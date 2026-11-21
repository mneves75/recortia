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
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let clock: any FeatureClock

    public init(assets: any ImageAssetService, clock: any FeatureClock) {
        self.assets = assets
        self.clock = clock
    }

    public var isEmpty: Bool { kept == nil }

    /// Closes `editor`. Its document replaces the kept one, whose pixels are released; a document
    /// that may not be kept closes as `EditorModel.close()` does and leaves the slot empty, so an
    /// older document never comes back in place of the one just closed.
    public func close(_ editor: EditorModel) {
        guard !editor.isClosed else { return }
        let document = editor.closeKeepingDocument()
        clear()
        guard let document else { return }
        kept = document
        let clock = self.clock
        expiry = Task { [weak self] in
            do { try await clock.sleep(for: Self.lifetime) } catch { return }
            self?.clear()
        }
    }

    /// Empties the slot and hands over the kept document: its pixels now belong to the caller,
    /// which opens it in an editor.
    public func take() -> DocumentSession? {
        expiry?.cancel()
        expiry = nil
        defer { kept = nil }
        return kept
    }

    /// Empties the slot and releases the kept document's pixels (timeout, replacement, quit).
    public func clear() {
        guard let session = take() else { return }
        for id in session.document.assets.keys { assets.release(id) }
    }
}
