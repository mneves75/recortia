import CoreGraphics
import Domain
import Foundation
import MacPlatform
import Observation

public enum ExportAction: Hashable, Sendable {
    /// Copy Image: always a sanitized PNG only (FR-07).
    case copy
    /// Save to a user-chosen URL in the format its save panel named, so the bytes match the
    /// extension even if the preference changed meanwhile; under Automatic the file takes the
    /// extension of the format chosen. `replacing` is the file the person agreed to replace, as
    /// the collision named it; only that exact file is overwritten.
    case save(to: URL, format: ExportFormatChoice, replacing: URL?)
    /// Save with a collision-free name into a previously authorized folder.
    case saveToFolder(URL)
    case drag
    case upload(to: GitHubDestination, intent: UUID)
    /// Print (B-9a): the sanitized PNG, handed to the system print panel like a Copy.
    case print
}

/// Only the prepared file's metadata crosses into the destination picker.
public struct OptimizedSaveDetails: Sendable {
    public let format: ExportFormat
    public let pixelSize: PixelSize
    public let byteCount: Int
    public let suggestedFilename: String
    public let preferredFolder: URL?
}

/// Dialogs must close and return when their presenting task is canceled.
public struct OptimizedSaveDialogs {
    let chooseDestination: @MainActor (OptimizedSaveDetails) async -> URL?
    let confirmReplacement: @MainActor (URL) async -> Bool

    public init(
        chooseDestination: @escaping @MainActor (OptimizedSaveDetails) async -> URL?,
        confirmReplacement: @escaping @MainActor (URL) async -> Bool
    ) {
        self.chooseDestination = chooseDestination
        self.confirmReplacement = confirmReplacement
    }
}

public enum ExportOutcome: Hashable, Sendable {
    case copied
    /// The print panel shows the snapshot; the person may still cancel there, so the document
    /// still counts as unexported.
    case printed
    case saved(URL)
    case dragged
    case uploaded(URL)
    /// Cancel arrived after the write was committed; the action happened and cannot be retracted.
    indirect case alreadyCompleted(ExportOutcome)
    case canceled
    case failed(ExportFailure)
    /// Another export is running; nothing was done.
    case rejectedBusy

    public var uploadedURL: URL? {
        switch self {
        case .uploaded(let url): url
        case .alreadyCompleted(let outcome): outcome.uploadedURL
        default: nil
        }
    }

    public var didWrite: Bool {
        switch self {
        case .copied, .saved, .dragged, .uploaded, .alreadyCompleted: true
        case .printed, .canceled, .failed, .rejectedBusy: false
        }
    }
}

/// What one automatic batch does (R-3), decided synchronously when its capture completes. A step
/// turned on or a folder chosen afterwards applies to the next capture; turning a step off still
/// stops it, because each step also checks the live settings when it starts and after its render.
public struct AutomaticExportPlan: Hashable, Sendable {
    enum Save: Hashable, Sendable {
        case folder(URL)
        /// Automatic save was on, but its folder no longer resolves: the batch reports that.
        case folderUnavailable
    }

    let copy: Bool
    let save: Save?
    /// `SettingsStore.saveFolderSelection` at capture: a later choice of folder revokes the save.
    let saveFolderSelection: Int
    let upload: GitHubDestination?
    let uploadConsentID: UUID

    public var isEmpty: Bool { !copy && save == nil && upload == nil }
}

/// The live check an automatic step makes when it starts and again after its render (EXP-03).
enum AutomaticStepCheck: Hashable, Sendable {
    case allowed
    /// The person turned the step off or chose another destination: skipped without a message.
    case revoked
    /// The step is still wanted but cannot run, such as a save folder that stopped resolving.
    case failed(ExportFailure)
}

/// Drives `ExportState` for Copy, Save, Drag, Print and GitHub upload (FR-07, EXP-02, NET-01).
///
/// Order: take an immutable snapshot through the export pipeline, verify that it still matches
/// the live document (revision and privacy epoch), then commit to exactly one sink. The pipeline
/// performs sanitizing, rendering, and encoding in one call, so the state reports `.rendering`
/// while it runs and `.encoding` once the encoded bytes are verified. Success is reported only
/// after the sink returns. Cancel before the commit leaves every sink untouched; a confirmed
/// write that a cancel reached reports `.alreadyCompleted`, while an interrupted upload can leave
/// its completion unknown. A drag stays uncommitted until a receiver writes the promised file, so
/// a drag the user abandons is a plain cancellation.
@MainActor
@Observable
public final class ExportCoordinator {
    public private(set) var state: ExportState?
    private var operation: Operation?
    private var automaticBatch: Operation?

    @ObservationIgnored private let exporter: any ExportService
    @ObservationIgnored private let clipboard: any ClipboardSinkService
    @ObservationIgnored private let files: any FileSinkService
    @ObservationIgnored private let drag: any DragSinkService
    @ObservationIgnored private let printer: any PrintSinkService
    @ObservationIgnored private let folders: any SaveFolderService
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let upload: (any GitHubUploadService)?
    @ObservationIgnored private let diagnostics: (any DiagnosticsSink)?
    @ObservationIgnored private var snapshotTask: Task<ShareSnapshot, any Error>?
    @ObservationIgnored private var pendingDrag: PendingDrag?
    @ObservationIgnored private var uploadTask: Task<URL, any Error>?

    private struct PendingDrag {
        let documentID: DocumentID
        let lease: ExportLease
    }

    private struct Operation {
        let id: UUID
        let documentID: DocumentID
        var cancelRequested = false
        var dismissDialog: (() -> Void)?
        /// A drag is offered and waiting for a receiver; cancel is decided when it ends.
        var awaitingDragReceiver = false
    }

    private enum Request {
        case action(ExportAction)
        case optimizedSave(OptimizedSaveDialogs)
    }

    public init(
        exporter: any ExportService, clipboard: any ClipboardSinkService, files: any FileSinkService,
        drag: any DragSinkService, printer: any PrintSinkService,
        folders: any SaveFolderService, clock: any FeatureClock, settings: SettingsStore,
        upload: (any GitHubUploadService)? = nil, diagnostics: (any DiagnosticsSink)? = nil
    ) {
        self.exporter = exporter
        self.clipboard = clipboard
        self.files = files
        self.drag = drag
        self.printer = printer
        self.folders = folders
        self.clock = clock
        self.settings = settings
        self.upload = upload
        self.diagnostics = diagnostics
    }

    public var isBusy: Bool { operation != nil }

    /// Whether the running export belongs to `documentID`; each editor shows and cancels only its own.
    public func isBusy(documentID: DocumentID) -> Bool { operation?.documentID == documentID }

    /// Exports `session` through one sink. `currentSession` returns the live session (nil once
    /// its editor closed) and is consulted after the snapshot, before anything is committed.
    public func export(
        _ action: ExportAction, session: DocumentSession,
        currentSession: @escaping @MainActor @Sendable () -> DocumentSession?
    ) async -> ExportOutcome {
        await export(
            .action(action), session: session, currentSession: currentSession, uploadConsentID: nil,
            isAllowed: { .allowed })
    }

    public func saveOptimized(
        _ session: DocumentSession, using dialogs: OptimizedSaveDialogs,
        currentSession: @escaping @MainActor @Sendable () -> DocumentSession?
    ) async -> ExportOutcome {
        await export(
            .optimizedSave(dialogs), session: session, currentSession: currentSession, uploadConsentID: nil,
            isAllowed: { .allowed })
    }

    /// The automatic path: `isAllowed` is the step's live check after its render, and an upload
    /// carries the consent identity its batch was planned with.
    private func export(
        _ request: Request, session: DocumentSession,
        currentSession: @escaping @MainActor @Sendable () -> DocumentSession?,
        uploadConsentID: UUID?, isAllowed: @escaping @MainActor () -> AutomaticStepCheck
    ) async -> ExportOutcome {
        let exporter = self.exporter
        return await run(
            request, documentID: session.document.id, uploadConsentID: uploadConsentID, isAllowed: isAllowed,
            makeSnapshot: { options, date in try await exporter.makeSnapshot(of: session, options: options, date: date)
            },
            isCurrent: { snapshot in currentSession()?.accepts(snapshot) == true })
    }

    /// Exports a pin's sanitized raster (FR-09, ADR-007) at its own size. `isCurrent` is false once
    /// the pin was closed or invalidated; a pending drag is revoked through `invalidatePendingDrag`.
    public func export(
        _ action: PinExportAction, pinned image: CGImage, exportID: DocumentID, privacyEpoch: UInt64,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> ExportOutcome {
        let exporter = self.exporter
        return await run(
            .action(action == .copy ? .copy : .drag), documentID: exportID, uploadConsentID: nil, fixedScale: 1,
            makeSnapshot: { options, date in
                try await exporter.makeSnapshot(
                    ofPinned: image, exportID: exportID, privacyEpoch: privacyEpoch, options: options, date: date)
            },
            isCurrent: { snapshot in snapshot.documentID == exportID && isCurrent() })
    }

    private func run(
        _ request: Request, documentID: DocumentID, uploadConsentID: UUID?,
        isAllowed: @escaping @MainActor () -> AutomaticStepCheck = { .allowed }, fixedScale: Double? = nil,
        makeSnapshot: @escaping @MainActor (ExportOptions, Date) async throws -> ShareSnapshot,
        isCurrent: @escaping @MainActor @Sendable (ShareSnapshot) -> Bool
    ) async -> ExportOutcome {
        let started = clock.uptime()
        let outcome = await perform(
            request, documentID: documentID, uploadConsentID: uploadConsentID, isAllowed: isAllowed,
            fixedScale: fixedScale, makeSnapshot: makeSnapshot, isCurrent: isCurrent)
        recordDiagnostics(outcome, of: request, duration: clock.uptime() - started)
        return outcome
    }

    /// One typed line per export outcome; a busy refusal started nothing and is not recorded.
    private func recordDiagnostics(_ outcome: ExportOutcome, of request: Request, duration: Duration) {
        guard let diagnostics else { return }
        let sink: DiagnosticExportSink =
            switch request {
            case .action(.copy): .clipboard
            case .action(.save), .action(.saveToFolder), .optimizedSave: .file
            case .action(.drag): .drag
            case .action(.upload): .github
            case .action(.print): .print
            }
        let format: DiagnosticImageFormat =
            switch options(for: request).formatChoice {
            case .fixed(.png): .png
            case .fixed(.jpeg): .jpeg
            case .fixed(.heic): .heic
            case .automatic: .automatic
            }
        switch outcome {
        case .copied, .printed, .saved, .dragged, .uploaded, .alreadyCompleted:
            diagnostics.record(.exportFinished(sink: sink, format: format, duration: duration))
        case .canceled:
            diagnostics.record(.exportCancelled(sink: sink, format: format, duration: duration))
        case .failed(let failure):
            diagnostics.record(
                .exportFailed(sink: sink, format: format, failure: DiagnosticExportFailure(failure), duration: duration)
            )
        case .rejectedBusy:
            break
        }
    }

    private func perform(
        _ request: Request, documentID: DocumentID, uploadConsentID: UUID?,
        isAllowed: @escaping @MainActor () -> AutomaticStepCheck, fixedScale: Double?,
        makeSnapshot: @escaping @MainActor (ExportOptions, Date) async throws -> ShareSnapshot,
        isCurrent: @escaping @MainActor @Sendable (ShareSnapshot) -> Bool
    ) async -> ExportOutcome {
        guard operation == nil else { return .rejectedBusy }
        let id = UUID()
        let consentID = uploadConsentID ?? settings.githubUploadConsentID
        operation = Operation(id: id, documentID: documentID)
        defer {
            if operation?.id == id { operation = nil }
            snapshotTask = nil
            uploadTask = nil
        }

        state = .requested
        apply(.snapshot)
        apply(.sanitize)
        apply(.render)

        // The export pipeline is the one admission point for these options.
        var options = options(for: request)
        if let fixedScale { options.scale = fixedScale }
        let date = clock.now()
        let task = Task<ShareSnapshot, any Error> { try await makeSnapshot(options, date) }
        snapshotTask = task
        let result = await task.result
        if operation?.cancelRequested == true { return .canceled }

        let snapshot: ShareSnapshot
        switch result {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            return fail((error as? ExportServiceError)?.failure ?? .renderFailed)
        }
        apply(.encode)

        guard isCurrent(snapshot) else { return fail(.staleDocument) }
        // The setting that authorized an automatic write may have changed during the render.
        switch isAllowed() {
        case .allowed: break
        case .revoked:
            apply(.cancel)
            return .canceled
        case .failed(let failure): return fail(failure)
        }

        do throws(SinkError) {
            let completed: ExportOutcome
            switch request {
            case .action(.copy):
                apply(.commit)
                try clipboard.write(snapshot)
                completed = .copied
            case .action(.print):
                apply(.commit)
                try printer.present(snapshot)
                completed = .printed
            case .action(.save(let url, let format, let replacing)):
                apply(.commit)
                let destination = format == .automatic ? Self.named(url, for: snapshot.format) : url
                // Consent travels with this save and names one file. A retry that renders again
                // may resolve to another (Automatic), which is then created exclusively and, if
                // it exists, reported so the person is asked about it by name (FR-07).
                let replaces = replacing?.standardizedFileURL == destination.standardizedFileURL
                do throws(SinkError) {
                    completed = .saved(try await files.save(snapshot, to: destination, overwrite: replaces))
                } catch .destinationExists {
                    return fail(.destinationExists(destination))
                }
            case .action(.saveToFolder(let folder)):
                apply(.commit)
                completed = .saved(try await files.saveUnique(snapshot, in: folder))
            case .action(.upload(let destination, let intent)):
                guard let upload else { return fail(.upload(.missingCredential)) }
                // No request of any kind (lookups included) for consent that is no longer live.
                guard settings.githubUploadConsentID == consentID else {
                    apply(.cancel)
                    return .canceled
                }
                // Rechecked by the uploader before each request: main-actor work queued before
                // this task (a Settings change) runs before it starts.
                let settings = self.settings
                let consentHolds = { @MainActor @Sendable () -> Bool in
                    settings.githubUploadConsentID == consentID
                        && settings.preferences.githubUpload?.automatic == true
                        && settings.preferences.githubUpload?.destination == destination
                }
                let isLive = { @MainActor @Sendable [weak self] () -> Bool in
                    guard let self else { return false }
                    return self.operation?.cancelRequested == false && consentHolds() && isCurrent(snapshot)
                }
                let task = Task<URL, any Error> { [weak self] in
                    try await upload.upload(
                        snapshot, to: destination, intent: intent, isLive: isLive,
                        isCurrent: { [weak self] in
                            guard let self, isLive() else { return false }
                            self.apply(.commit)
                            return true
                        })
                }
                uploadTask = task
                switch await task.result {
                case .success(let url): completed = .uploaded(url)
                case .failure(let error):
                    let failure = (error as? GitHubUploadFailure) ?? .completionUnknown
                    // Consent revoked before the image request started is the person's own
                    // action: any failure then (a lookup's 403 or timeout included) ends the upload
                    // silently, as a revocation before the step does. Once the image request has
                    // started (`.committing`), its failed or unknown result is reported.
                    if failure == .canceled || (!consentHolds() && state != .committing) {
                        if state != .canceled { apply(.cancel) }
                        return .canceled
                    }
                    return fail(.upload(failure))
                }
            case .action(.drag):
                // The receiver writes the file later, after an unbounded wait; the lease lets a
                // document change, cancel, or close revoke the offer before that write (RED-03).
                let lease = ExportLease()
                operation?.awaitingDragReceiver = true
                pendingDrag = PendingDrag(documentID: snapshot.documentID, lease: lease)
                // Whatever ends the offer (a write, the chip closing, cancel, failure), promises
                // already handed to receivers must not write later: revoking is a no-op once the
                // write has committed.
                defer {
                    lease.revoke()
                    pendingDrag = nil
                }
                let delivery = try await drag.deliver(snapshot, lease: lease)
                operation?.awaitingDragReceiver = false
                // The lease, not the chip's report, says whether the receiver has the file: a
                // cancel or edit that lands after the write must not call a finished export
                // canceled or stale (it is reported as already completed below).
                if lease.isCommitted {
                    apply(.commit)
                    completed = .dragged
                } else if operation?.cancelRequested == true {
                    apply(.cancel)
                    return .canceled
                } else if lease.isRevoked || delivery == .delivered {
                    // Revoked before the write, or a sink that reported delivery without it.
                    return fail(.staleDocument)
                } else {
                    apply(.cancel)
                    return .canceled
                }
            case .optimizedSave(let dialogs):
                return await deliverOptimizedSave(snapshot, using: dialogs, isCurrent: isCurrent)
            }
            return complete(completed)
        } catch {
            return fail(Self.failure(for: error))
        }
    }

    private func deliverOptimizedSave(
        _ snapshot: ShareSnapshot, using dialogs: OptimizedSaveDialogs,
        isCurrent: @MainActor (ShareSnapshot) -> Bool
    ) async -> ExportOutcome {
        func canDeliver() -> Bool {
            !Task.isCancelled && operation?.cancelRequested == false && isCurrent(snapshot)
        }

        let details = OptimizedSaveDetails(
            format: snapshot.format, pixelSize: snapshot.pixelSize, byteCount: snapshot.bytes.count,
            suggestedFilename: snapshot.suggestedFilename,
            preferredFolder: settings.preferences.preferredSaveFolderBookmark.flatMap(folders.resolveFolder))
        guard canDeliver(), let selected = await waitForDialog({ await dialogs.chooseDestination(details) }),
            canDeliver()
        else { return cancelPreparedSave() }
        guard selected.isFileURL, !selected.hasDirectoryPath else { return fail(.system(code: Int(EINVAL))) }
        let destination = Self.named(selected, for: snapshot.format).standardizedFileURL

        var overwrite = false
        while canDeliver() {
            apply(.commit)
            do throws(SinkError) {
                let saved = try await files.save(snapshot, to: destination, overwrite: overwrite)
                return complete(.saved(saved), callerCanceled: Task.isCancelled)
            } catch .destinationExists {
                guard !overwrite else { return fail(.destinationExists(destination)) }
                apply(.destinationCollision)
                guard canDeliver(), await waitForDialog({ await dialogs.confirmReplacement(destination) }) == true
                else { break }
                overwrite = true
            } catch {
                return fail(Self.failure(for: error))
            }
        }
        return cancelPreparedSave()
    }

    private func waitForDialog<Value: Sendable>(_ show: @escaping @MainActor () async -> Value?) async -> Value? {
        let task = Task<Value?, Never> {
            guard !Task.isCancelled else { return nil }
            return await show()
        }
        operation?.dismissDialog = { task.cancel() }
        defer { operation?.dismissDialog = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func cancelPreparedSave() -> ExportOutcome {
        if state == .encoding { apply(.cancel) }
        return .canceled
    }

    private func complete(_ completed: ExportOutcome, callerCanceled: Bool = false) -> ExportOutcome {
        if operation?.cancelRequested == true || callerCanceled {
            apply(.cancel)
            return .alreadyCompleted(completed)
        }
        apply(.committed)
        return completed
    }

    /// Cancels the running export. Before the commit nothing is written; during the commit the
    /// write completes and the outcome says so.
    public func cancel() {
        automaticBatch?.cancelRequested = true
        cancelOperation()
    }

    /// Closing one editor cancels only the snapshot, upload and batch owned by its document.
    public func cancel(documentID: DocumentID) {
        if automaticBatch?.documentID == documentID { automaticBatch?.cancelRequested = true }
        guard operation?.documentID == documentID else { return }
        cancelOperation()
    }

    private func cancelOperation() {
        guard var current = operation else { return }
        current.cancelRequested = true
        operation = current
        current.dismissDialog?()
        uploadTask?.cancel()
        if current.awaitingDragReceiver {
            revokePendingDrag()
            return
        }
        switch state {
        case .requested, .snapshotting, .sanitizing, .rendering, .encoding:
            snapshotTask?.cancel()
            apply(.cancel)
        default:
            break
        }
    }

    /// The document changed or its editor closed: revokes its pending drag, which blocks a write
    /// not yet claimed. A receiver that already claimed the lease can finish.
    func invalidatePendingDrag(documentID: DocumentID) {
        guard pendingDrag?.documentID == documentID else { return }
        revokePendingDrag()
    }

    private func revokePendingDrag() {
        guard let pending = pendingDrag else { return }
        pending.lease.revoke()
        drag.dismiss()
    }

    /// The automatic batch the settings choose right now. Call it synchronously when the capture
    /// completes, before anything else can run on the main actor, and pass it to
    /// `runAutomaticExports`.
    public func automaticExportPlan() -> AutomaticExportPlan {
        let chosen = settings.preferences
        let save: AutomaticExportPlan.Save? =
            chosen.autoSave
            ? chosen.preferredSaveFolderBookmark.flatMap(folders.resolveFolder).map { .folder($0) }
                ?? .folderUnavailable : nil
        return AutomaticExportPlan(
            copy: chosen.autoCopy, save: save, saveFolderSelection: settings.saveFolderSelection,
            upload: chosen.githubUpload.flatMap { $0.automatic ? $0.destination : nil },
            uploadConsentID: settings.githubUploadConsentID)
    }

    /// Automatic copy/save/upload after a capture, only the steps `plan` chose (off by default).
    public func runAutomaticExports(
        _ plan: AutomaticExportPlan, for session: DocumentSession,
        currentSession: @escaping @MainActor @Sendable () -> DocumentSession?
    ) async -> [ExportOutcome] {
        guard automaticBatch == nil, operation == nil else { return [.failed(.busy)] }
        automaticBatch = Operation(id: UUID(), documentID: session.document.id)
        defer { automaticBatch = nil }
        let settings = self.settings
        // `plan` holds the steps and the save folder chosen when the capture was taken. A step runs
        // only if it is still allowed when it starts, and the same live check runs again after its
        // render.
        var outcomes: [ExportOutcome] = []
        let copyCheck = { @MainActor () -> AutomaticStepCheck in settings.preferences.autoCopy ? .allowed : .revoked }
        if plan.copy, copyCheck() == .allowed {
            outcomes.append(
                await export(
                    .action(.copy), session: session, currentSession: currentSession, uploadConsentID: nil,
                    isAllowed: copyCheck))
        }
        guard automaticBatch?.cancelRequested == false, !Task.isCancelled else { return outcomes }
        if let save = plan.save {
            let saveCheck = { @MainActor [folders] () -> AutomaticStepCheck in
                // Off, or another folder chosen since the capture: skipped without a message.
                guard settings.preferences.autoSave, settings.saveFolderSelection == plan.saveFolderSelection
                else { return .revoked }
                // The planned folder (its bookmark may have been renewed after a move) that does
                // not resolve, such as an ejected volume, is a failure.
                guard case .folder(let folder) = save,
                    let live = settings.preferences.preferredSaveFolderBookmark.flatMap(folders.resolveFolder)
                else { return .failed(.accessDenied) }
                return live == folder ? .allowed : .revoked
            }
            switch saveCheck() {
            case .allowed:
                if case .folder(let folder) = save {
                    outcomes.append(
                        await export(
                            .action(.saveToFolder(folder)), session: session, currentSession: currentSession,
                            uploadConsentID: nil, isAllowed: saveCheck))
                }
            case .revoked: break
            case .failed(let failure): outcomes.append(.failed(failure))
            }
        }
        guard automaticBatch?.cancelRequested == false, !Task.isCancelled else { return outcomes }
        if let destination = plan.upload, let live = settings.preferences.githubUpload, live.automatic,
            live.destination == destination, settings.githubUploadConsentID == plan.uploadConsentID
        {
            outcomes.append(
                await export(
                    .action(.upload(to: destination, intent: UUID())), session: session,
                    currentSession: currentSession, uploadConsentID: plan.uploadConsentID, isAllowed: { .allowed }))
        }
        return outcomes
    }

    private func options(for request: Request) -> ExportOptions {
        switch request {
        case .action(let action): return exportOptions(for: action)
        case .optimizedSave:
            var options = settings.exportOptions
            options.formatChoice = .automatic
            return options
        }
    }

    public func exportOptions(for action: ExportAction) -> ExportOptions {
        var options = settings.exportOptions
        switch action {
        case .copy, .print: options.formatChoice = .fixed(.png)
        case .save(_, let format, _): options.formatChoice = format
        case .saveToFolder, .drag, .upload: break
        }
        return options
    }

    /// `url` with an extension for `format`: kept when it already names it (.jpg or .jpeg for
    /// JPEG), replaced otherwise.
    static func named(_ url: URL, for format: ExportFormat) -> URL {
        let current = url.pathExtension.lowercased()
        let matches =
            switch format {
            case .png: current == "png"
            case .jpeg: current == "jpg" || current == "jpeg"
            case .heic: current == "heic"
            }
        return matches ? url : url.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    // MARK: Helpers

    private func fail(_ failure: ExportFailure) -> ExportOutcome {
        if state == .canceled { return .canceled }
        apply(.fail(failure))
        return .failed(failure)
    }

    private func apply(_ event: ExportEvent) {
        guard let current = state else { return }
        do {
            state = try current.next(event)
        } catch {
            assertionFailure("\(error)")
        }
    }

    static func failure(for error: SinkError) -> ExportFailure {
        switch error {
        case .clipboardWriteFailed: .clipboardFailed
        case .printFailed: .printFailed
        case .destinationExists: .destinationExists(nil)
        case .nameTooLong: .nameTooLong
        case .accessDenied: .accessDenied
        case .diskFull: .diskFull
        case .volumeUnavailable: .volumeUnavailable
        case .writeFailed(let code): .system(code: code)
        case .leftover(let name): .leftover(name: name)
        }
    }
}
