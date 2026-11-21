import CoreGraphics
import Domain
import Foundation
import Observation

/// Where a completed capture goes (FR-01, ADR-009), decided synchronously when it completes.
public enum CaptureFollowUp: Hashable, Sendable {
    case editor(masksSensitiveText: Bool)
    case quickActions
    case recognizeText

    /// Capture Text keeps its flow. With automatic masking on, the capture opens in the editor
    /// whatever "After a capture" says: nothing may show or export it before its masks land, and
    /// a failed masking leaves the person in the editor to review it (FR-06 amendment).
    public static func decide(purpose: CapturePurpose, preferences: Preferences) -> CaptureFollowUp {
        guard purpose == .edit else { return .recognizeText }
        if preferences.autoRedactsSensitiveText { return .editor(masksSensitiveText: true) }
        return preferences.afterCapture == .showQuickActions ? .quickActions : .editor(masksSensitiveText: false)
    }
}

/// The capture a quick-action thumbnail holds: its session, whose pixels live only in the image
/// store, and the sanitizing renderer's small preview.
public struct QuickCapture: Identifiable, Sendable {
    public let id: UUID
    public let session: DocumentSession
    public internal(set) var preview: CGImage?
    /// The link this capture's own automatic upload returned, if it uploaded.
    public internal(set) var uploadedURL: URL?
}

/// The quick-action thumbnail after a capture (B-1, ADR-009). One capture at a time: its
/// automatic exports run first, then it shows with Copy, Save, Open in Editor, Pin and Dismiss
/// until an action ends it or `timeout` passes without the pointer over it.
///
/// Privacy: every export goes through `ExportCoordinator` (ShareSnapshot) and a pin through
/// `PinsModel`'s sanitizing render. Ending the thumbnail any way except Open in Editor releases
/// the capture's pixels from the image store, and an export still running then finds no current
/// session, so it writes nothing.
@MainActor
@Observable
public final class QuickActionsModel {
    /// How long a shown thumbnail waits for an action, counted again whenever the pointer leaves it.
    public static let timeout: Duration = .seconds(8)
    /// The preview's longest side in pixels; the thumbnail shows it at most 240 pt wide on 2× displays.
    static let previewMaxPixels = 640.0

    public private(set) var capture: QuickCapture?
    /// False while the capture's automatic exports run: the thumbnail is not shown yet.
    public private(set) var isShown = false
    /// An action (copy, save, drag offer, pin) is running; the others wait for it.
    public private(set) var isActing = false
    public private(set) var isPointerInside = false

    /// Receives the session for Open in Editor; the editor then owns its pixels.
    @ObservationIgnored public var onOpenInEditor: ((DocumentSession) -> Void)?

    @ObservationIgnored private let export: ExportCoordinator
    @ObservationIgnored private let pins: PinsModel
    @ObservationIgnored private let renderer: any RenderService
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let folders: any SaveFolderService
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let textClipboard: any TextClipboardService
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var exportSlotWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        export: ExportCoordinator, pins: PinsModel, renderer: any RenderService, assets: any ImageAssetService,
        folders: any SaveFolderService, settings: SettingsStore, clock: any FeatureClock,
        textClipboard: any TextClipboardService
    ) {
        self.export = export
        self.pins = pins
        self.renderer = renderer
        self.assets = assets
        self.folders = folders
        self.settings = settings
        self.clock = clock
        self.textClipboard = textClipboard
    }

    /// Holds `session`, discarding any earlier capture, runs `plan` (decided when the capture
    /// completed) on it, then shows the thumbnail. Returns the automatic outcomes for the caller to
    /// report. Like the editor's batch, it waits for another export to free the shared slot.
    public func present(_ session: DocumentSession, after plan: AutomaticExportPlan) async -> [ExportOutcome] {
        discard()
        let id = UUID()
        capture = QuickCapture(id: id, session: session)
        var outcomes: [ExportOutcome] = []
        if !plan.isEmpty {
            guard await waitForExportSlot(id) else { return [.canceled] }
            outcomes = await export.runAutomaticExports(
                plan, for: session, currentSession: { [weak self] in self?.held(id) })
        }
        guard capture?.id == id else { return outcomes }
        let document = session.document
        let side = document.assets.values.map { Double(max($0.pixelSize.width, $0.pixelSize.height)) }.max() ?? 1
        let preview = try? await renderer.render(document, scale: min(1, Self.previewMaxPixels / max(side, 1)))
        guard capture?.id == id else { return outcomes }
        capture?.preview = preview
        // Only this batch's outcome, run under the consent identity fixed at capture.
        capture?.uploadedURL = outcomes.lazy.compactMap(\.uploadedURL).first
        isShown = true
        armTimer()
        return outcomes
    }

    /// The pointer over the thumbnail stops its timer; leaving starts a full `timeout` again.
    public func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside, capture != nil else { return }
        isPointerInside = inside
        armTimer()
    }

    public func copy() async -> ExportOutcome {
        await run(.copy)
    }

    /// Offers the sanitized snapshot on the drag chip (ADR-004); the thumbnail ends once a
    /// receiver has written the file, and stays when the offer ends without one.
    public func drag() async -> ExportOutcome {
        await run(.drag)
    }

    /// Saves into the folder chosen in Settings when it resolves; otherwise asks `choose` for a
    /// destination (nil cancels). Replacing an existing file needs `confirmReplacement` (FR-07).
    public func save(
        choosing choose: @MainActor () async -> (url: URL, format: ExportFormatChoice)?,
        confirmReplacement: @MainActor () async -> Bool
    ) async -> ExportOutcome {
        guard let held = begin() else { return .rejectedBusy }
        if let folder = settings.preferences.preferredSaveFolderBookmark.flatMap(folders.resolveFolder) {
            return finish(held, await exportHeld(.saveToFolder(folder), held))
        }
        guard let destination = await choose(), capture?.id == held.id else { return finish(held, .canceled) }
        var outcome = await exportHeld(
            .save(to: destination.url, format: destination.format, overwriteConfirmed: false), held)
        if outcome == .failed(.destinationExists), capture?.id == held.id {
            guard await confirmReplacement(), capture?.id == held.id else { return finish(held, .canceled) }
            outcome = await exportHeld(
                .save(to: destination.url, format: destination.format, overwriteConfirmed: true), held)
        }
        return finish(held, outcome)
    }

    /// Pins a sanitized render; the pin keeps only that raster, so the capture's pixels go.
    public func pin() async -> PinError? {
        guard let held = begin() else { return nil }
        do {
            try await pins.pin(held.session, currentSession: { [weak self] in self?.held(held.id) })
            end(held, finished: true)
            return nil
        } catch {
            end(held, finished: false)
            return error
        }
    }

    /// Copies the link this capture's own automatic upload returned, as plain text. It exports
    /// nothing of the capture, so the thumbnail stays and its timer keeps running.
    public func copyLink() -> Bool {
        guard isShown, let url = capture?.uploadedURL else { return false }
        return textClipboard.writePlainText(url.absoluteString)
    }

    /// Hands the capture to an ordinary editor, which then owns its pixels. Cancels an action in
    /// progress first, so a drag offer made from the thumbnail cannot outlive it.
    public func openInEditor() {
        guard isShown, let held = capture, let open = onOpenInEditor else { return }
        clear()
        export.cancel(documentID: held.session.document.id)
        open(held.session)
    }

    /// Ends the thumbnail and releases the capture's pixels. Idempotent.
    public func dismiss() {
        discard()
    }

    // MARK: Lifecycle

    private func held(_ id: UUID) -> DocumentSession? {
        capture?.id == id ? capture?.session : nil
    }

    private func run(_ action: ExportAction) async -> ExportOutcome {
        guard let held = begin() else { return .rejectedBusy }
        return finish(held, await exportHeld(action, held))
    }

    private func exportHeld(_ action: ExportAction, _ held: QuickCapture) async -> ExportOutcome {
        await export.export(action, session: held.session, currentSession: { [weak self] in self?.held(held.id) })
    }

    private func begin() -> QuickCapture? {
        guard isShown, !isActing, let capture else { return nil }
        isActing = true
        armTimer()
        return capture
    }

    private func finish(_ held: QuickCapture, _ outcome: ExportOutcome) -> ExportOutcome {
        end(held, finished: outcome.didWrite)
        return outcome
    }

    /// A finished action ends the thumbnail; one that wrote nothing leaves it for another try.
    private func end(_ held: QuickCapture, finished: Bool) {
        guard capture?.id == held.id else { return }
        isActing = false
        if finished { discard() } else { armTimer() }
    }

    private func discard() {
        guard let held = capture else { return }
        clear()
        // An export or drag offer still running for this capture ends here; it finds no session.
        export.cancel(documentID: held.session.document.id)
        for id in held.session.document.assets.keys { assets.release(id) }
    }

    private func clear() {
        timer?.cancel()
        timer = nil
        capture = nil
        isShown = false
        isActing = false
        isPointerInside = false
        resumeExportSlotWaiters()
    }

    /// Runs only while shown, idle and without the pointer over the thumbnail.
    private func armTimer() {
        timer?.cancel()
        timer = nil
        guard isShown, !isActing, !isPointerInside, let id = capture?.id else { return }
        let clock = self.clock
        timer = Task { [weak self] in
            do { try await clock.sleep(for: Self.timeout) } catch { return }
            guard let self, self.capture?.id == id, !self.isActing, !self.isPointerInside else { return }
            self.discard()
        }
    }

    /// Suspends until no export runs; false once this capture is no longer held. As in the editor,
    /// the coordinator sets and clears its operation without suspending between a batch's steps.
    private func waitForExportSlot(_ id: UUID) async -> Bool {
        while export.isBusy, capture?.id == id {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                exportSlotWaiters.append(waiter)
                withObservationTracking {
                    _ = export.isBusy
                } onChange: { [weak self] in
                    Task { @MainActor in self?.resumeExportSlotWaiters() }
                }
            }
        }
        return capture?.id == id
    }

    private func resumeExportSlotWaiters() {
        let waiters = exportSlotWaiters
        exportSlotWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
