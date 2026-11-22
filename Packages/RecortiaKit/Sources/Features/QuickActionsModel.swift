import CoreGraphics
import Domain
import Foundation
import Imaging
import Observation

/// Where a completed capture goes (FR-01, ADR-009), decided synchronously when it completes.
public enum CaptureFollowUp: Hashable, Sendable {
    case editor(masksSensitiveText: Bool)
    case quickActions
    case pin
    case recognizeText

    /// Capture Text keeps its flow. With automatic masking on, the capture opens in the editor
    /// whatever "After a capture" says: nothing may show or export it before its masks land, and
    /// a failed masking leaves the person in the editor to review it (FR-06 amendment).
    public static func decide(purpose: CapturePurpose, preferences: Preferences) -> CaptureFollowUp {
        guard purpose == .edit else { return .recognizeText }
        if preferences.autoRedactsSensitiveText { return .editor(masksSensitiveText: true) }
        return switch preferences.afterCapture {
        case .openEditor: .editor(masksSensitiveText: false)
        case .showQuickActions: .quickActions
        case .pin: .pin
        }
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
    public internal(set) var automaticPinFailure: PinError?
}

public enum QuickTextCopyOutcome: Equatable, Sendable {
    case copied
    case noText
    case recognitionFailed
    case clipboardFailed
    case canceled
    case rejectedBusy
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
    public typealias PresentationOutcome = (exports: [ExportOutcome], permissionDenied: Bool)
    /// How long a shown thumbnail waits for an action, counted again whenever the pointer leaves it.
    public static let timeout: Duration = .seconds(8)
    /// The preview's longest side in pixels; the thumbnail shows it at most 240 pt wide on 2× displays.
    static let previewMaxPixels = 640.0
    private static let expandedPreviewMaxPixels = 1600

    public private(set) var capture: QuickCapture?
    public private(set) var expandedPreview: CGImage?
    public var canOpenPreview: Bool { isShown && !isActing && previewTask == nil && expandedPreview == nil }
    public var canCopyText: Bool { isShown && !isActing && textCopyTask == nil }
    /// False while the capture's automatic exports run: the thumbnail is not shown yet.
    public private(set) var isShown = false
    /// An image or text action is running; the others wait for it.
    public private(set) var isActing = false
    public private(set) var isPointerInside = false
    private var isPointerInsidePreview = false
    private var isPreviewKey = false
    private var previewRequest: UUID?
    private var previewTask: Task<CGImage, any Error>?
    private var textCopyTask: Task<String?, any Error>?
    private var automaticPinPermission: (any ScreenPermissionService)?

    public var isPreparingAutomaticPin: Bool { automaticPinPermission != nil }

    /// Receives the session for Open in Editor; the editor then owns its pixels.
    @ObservationIgnored public var onOpenInEditor: ((DocumentSession) -> Void)?

    @ObservationIgnored private let export: ExportCoordinator
    @ObservationIgnored private let pins: PinsModel
    @ObservationIgnored private let renderer: any RenderService
    @ObservationIgnored private let assets: any ImageAssetService
    @ObservationIgnored private let folders: any SaveFolderService
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let textRecognition: any TextRecognitionService
    @ObservationIgnored private let textClipboard: any TextClipboardService
    @ObservationIgnored private var textCopyRequest: UUID?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var exportSlotWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        export: ExportCoordinator, pins: PinsModel, renderer: any RenderService, assets: any ImageAssetService,
        folders: any SaveFolderService, settings: SettingsStore, clock: any FeatureClock,
        textRecognition: any TextRecognitionService, textClipboard: any TextClipboardService
    ) {
        self.export = export
        self.pins = pins
        self.renderer = renderer
        self.assets = assets
        self.folders = folders
        self.settings = settings
        self.clock = clock
        self.textRecognition = textRecognition
        self.textClipboard = textClipboard
    }

    /// Holds `session`, discarding any earlier capture, runs `plan` (decided when the capture
    /// completed) on it, then shows the thumbnail. Returns the automatic outcomes for the caller to
    /// report. Like the editor's batch, it waits for another export to free the shared slot.
    public func present(_ session: DocumentSession, after plan: AutomaticExportPlan) async -> [ExportOutcome] {
        let pending = hold(session, pinningIfAllowedBy: nil)
        return await finishPresentation(pending, after: plan).exports
    }

    /// Admit the capture now so an earlier queued job cannot replace it. A supplied permission
    /// service selects Pin, with the same thumbnail as its fallback.
    public func schedulePresentation(
        _ session: DocumentSession, after plan: AutomaticExportPlan,
        pinningIfAllowedBy permission: (any ScreenPermissionService)? = nil
    ) -> Task<PresentationOutcome, Never> {
        let pending = hold(session, pinningIfAllowedBy: permission)
        return Task {
            await withTaskCancellationHandler {
                await finishPresentation(pending, after: plan)
            } onCancel: { [weak self] in
                Task { @MainActor in self?.discardIfCurrent(pending.id) }
            }
        }
    }

    private func hold(
        _ session: DocumentSession, pinningIfAllowedBy permission: (any ScreenPermissionService)?
    ) -> QuickCapture {
        discard()
        let pending = QuickCapture(id: UUID(), session: session)
        capture = pending
        automaticPinPermission = permission
        return pending
    }

    private func finishPresentation(_ pending: QuickCapture, after plan: AutomaticExportPlan) async
        -> PresentationOutcome
    {
        let id = pending.id
        let sessionIfCurrent: @MainActor @Sendable () -> DocumentSession? = { [weak self] in
            guard !Task.isCancelled, self?.automaticPinPermission?.isGranted != false else { return nil }
            return self?.held(id)
        }
        var outcomes: [ExportOutcome] = []
        if let ended = endedPresentation(id, exports: outcomes) { return ended }
        if !plan.isEmpty {
            guard await waitForExportSlot(id) else { return ([.canceled], false) }
            if let ended = endedPresentation(id, exports: outcomes) { return ended }
            outcomes = await export.runAutomaticExports(plan, for: pending.session, currentSession: sessionIfCurrent)
        }
        if let ended = endedPresentation(id, exports: outcomes) { return ended }
        var pinFailure: PinError?
        if isPreparingAutomaticPin {
            do {
                try await pins.pin(pending.session, takesFocus: false, currentSession: sessionIfCurrent)
                discardIfCurrent(id)
                return (outcomes, false)
            } catch {
                if let ended = endedPresentation(id, exports: outcomes) { return ended }
                pinFailure = error
            }
        }
        let document = pending.session.document
        let side = document.assets.values.map { Double(max($0.pixelSize.width, $0.pixelSize.height)) }.max() ?? 1
        let preview = try? await renderer.render(document, scale: min(1, Self.previewMaxPixels / max(side, 1)))
        if let ended = endedPresentation(id, exports: outcomes) { return ended }
        capture?.preview = preview
        // Only this batch's outcome, run under the consent identity fixed at capture.
        capture?.uploadedURL = outcomes.lazy.compactMap(\.uploadedURL).first
        capture?.automaticPinFailure = pinFailure
        automaticPinPermission = nil
        isShown = true
        armTimer()
        return (outcomes, false)
    }

    private func endedPresentation(_ id: UUID, exports: [ExportOutcome]) -> PresentationOutcome? {
        guard capture?.id == id else { return (exports, false) }
        if Task.isCancelled {
            discard()
            return (exports, false)
        }
        guard automaticPinPermission?.isGranted == false else { return nil }
        discard()
        return (exports.filter { $0 != .failed(.staleDocument) }, true)
    }

    /// The pointer over the thumbnail stops its timer; leaving starts a full `timeout` again.
    public func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside, capture != nil else { return }
        isPointerInside = inside
        armTimer()
    }

    public func setPointerInsidePreview(_ inside: Bool) {
        guard isPointerInsidePreview != inside, expandedPreview != nil else { return }
        isPointerInsidePreview = inside
        armTimer()
    }

    public func setPreviewKey(_ key: Bool) {
        guard isPreviewKey != key, expandedPreview != nil else { return }
        isPreviewKey = key
        armTimer()
    }

    public func openPreview() async throws {
        guard canOpenPreview, let capture else { return }
        let document = capture.session.document
        let scale = try Self.expandedPreviewScale(for: document)
        let request = UUID()
        previewRequest = request
        armTimer()
        let task = Task { [renderer] in try await renderer.render(document, scale: scale) }
        previewTask = task
        let result = await task.result
        previewTask = nil
        guard previewRequest == request, self.capture?.id == capture.id else { return }
        previewRequest = nil
        armTimer()
        expandedPreview = try result.get()
    }

    private static func expandedPreviewScale(for document: Document) throws(RenderError) -> Double {
        let size = document.outputPixelSize(exportScale: 1)
        guard !size.isEmpty else { throw .invalidGeometry }
        let side = max(size.width, size.height)
        guard side > expandedPreviewMaxPixels else { return 1 }
        // Aspect presets round up by a whole ratio multiple. Leave room for that final step.
        let ratio = document.presentation.aspect.ratio
        let rounding = max(ratio?.width ?? 1, ratio?.height ?? 1)
        let scale = Double(expandedPreviewMaxPixels - rounding) / Double(side)
        let scaled = document.outputPixelSize(exportScale: scale)
        guard !scaled.isEmpty, max(scaled.width, scaled.height) <= expandedPreviewMaxPixels else {
            throw .invalidGeometry
        }
        return scale
    }

    @discardableResult
    public func closePreview() -> Bool {
        guard previewRequest != nil || expandedPreview != nil else { return false }
        clearPreview()
        armTimer()
        return true
    }

    public func suspendForCapture(keepingVisiblePreview: Bool) {
        cancelTextCopy()
        if !keepingVisiblePreview { closePreview() }
        setPointerInside(false)
        setPointerInsidePreview(false)
        setPreviewKey(false)
    }

    public func copy() async -> ExportOutcome {
        await run(.copy)
    }

    /// Recognizes only the current sanitized output, without using the thumbnail's smaller raster.
    public func copyText() async -> QuickTextCopyOutcome {
        guard !Task.isCancelled else { return .canceled }
        guard textCopyTask == nil, let held = begin() else { return .rejectedBusy }
        let request = UUID()
        let identity = held.session.requestIdentity()
        let mode = settings.preferences.ocrTextMode
        let document = held.session.document
        let task = Task { [renderer, textRecognition, settings] () throws -> String? in
            let image = try await renderer.render(document, scale: 1)
            try Task.checkCancellation()
            let supported = await textRecognition.supportedLanguages()
            try Task.checkCancellation()
            let (languages, _) = settings.recognitionLanguages(supported: supported)
            let result = try await textRecognition.recognize(image, languages: languages)
            try Task.checkCancellation()
            return result.isEmpty ? nil : result.text(mode: mode)
        }
        textCopyRequest = request
        textCopyTask = task
        defer {
            textCopyTask = nil
            if textCopyRequest == request {
                textCopyRequest = nil
                end(held, finished: false)
            }
        }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, !task.isCancelled, textCopyRequest == request,
            capture?.id == held.id, capture?.session.accepts(identity) == true
        else { return .canceled }
        switch result {
        case .failure(let error):
            return error is CancellationError ? .canceled : .recognitionFailed
        case .success(let text):
            guard let text, !text.isEmpty else { return .noText }
            return textClipboard.writePlainText(text) ? .copied : .clipboardFailed
        }
    }

    /// Offers the sanitized snapshot on the drag chip (ADR-004); the thumbnail ends once a
    /// receiver has written the file, and stays when the offer ends without one.
    public func drag() async -> ExportOutcome {
        await run(.drag)
    }

    /// Saves into the folder chosen in Settings when it resolves; otherwise asks `choose` for a
    /// destination (nil cancels). Replacing an existing file needs `confirmReplacement` for that
    /// exact file; a retry that resolves to another existing file asks again about it (FR-07).
    public func save(
        choosing choose: @MainActor () async -> (url: URL, format: ExportFormatChoice)?,
        confirmReplacement: @MainActor (_ existing: URL) async -> Bool
    ) async -> ExportOutcome {
        guard let held = begin() else { return .rejectedBusy }
        if let folder = settings.preferences.preferredSaveFolderBookmark.flatMap(folders.resolveFolder) {
            return finish(held, await exportHeld(.saveToFolder(folder), held))
        }
        guard let destination = await choose(), capture?.id == held.id else { return finish(held, .canceled) }
        var outcome = await exportHeld(.save(to: destination.url, format: destination.format, replacing: nil), held)
        var asked: Set<URL> = []
        while case .failed(.destinationExists(let existing?)) = outcome, asked.insert(existing).inserted,
            capture?.id == held.id
        {
            guard await confirmReplacement(existing), capture?.id == held.id else { return finish(held, .canceled) }
            outcome = await exportHeld(
                .save(to: destination.url, format: destination.format, replacing: existing), held)
        }
        return finish(held, outcome)
    }

    public func saveOptimized(using dialogs: OptimizedSaveDialogs) async -> ExportOutcome {
        guard let held = begin() else { return .rejectedBusy }
        let outcome = await export.saveOptimized(
            held.session, using: dialogs, currentSession: { [weak self] in self?.held(held.id) })
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
        // A later explicit clipboard action takes precedence over pending recognition.
        cancelTextCopy()
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

    public func cancelAutomaticPin() {
        if isPreparingAutomaticPin { discard() }
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

    private func discardIfCurrent(_ id: UUID) {
        if capture?.id == id { discard() }
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
        clearPreview()
        capture = nil
        automaticPinPermission = nil
        isShown = false
        cancelTextCopy()
        isActing = false
        isPointerInside = false
        resumeExportSlotWaiters()
    }

    private func cancelTextCopy() {
        guard textCopyRequest != nil else { return }
        textCopyRequest = nil
        // Keep the OCR slot until the canceled render or recognition has unwound.
        textCopyTask?.cancel()
        isActing = false
        armTimer()
    }

    private func clearPreview() {
        // Release the slot only when the task unwinds. A render may be in synchronous imaging code.
        previewTask?.cancel()
        previewRequest = nil
        expandedPreview = nil
        isPointerInsidePreview = false
        isPreviewKey = false
    }

    private var canExpire: Bool {
        isShown && !isActing && !isPointerInside && !isPointerInsidePreview && !isPreviewKey && previewRequest == nil
    }

    private func armTimer() {
        timer?.cancel()
        timer = nil
        guard canExpire, let id = capture?.id else { return }
        let clock = self.clock
        timer = Task { [weak self] in
            do { try await clock.sleep(for: Self.timeout) } catch { return }
            guard !Task.isCancelled, let self, self.capture?.id == id, self.canExpire else { return }
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
