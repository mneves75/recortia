import Foundation

// The diagnostics file's line format (B-10): ISO-8601 UTC time with milliseconds, the event name,
// then key=value pairs. Every name and value below is a literal or a number: nothing is derived
// from `String(describing:)`, so renaming a Swift case cannot change or widen what is written.
extension DiagnosticEvent {
    /// Every event name the file can contain; the E2E scenario admits nothing else.
    public static let names: Set<String> = [
        "app.launched", "diagnostics.turned_on", "capture.started", "capture.finished", "capture.cancelled",
        "capture.failed", "export.finished", "export.failed", "export.cancelled", "permission.status",
        "ocr.finished", "ocr.failed", "qr.finished", "qr.failed", "scroll.finished", "scroll.failed",
        "masking.finished",
    ]

    public var name: String {
        switch self {
        case .appLaunched: "app.launched"
        case .diagnosticsTurnedOn: "diagnostics.turned_on"
        case .captureStarted: "capture.started"
        case .captureFinished: "capture.finished"
        case .captureCancelled: "capture.cancelled"
        case .captureFailed: "capture.failed"
        case .exportFinished: "export.finished"
        case .exportFailed: "export.failed"
        case .exportCancelled: "export.cancelled"
        case .permissionStatus: "permission.status"
        case .textRecognitionFinished: "ocr.finished"
        case .textRecognitionFailed: "ocr.failed"
        case .qrDecodingFinished: "qr.finished"
        case .qrDecodingFailed: "qr.failed"
        case .scrollCaptureFinished: "scroll.finished"
        case .scrollCaptureFailed: "scroll.failed"
        case .autoMaskingFinished: "masking.finished"
        }
    }

    /// One line without its newline.
    public func line(at date: Date) -> String {
        let time = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return ([time, name] + fields.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
    }

    private var fields: [(key: String, value: String)] {
        switch self {
        case .appLaunched(let versions), .diagnosticsTurnedOn(let versions):
            [("app", versions.app.text), ("build", "\(versions.build)"), ("macos", versions.macOS.text)]
        case .captureStarted(let mode, let purpose):
            [("mode", mode.token), ("purpose", purpose.token)]
        case .captureFinished(let mode, let purpose, let duration, let width, let height):
            [
                ("mode", mode.token), ("purpose", purpose.token), Self.milliseconds(duration), ("width", "\(width)"),
                ("height", "\(height)"),
            ]
        case .captureCancelled(let mode, let duration):
            [("mode", mode.token), Self.milliseconds(duration)]
        case .captureFailed(let mode, let failure, let duration):
            [("mode", mode.token)] + failure.fields + [Self.milliseconds(duration)]
        case .exportFinished(let sink, let format, let duration), .exportCancelled(let sink, let format, let duration):
            [("sink", sink.token), ("format", format.token), Self.milliseconds(duration)]
        case .exportFailed(let sink, let format, let failure, let duration):
            [("sink", sink.token), ("format", format.token)] + failure.fields + [Self.milliseconds(duration)]
        case .permissionStatus(let permission, let granted):
            [("permission", permission.token), ("granted", granted ? "true" : "false")]
        case .textRecognitionFinished(let lines, let duration):
            [("lines", "\(lines)"), Self.milliseconds(duration)]
        case .qrDecodingFinished(let codes, let duration):
            [("codes", "\(codes)"), Self.milliseconds(duration)]
        case .textRecognitionFailed(let duration), .qrDecodingFailed(let duration):
            [Self.milliseconds(duration)]
        case .scrollCaptureFinished(let frames, let automatic, let partial, let duration):
            [
                ("frames", "\(frames)"), ("automatic", automatic ? "true" : "false"),
                ("partial", partial ? "true" : "false"), Self.milliseconds(duration),
            ]
        case .scrollCaptureFailed(let failure, let frames):
            [("failure", failure.token), ("frames", "\(frames)")]
        case .autoMaskingFinished(let regions, let outcome, let duration):
            [("regions", "\(regions)"), ("outcome", outcome.token), Self.milliseconds(duration)]
        }
    }

    private static func milliseconds(_ duration: Duration) -> (key: String, value: String) {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return ("duration_ms", "0") }
        // Capped far beyond any real duration so the multiplication cannot overflow.
        let total = min(seconds, 1_000_000_000) * 1000 + attoseconds / 1_000_000_000_000_000
        return ("duration_ms", "\(total)")
    }
}

extension DiagnosticVersion {
    /// The leading numeric components of a version string such as `CFBundleShortVersionString`
    /// ("0.19.0", "26.1"); a component that is not a short number, and everything after it, is 0.
    public init(parsing text: String) {
        var numbers: [Int] = []
        for component in text.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false).prefix(3) {
            guard component.count <= 6, let number = Int(component), number >= 0 else { break }
            numbers.append(number)
        }
        numbers += Array(repeating: 0, count: 3 - numbers.count)
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    var text: String { "\(major).\(minor).\(patch)" }
}

extension DiagnosticCaptureMode {
    var token: String {
        switch self {
        case .region: "region"
        case .display: "display"
        case .window: "window"
        case .repeatRegion: "repeat_region"
        }
    }
}

extension DiagnosticCapturePurpose {
    var token: String {
        switch self {
        case .edit: "edit"
        case .recognizeText: "recognize_text"
        }
    }
}

extension DiagnosticCaptureFailure {
    var fields: [(key: String, value: String)] {
        switch self {
        case .permissionDenied: [("failure", "permission_denied")]
        case .targetUnavailable: [("failure", "target_unavailable")]
        case .displayChanged: [("failure", "display_changed")]
        case .screenLocked: [("failure", "screen_locked")]
        case .protectedContent: [("failure", "protected_content")]
        case .system(let code): [("failure", "system"), ("code", "\(code)")]
        }
    }
}

extension DiagnosticExportSink {
    var token: String {
        switch self {
        case .clipboard: "clipboard"
        case .file: "file"
        case .drag: "drag"
        case .github: "github"
        case .print: "print"
        }
    }
}

extension DiagnosticImageFormat {
    var token: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpeg"
        case .heic: "heic"
        case .automatic: "automatic"
        }
    }
}

extension DiagnosticExportFailure {
    var fields: [(key: String, value: String)] {
        switch self {
        case .busy: [("failure", "busy")]
        case .upload(let upload): [("failure", "upload"), ("upload", upload.token)]
        case .renderFailed: [("failure", "render_failed")]
        case .encodeFailed: [("failure", "encode_failed")]
        case .budgetExceeded: [("failure", "budget_exceeded")]
        case .clipboardFailed: [("failure", "clipboard_failed")]
        case .accessDenied: [("failure", "access_denied")]
        case .destinationExists: [("failure", "destination_exists")]
        case .nameTooLong: [("failure", "name_too_long")]
        case .diskFull: [("failure", "disk_full")]
        case .volumeUnavailable: [("failure", "volume_unavailable")]
        case .staleDocument: [("failure", "stale_document")]
        case .system(let code): [("failure", "system"), ("code", "\(code)")]
        case .leftover: [("failure", "leftover")]
        case .maskingUnfinished: [("failure", "masking_unfinished")]
        case .printFailed: [("failure", "print_failed")]
        }
    }
}

extension DiagnosticUploadFailure {
    var token: String {
        switch self {
        case .invalidDestination: "invalid_destination"
        case .missingCredential: "missing_credential"
        case .invalidCredential: "invalid_credential"
        case .credentialsUnavailable: "credentials_unavailable"
        case .publicRepository: "public_repository"
        case .tooLarge: "too_large"
        case .accessDenied: "access_denied"
        case .rateLimited: "rate_limited"
        case .conflict: "conflict"
        case .staleDocument: "stale_document"
        case .canceled: "canceled"
        case .network: "network"
        case .completionUnknown: "completion_unknown"
        case .invalidResponse: "invalid_response"
        }
    }
}

extension DiagnosticPermission {
    var token: String {
        switch self {
        case .screenRecording: "screen_recording"
        case .accessibility: "accessibility"
        }
    }
}

extension DiagnosticScrollFailure {
    var token: String {
        switch self {
        case .targetLost: "target_lost"
        case .permissionRevoked: "permission_revoked"
        case .displayChanged: "display_changed"
        case .screenLocked: "screen_locked"
        case .noFrames: "no_frames"
        }
    }
}

extension DiagnosticMaskingOutcome {
    var token: String {
        switch self {
        case .masked: "masked"
        case .failed: "failed"
        case .timedOut: "timed_out"
        }
    }
}
