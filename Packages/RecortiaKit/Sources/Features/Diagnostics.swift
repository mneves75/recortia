import Domain
import Foundation
import MacPlatform

/// Where feature models report the few outcomes the optional diagnostics file records (B-10):
/// capture, export, permissions, recognition, scrolling capture, automatic masking and launch.
/// Views never call it.
@MainActor
public protocol DiagnosticsSink: AnyObject {
    func record(_ event: DiagnosticEvent)
}

/// The live sink: does nothing while Settings › Privacy › "Write a diagnostics file" is off, and
/// otherwise hands each event, with the time it happened, to the one `DiagnosticsLog` writer in
/// order. It never waits for the file, so the UI never blocks on it.
@MainActor
public final class DiagnosticsRecorder: DiagnosticsSink {
    /// Writes queued while the writer is behind; past this, new events are dropped.
    static let maxPending = 64

    public let log: DiagnosticsLog
    private let settings: SettingsStore
    private let clock: any FeatureClock
    private let versions: DiagnosticVersions
    private var tail: Task<Void, Never>?
    private var pending = 0
    /// The last status written per permission since the switch was turned on.
    private var permissions: [DiagnosticPermission: Bool] = [:]

    public init(log: DiagnosticsLog, settings: SettingsStore, clock: any FeatureClock, versions: DiagnosticVersions) {
        self.log = log
        self.settings = settings
        self.clock = clock
        self.versions = versions
    }

    public var isOn: Bool { settings.preferences.writesDiagnosticsFile }

    /// The Settings switch. Turning it on starts the file with the versions; turning it off stops
    /// writing and keeps the file until `delete`.
    public func setOn(_ on: Bool) {
        let wasOn = isOn
        settings.update { $0.writesDiagnosticsFile = on }
        guard isOn, !wasOn else { return }
        permissions = [:]
        record(.diagnosticsTurnedOn(versions))
    }

    public func recordLaunch() {
        record(.appLaunched(versions))
    }

    public func record(_ event: DiagnosticEvent) {
        // A full queue drops the event before the permission memory sees it, so a dropped change
        // is written at its next report.
        guard isOn, pending < Self.maxPending else { return }
        if case .permissionStatus(let permission, let granted) = event {
            guard permissions[permission] != granted else { return }
            permissions[permission] = granted
        }
        pending += 1
        let date = clock.now()
        enqueue { log in
            await log.append(event, at: date)
        } completion: { [weak self] in
            self?.pending -= 1
        }
    }

    /// Waits until every event recorded so far reached the writer.
    public func flush() async {
        await tail?.value
    }

    /// Whether a diagnostics file exists, after the writes recorded so far.
    public func fileExists() async -> Bool {
        await !existingFiles().isEmpty
    }

    public func existingFiles() async -> [URL] {
        await flush()
        return await log.existingFiles()
    }

    /// Deletes both files after the writes recorded so far; true when none is left.
    @discardableResult
    public func delete() async -> Bool {
        await flush()
        return await log.delete()
    }

    /// Chains `work` after the previous write, so lines keep the order they were recorded in.
    private func enqueue(
        _ work: @escaping @Sendable (DiagnosticsLog) async -> Bool, completion: @escaping @MainActor () -> Void
    ) {
        let previous = tail
        let log = self.log
        tail = Task {
            await previous?.value
            _ = await work(log)  // a dropped line is the writer's documented outcome
            completion()
        }
    }
}

// The allowlisted mappings from typed feature values to diagnostic cases: exhaustive switches, so
// a new case with a payload cannot reach the file without a decision here.

extension DiagnosticCaptureMode {
    init(_ mode: CaptureMode) {
        self =
            switch mode {
            case .region: .region
            case .display: .display
            case .window: .window
            case .repeatRegion: .repeatRegion
            }
    }
}

extension DiagnosticCapturePurpose {
    init(_ purpose: CapturePurpose) {
        self =
            switch purpose {
            case .edit: .edit
            case .recognizeText: .recognizeText
            }
    }
}

extension DiagnosticCaptureFailure {
    init(_ failure: CaptureFailure) {
        self =
            switch failure {
            case .permissionDenied: .permissionDenied
            case .targetUnavailable: .targetUnavailable
            case .displayChanged: .displayChanged
            case .screenLocked: .screenLocked
            case .protectedContent: .protectedContent
            case .system(let code): .system(code: code)
            }
    }
}

extension DiagnosticExportFailure {
    init(_ failure: ExportFailure) {
        self =
            switch failure {
            case .busy: .busy
            case .upload(let upload): .upload(DiagnosticUploadFailure(upload))
            case .renderFailed: .renderFailed
            case .encodeFailed: .encodeFailed
            case .budgetExceeded: .budgetExceeded
            case .clipboardFailed: .clipboardFailed
            case .accessDenied: .accessDenied
            case .destinationExists: .destinationExists  // the file it names is not recorded
            case .nameTooLong: .nameTooLong
            case .diskFull: .diskFull
            case .volumeUnavailable: .volumeUnavailable
            case .staleDocument: .staleDocument
            case .system(let code): .system(code: code)
            case .leftover: .leftover  // the entry's name is not recorded
            case .maskingUnfinished: .maskingUnfinished
            case .printFailed: .printFailed
            }
    }
}

extension DiagnosticUploadFailure {
    init(_ failure: GitHubUploadFailure) {
        self =
            switch failure {
            case .invalidDestination: .invalidDestination
            case .missingCredential: .missingCredential
            case .invalidCredential: .invalidCredential
            case .credentialsUnavailable: .credentialsUnavailable
            case .publicRepository: .publicRepository
            case .tooLarge: .tooLarge
            case .accessDenied: .accessDenied
            case .rateLimited: .rateLimited
            case .conflict: .conflict
            case .staleDocument: .staleDocument
            case .canceled: .canceled
            case .network: .network
            case .completionUnknown: .completionUnknown
            case .invalidResponse: .invalidResponse
            }
    }
}

extension DiagnosticScrollFailure {
    init(_ failure: ScrollFailure) {
        self =
            switch failure {
            case .targetLost: .targetLost
            case .permissionRevoked: .permissionRevoked
            case .displayChanged: .displayChanged
            case .screenLocked: .screenLocked
            case .noFrames: .noFrames
            }
    }
}
