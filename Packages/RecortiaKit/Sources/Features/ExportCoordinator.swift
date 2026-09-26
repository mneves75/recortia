import Domain
import Foundation
import MacPlatform
import Observation

public enum ExportAction: Hashable, Sendable {
    /// Copy Image: always a sanitized PNG only (FR-07).
    case copy
    /// Save to a user-chosen URL; `overwriteConfirmed` only after the user confirmed replacing a file.
    case save(to: URL, overwriteConfirmed: Bool)
    /// Save with a collision-free name into a previously authorized folder.
    case saveToFolder(URL)
    case drag
}

public enum ExportOutcome: Hashable, Sendable {
    case copied
    case saved(URL)
    case dragged
    /// Cancel arrived after the write was committed; the action happened and cannot be retracted.
    indirect case alreadyCompleted(ExportOutcome)
    case canceled
    case failed(ExportFailure)
    /// Another export is running; nothing was done.
    case rejectedBusy

    public var didWrite: Bool {
        switch self {
        case .copied, .saved, .dragged, .alreadyCompleted: true
        case .canceled, .failed, .rejectedBusy: false
        }
    }
}

/// Drives `ExportState` for Copy, Save, and Drag (FR-07, EXP-02).
///
/// Order: take an immutable snapshot through the export pipeline, verify that it still matches
/// the live document (revision and privacy epoch), then commit to exactly one sink. The pipeline
/// performs sanitizing, rendering, and encoding in one call, so the state reports `.rendering`
/// while it runs and `.encoding` once the encoded bytes are verified. Success is reported only
/// after the sink returns. Cancel before the commit leaves every sink untouched; cancel during
/// the commit lets the write finish and reports `.alreadyCompleted`. A drag stays uncommitted
/// until a receiver accepts the file, so a drag the user abandons is a plain cancellation.
@MainActor
@Observable
public final class ExportCoordinator {
    public private(set) var state: ExportState?
    public private(set) var lastOutcome: ExportOutcome?
    private var operation: Operation?

    @ObservationIgnored private let exporter: any ExportService
    @ObservationIgnored private let clipboard: any ClipboardSinkService
    @ObservationIgnored private let files: any FileSinkService
    @ObservationIgnored private let drag: any DragSinkService
    @ObservationIgnored private let folders: any SaveFolderService
    @ObservationIgnored private let clock: any FeatureClock
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var snapshotTask: Task<ShareSnapshot, any Error>?

    private struct Operation {
        let id: UUID
        var cancelRequested = false
        /// A drag is offered and waiting for a receiver; cancel is decided when it ends.
        var awaitingDragReceiver = false
    }

    public init(
        exporter: any ExportService, clipboard: any ClipboardSinkService, files: any FileSinkService,
        drag: any DragSinkService,
        folders: any SaveFolderService, clock: any FeatureClock, settings: SettingsStore
    ) {
        self.exporter = exporter
        self.clipboard = clipboard
        self.files = files
        self.drag = drag
        self.folders = folders
        self.clock = clock
        self.settings = settings
    }

    public var isBusy: Bool { operation != nil }

    /// Exports `session` through one sink. `currentSession` returns the live session (nil once
    /// its editor closed) and is consulted after the snapshot, before anything is committed.
    public func export(
        _ action: ExportAction, session: DocumentSession, currentSession: @escaping () -> DocumentSession?
    ) async -> ExportOutcome {
        guard operation == nil else { return .rejectedBusy }
        let id = UUID()
        operation = Operation(id: id)
        defer {
            if operation?.id == id { operation = nil }
            snapshotTask = nil
        }

        state = .requested
        apply(.snapshot)
        apply(.sanitize)
        apply(.render)

        let options: ExportOptions
        do {
            options = try exportOptions(for: action).validated()
        } catch {
            return fail(.encodeFailed)
        }
        let date = clock.now()
        let exporter = self.exporter
        let task = Task<ShareSnapshot, any Error> {
            try await exporter.makeSnapshot(of: session, options: options, date: date)
        }
        snapshotTask = task
        let result = await task.result
        if operation?.cancelRequested == true { return finish(.canceled) }

        let snapshot: ShareSnapshot
        switch result {
        case .success(let value):
            snapshot = value
        case .failure(let error):
            return fail((error as? ExportServiceError)?.failure ?? .renderFailed)
        }
        apply(.encode)

        guard let current = currentSession(), current.document.id == snapshot.documentID,
            current.revision == snapshot.revision, current.privacyEpoch == snapshot.privacyEpoch
        else { return fail(.staleDocument) }

        do throws(SinkError) {
            let completed: ExportOutcome
            switch action {
            case .copy:
                apply(.commit)
                try clipboard.write(snapshot)
                completed = .copied
            case .save(let url, let overwrite):
                apply(.commit)
                completed = .saved(try await files.save(snapshot, to: url, overwrite: overwrite))
            case .saveToFolder(let folder):
                apply(.commit)
                completed = .saved(try await files.saveUnique(snapshot, in: folder))
            case .drag:
                operation?.awaitingDragReceiver = true
                let delivery = try await drag.deliver(snapshot)
                operation?.awaitingDragReceiver = false
                switch delivery {
                case .canceledByUser:
                    apply(.cancel)
                    return finish(.canceled)
                case .delivered:
                    apply(.commit)
                    completed = .dragged
                }
            }
            if operation?.cancelRequested == true {
                apply(.cancel)
                return finish(.alreadyCompleted(completed))
            }
            apply(.committed)
            return finish(completed)
        } catch {
            return fail(Self.failure(for: error))
        }
    }

    /// Cancels the running export. Before the commit nothing is written; during the commit the
    /// write completes and the outcome says so.
    public func cancel() {
        guard var current = operation else { return }
        current.cancelRequested = true
        operation = current
        guard !current.awaitingDragReceiver else { return }
        switch state {
        case .requested, .snapshotting, .sanitizing, .rendering, .encoding:
            snapshotTask?.cancel()
            apply(.cancel)
        default:
            break
        }
    }

    /// Automatic copy/save after a capture, only when the user enabled them (off by default).
    public func runAutomaticExports(
        for session: DocumentSession, currentSession: @escaping () -> DocumentSession?
    ) async -> [ExportOutcome] {
        let preferences = settings.preferences
        var outcomes: [ExportOutcome] = []
        if preferences.autoCopy {
            outcomes.append(await export(.copy, session: session, currentSession: currentSession))
        }
        if preferences.autoSave {
            if let bookmark = preferences.preferredSaveFolderBookmark,
                let folder = folders.resolveFolder(bookmark: bookmark)
            {
                outcomes.append(await export(.saveToFolder(folder), session: session, currentSession: currentSession))
            } else {
                outcomes.append(.failed(.accessDenied))
            }
        }
        return outcomes
    }

    public func exportOptions(for action: ExportAction) -> ExportOptions {
        var options = settings.preferences.exportOptions
        if action == .copy { options.format = .png }
        return options
    }

    // MARK: Helpers

    private func fail(_ failure: ExportFailure) -> ExportOutcome {
        if state == .canceled { return finish(.canceled) }
        apply(.fail(failure))
        return finish(.failed(failure))
    }

    private func finish(_ outcome: ExportOutcome) -> ExportOutcome {
        lastOutcome = outcome
        return outcome
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
        case .destinationExists: .destinationExists
        case .accessDenied: .accessDenied
        case .diskFull: .diskFull
        case .volumeUnavailable: .volumeUnavailable
        case .writeFailed(let code): .system(code: code)
        }
    }
}
