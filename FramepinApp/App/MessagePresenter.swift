import AppKit
import Domain
import Features

/// A user-facing message: plain text, never an icon or color alone (UX-01).
struct UserMessage: Equatable {
    var title: String
    var detail: String
    /// Offers a button that opens the Screen Recording pane of System Settings.
    var offersScreenRecordingSettings = false
}

/// Shows messages as standard alerts. Content-free: never includes image data, OCR text,
/// window titles, or paths (PRIV-01).
enum MessagePresenter {
    static func present(_ message: UserMessage) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.detail
        alert.alertStyle = .informational
        if message.offersScreenRecordingSettings {
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Not Now"))
        } else {
            alert.addButton(withTitle: String(localized: "OK"))
        }
        let response = alert.runModal()
        if message.offersScreenRecordingSettings, response == .alertFirstButtonReturn,
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
}

extension UserMessage {
    static func capture(_ failure: CaptureFailure) -> UserMessage {
        switch failure {
        case .permissionDenied:
            UserMessage(
                title: String(localized: "Screen Recording is off for Framepin"),
                detail: String(
                    localized: """
                        Framepin can capture your screen only with Screen Recording permission. \
                        Opening, pasting, editing, and exporting images keep working without it. \
                        To allow capture, turn on Framepin in System Settings › Privacy & Security › Screen & System Audio Recording.
                        """),
                offersScreenRecordingSettings: true)
        case .targetUnavailable:
            UserMessage(
                title: String(localized: "Nothing was captured"),
                detail: String(localized: "The window or display you chose is no longer available."))
        case .displayChanged:
            UserMessage(
                title: String(localized: "Nothing was captured"),
                detail: String(localized: "Your display arrangement changed. Select the area again."))
        case .screenLocked:
            UserMessage(
                title: String(localized: "Nothing was captured"),
                detail: String(localized: "The screen locked during the capture."))
        case .protectedContent:
            UserMessage(
                title: String(localized: "Nothing was captured"),
                detail: String(localized: "The selected content is protected and cannot be captured."))
        case .system(let code):
            UserMessage(
                title: String(localized: "Nothing was captured"),
                detail: String(localized: "The system reported an error (\(code))."))
        }
    }

    static func importFailure(_ failure: ImportFailure) -> UserMessage {
        let title = String(localized: "The image could not be opened")
        let detail =
            switch failure {
            case .nothingToPaste: String(localized: "The clipboard does not contain a PNG or JPEG image.")
            case .tooLarge: String(localized: "The file is larger than 64 MB.")
            case .tooManyPixels: String(localized: "The image is larger than 40 megapixels.")
            case .invalidDimensions: String(localized: "The image has invalid dimensions.")
            case .unsupportedFormat: String(localized: "Only PNG and JPEG images are supported.")
            case .multipleFrames: String(localized: "Animated or multi-page images are not supported.")
            case .corrupt: String(localized: "The image data is damaged.")
            case .unreadable: String(localized: "The file could not be read.")
            }
        return UserMessage(title: title, detail: detail)
    }

    static func export(_ failure: ExportFailure) -> UserMessage {
        let detail =
            switch failure {
            case .renderFailed, .encodeFailed: String(localized: "The image could not be rendered.")
            case .budgetExceeded: String(localized: "The image is too large to export.")
            case .clipboardFailed:
                String(localized: "The clipboard could not be updated. Its previous content is unchanged.")
            case .accessDenied:
                String(localized: "Framepin cannot write to that folder. Choose a folder in Settings › Export.")
            case .destinationExists: String(localized: "A file with that name already exists.")
            case .diskFull: String(localized: "The disk is full.")
            case .volumeUnavailable: String(localized: "The destination volume is not available.")
            case .staleDocument: String(localized: "The image changed while exporting. Try again.")
            case .system(let code): String(localized: "The system reported an error (\(code)).")
            }
        return UserMessage(title: String(localized: "Nothing was exported"), detail: detail)
    }

    static func scroll(_ failure: ScrollFailure) -> UserMessage {
        let detail =
            switch failure {
            case .targetLost: String(localized: "The scrolling area is no longer available, so capture stopped.")
            case .permissionRevoked:
                String(localized: "Screen Recording permission was turned off, so capture stopped.")
            case .displayChanged: String(localized: "Your display arrangement changed, so capture stopped.")
            case .screenLocked: String(localized: "The screen locked, so capture stopped.")
            case .noFrames: String(localized: "No content was collected. Scroll the area while capturing.")
            }
        return UserMessage(title: String(localized: "Scrolling capture stopped"), detail: detail)
    }
}
