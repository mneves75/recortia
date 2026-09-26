import Foundation

/// Every command the menu-bar menu and global shortcuts can trigger (FR-01).
enum AppCommand: String, CaseIterable, Identifiable, Sendable {
    case captureRegion
    case captureDisplay
    case captureWindow
    case captureWithDelay
    case repeatLastRegion
    case scrollingCapture
    case captureText
    case openImage
    case pasteImage
    case bringPinsForward
    case closeAllPins
    case settings
    case about
    case quit

    var id: String { rawValue }

    /// Commands a user may bind to a global shortcut. None has a default key combination.
    static let shortcutAssignable: [AppCommand] = [
        .captureRegion, .captureDisplay, .captureWindow, .captureWithDelay, .repeatLastRegion, .scrollingCapture,
        .captureText,
    ]

    var title: String {
        switch self {
        case .captureRegion: String(localized: "Capture Region")
        case .captureDisplay: String(localized: "Capture Display")
        case .captureWindow: String(localized: "Capture Window")
        case .captureWithDelay: String(localized: "Capture with Delay…")
        case .repeatLastRegion: String(localized: "Repeat Last Region")
        case .scrollingCapture: String(localized: "Scrolling Capture")
        case .captureText: String(localized: "Capture Text (OCR)")
        case .openImage: String(localized: "Open Image…")
        case .pasteImage: String(localized: "Paste Image")
        case .bringPinsForward: String(localized: "Bring Pins Forward")
        case .closeAllPins: String(localized: "Close All Pins")
        case .settings: String(localized: "Settings…")
        case .about: String(localized: "About Recortia")
        case .quit: String(localized: "Quit Recortia")
        }
    }
}

/// What the menu and shortcuts call. The composition root implements it; a command whose backend
/// is not wired reports `isEnabled == false` instead of pretending to work (SPEC §11).
@MainActor
protocol AppActions: AnyObject {
    func isEnabled(_ command: AppCommand) -> Bool
    func perform(_ command: AppCommand)
}
