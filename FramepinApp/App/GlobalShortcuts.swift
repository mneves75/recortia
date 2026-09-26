import Carbon.HIToolbox
import Features
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // User-assigned only: no default key combination, so Framepin never replaces Apple's
    // screenshot shortcuts or registers a surprising global key on first launch (FR-01).
    static let captureRegion = Self("captureRegion")
    static let captureDisplay = Self("captureDisplay")
    static let captureWindow = Self("captureWindow")
    static let captureWithDelay = Self("captureWithDelay")
    static let repeatLastRegion = Self("repeatLastRegion")
    static let scrollingCapture = Self("scrollingCapture")
    static let captureText = Self("captureText")
    /// Stops (or starts) a scrolling capture while another app is focused (FR-10).
    static let scrollingToggle = Self("scrollingToggle")
}

/// One recordable global shortcut and the action it triggers.
struct ShortcutBinding: Identifiable {
    let name: KeyboardShortcuts.Name
    let title: String

    var id: String { name.rawValue }

    static let all: [ShortcutBinding] = [
        ShortcutBinding(name: .captureRegion, title: AppCommand.captureRegion.title),
        ShortcutBinding(name: .captureDisplay, title: AppCommand.captureDisplay.title),
        ShortcutBinding(name: .captureWindow, title: AppCommand.captureWindow.title),
        ShortcutBinding(name: .captureWithDelay, title: AppCommand.captureWithDelay.title),
        ShortcutBinding(name: .repeatLastRegion, title: AppCommand.repeatLastRegion.title),
        ShortcutBinding(name: .scrollingCapture, title: AppCommand.scrollingCapture.title),
        ShortcutBinding(name: .scrollingToggle, title: String(localized: "Stop Scrolling Capture")),
        ShortcutBinding(name: .captureText, title: AppCommand.captureText.title),
    ]

    var command: AppCommand? {
        switch name {
        case .captureRegion: .captureRegion
        case .captureDisplay: .captureDisplay
        case .captureWindow: .captureWindow
        case .captureWithDelay: .captureWithDelay
        case .repeatLastRegion: .repeatLastRegion
        case .scrollingCapture: .scrollingCapture
        case .captureText: .captureText
        default: nil
        }
    }
}

/// Best-effort check that a recorded combination can be registered with the system. It
/// temporarily releases Framepin's own registration, asks Carbon for an exclusive hot key, and
/// restores the registration. Carbon cannot report every shortcut other apps observe, so a
/// passing probe is not a guarantee; the Settings copy says so.
final class CarbonShortcutProbe: ShortcutRegistrationProbe {
    func canRegister(shortcutNamed name: String) -> Bool {
        let shortcutName = KeyboardShortcuts.Name(name)
        guard let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) else { return true }
        KeyboardShortcuts.disable(shortcutName)
        defer { KeyboardShortcuts.enable(shortcutName) }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4650_5042), id: 1)  // 'FPPB'
        let status = RegisterEventHotKey(
            UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers), hotKeyID, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status == noErr
    }
}
