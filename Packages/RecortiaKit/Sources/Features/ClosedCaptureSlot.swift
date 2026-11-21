import Domain
import Foundation
import Observation

/// Reopen Closed Capture (B-6, decisions 2026-11-21): the document of the most recently closed
/// editor, without its undo history, in memory only. It is never written to disk, preferences,
/// the pasteboard or a log. The slot owns the pixels of the kept document's assets and releases
/// them when a newer close replaces it, `lifetime` after the close, or on quit (`clear`). A
/// document whose masking is pending or failed unread is never kept (`EditorModel.isKeptOnClose`).
/// The slot is not a window: it never affects presence or the quit-after-last-window decision.
@MainActor
@Observable
public final class ClosedCaptureSlot {
    /// How long a closed editor's document can be reopened.
    public static let lifetime: Duration = .seconds(10 * 60)

    private var kept: DocumentSession?
    /// `clock.uptime()` at which the kept document expires. The expiry task can run late (App
    /// Nap, a wake from sleep), so every read checks this deadline too.
    @ObservationIgnored private var deadline: Duration?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let clock: any FeatureClock

    public init(assets: any ImageAssetService, clock: any FeatureClock) {
        self.assets = assets
        self.clock = clock
    }

    public var isEmpty: Bool { kept == nil || isExpired }

    private var isExpired: Bool { deadline.map { clock.uptime() >= $0 } ?? false }

    /// Closes `editor`. Its document replaces the kept one, whose pixels are released; a document
    /// that may not be kept closes as `EditorModel.close()` does and leaves the slot empty, so an
    /// older document never comes back in place of the one just closed.
    public func close(_ editor: EditorModel) {
        guard !editor.isClosed else { return }
        let document = editor.closeKeepingDocument()
        clear()
        guard let document else { return }
        kept = document
        let deadline = clock.uptime() + Self.lifetime
        self.deadline = deadline
        let clock = self.clock
        expiry = Task { [weak self] in
            // Sleep only what is left: a task that starts late still clears at the deadline.
            do { try await clock.sleep(for: max(.zero, deadline - clock.uptime())) } catch { return }
            // A sleep that ended just before a newer close cancelled it must not clear that close.
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    /// Empties the slot and hands over the kept document: its pixels now belong to the caller,
    /// which opens it in an editor. An expired document is released instead, and nil returned.
    public func take() -> DocumentSession? {
        let expired = isExpired
        guard let session = empty() else { return nil }
        guard !expired else {
            release(session)
            return nil
        }
        return session
    }

    /// Empties the slot and releases the kept document's pixels (timeout, replacement, quit).
    public func clear() {
        if let session = empty() { release(session) }
    }

    private func empty() -> DocumentSession? {
        expiry?.cancel()
        expiry = nil
        deadline = nil
        defer { kept = nil }
        return kept
    }

    private func release(_ session: DocumentSession) {
        for id in session.document.assets.keys { assets.release(id) }
    }
}
