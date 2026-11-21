// What the optional diagnostics file can say (B-10, SPEC §7). Declarations only:
// `DiagnosticsSourceScanTests` admits no payload here but Int, Bool, Duration and the closed types
// this file declares, so no text, path, file name, pixel, error message or arbitrary value can
// reach the file. Features maps each typed failure to these cases with exhaustive switches.

/// One line of the diagnostics file; `DiagnosticLine.swift` writes it.
public enum DiagnosticEvent: Hashable, Sendable {
    case appLaunched(DiagnosticVersions)
    case diagnosticsTurnedOn(DiagnosticVersions)
    case captureStarted(mode: DiagnosticCaptureMode, purpose: DiagnosticCapturePurpose)
    case captureFinished(
        mode: DiagnosticCaptureMode, purpose: DiagnosticCapturePurpose, duration: Duration, width: Int, height: Int)
    case captureCancelled(mode: DiagnosticCaptureMode, duration: Duration)
    case captureFailed(mode: DiagnosticCaptureMode, failure: DiagnosticCaptureFailure, duration: Duration)
    case exportFinished(sink: DiagnosticExportSink, format: DiagnosticImageFormat, duration: Duration)
    case exportFailed(
        sink: DiagnosticExportSink, format: DiagnosticImageFormat, failure: DiagnosticExportFailure,
        duration: Duration)
    case exportCancelled(sink: DiagnosticExportSink, format: DiagnosticImageFormat, duration: Duration)
    /// Recorded when the status differs from the last one this file was told.
    case permissionStatus(permission: DiagnosticPermission, granted: Bool)
    case textRecognitionFinished(lines: Int, duration: Duration)
    case textRecognitionFailed(duration: Duration)
    case qrDecodingFinished(codes: Int, duration: Duration)
    case qrDecodingFailed(duration: Duration)
    case scrollCaptureFinished(frames: Int, automatic: Bool, partial: Bool, duration: Duration)
    case scrollCaptureFailed(failure: DiagnosticScrollFailure, frames: Int)
    case autoMaskingFinished(regions: Int, outcome: DiagnosticMaskingOutcome, duration: Duration)
}

public struct DiagnosticVersion: Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

/// Recortia's version and build and the macOS version, as numbers.
public struct DiagnosticVersions: Hashable, Sendable {
    public let app: DiagnosticVersion
    public let build: Int
    public let macOS: DiagnosticVersion

    public init(app: DiagnosticVersion, build: Int, macOS: DiagnosticVersion) {
        self.app = app
        self.build = build
        self.macOS = macOS
    }
}

public enum DiagnosticCaptureMode: Hashable, Sendable {
    case region
    case display
    case window
    case repeatRegion
}

public enum DiagnosticCapturePurpose: Hashable, Sendable {
    case edit
    case recognizeText
}

public enum DiagnosticCaptureFailure: Hashable, Sendable {
    case permissionDenied
    case targetUnavailable
    case displayChanged
    case screenLocked
    case protectedContent
    case system(code: Int)
}

public enum DiagnosticExportSink: Hashable, Sendable {
    case clipboard
    case file
    case drag
    case github
}

public enum DiagnosticImageFormat: Hashable, Sendable {
    case png
    case jpeg
    case automatic
}

public enum DiagnosticExportFailure: Hashable, Sendable {
    case busy
    case upload(DiagnosticUploadFailure)
    case renderFailed
    case encodeFailed
    case budgetExceeded
    case clipboardFailed
    case accessDenied
    case destinationExists
    case nameTooLong
    case diskFull
    case volumeUnavailable
    case staleDocument
    case system(code: Int)
    case leftover
    case maskingUnfinished
}

public enum DiagnosticUploadFailure: Hashable, Sendable {
    case invalidDestination
    case missingCredential
    case invalidCredential
    case credentialsUnavailable
    case publicRepository
    case tooLarge
    case accessDenied
    case rateLimited
    case conflict
    case staleDocument
    case canceled
    case network
    case completionUnknown
    case invalidResponse
}

public enum DiagnosticPermission: Hashable, Sendable {
    case screenRecording
    case accessibility
}

public enum DiagnosticScrollFailure: Hashable, Sendable {
    case targetLost
    case permissionRevoked
    case displayChanged
    case screenLocked
    case noFrames
}

public enum DiagnosticMaskingOutcome: Hashable, Sendable {
    case masked
    case failed
    case timedOut
}
