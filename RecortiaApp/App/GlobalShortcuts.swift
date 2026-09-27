import Carbon.HIToolbox
import Features
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // No `initial:` shortcut: the library would write it to the user's defaults as soon as a name
    // is created, tests included. Defaults are seeded on a normal launch instead (ADR-005).
    static let captureRegion = Self("captureRegion")
    static let captureDisplay = Self("captureDisplay")
    static let captureWindow = Self("captureWindow")
    /// Every capture mode in a menu at the pointer: Recortia's ⇧⌘5.
    static let captureMenu = Self("captureMenu")
    static let captureWithDelay = Self("captureWithDelay")
    static let repeatLastRegion = Self("repeatLastRegion")
    static let scrollingCapture = Self("scrollingCapture")
    static let captureText = Self("captureText")
    /// Stops (or starts) a scrolling capture while another app is focused (FR-10).
    static let scrollingToggle = Self("scrollingToggle")
}

/// One recordable global shortcut, the action it triggers, and its macOS-style default.
struct ShortcutBinding: Identifiable {
    let name: KeyboardShortcuts.Name
    let title: String
    var defaultShortcut: KeyboardShortcuts.Shortcut?

    var id: String { name.rawValue }

    static let all: [ShortcutBinding] = [
        ShortcutBinding(
            name: .captureRegion, title: AppCommand.captureRegion.title,
            defaultShortcut: .init(.four, modifiers: [.command, .shift])),
        ShortcutBinding(
            name: .captureDisplay, title: AppCommand.captureDisplay.title,
            defaultShortcut: .init(.three, modifiers: [.command, .shift])),
        ShortcutBinding(name: .captureWindow, title: AppCommand.captureWindow.title),
        ShortcutBinding(
            name: .captureMenu, title: AppCommand.captureMenu.title,
            defaultShortcut: .init(.five, modifiers: [.command, .shift])),
        ShortcutBinding(name: .captureWithDelay, title: AppCommand.captureWithDelay.title),
        ShortcutBinding(name: .repeatLastRegion, title: AppCommand.repeatLastRegion.title),
        ShortcutBinding(name: .scrollingCapture, title: AppCommand.scrollingCapture.title),
        ShortcutBinding(name: .scrollingToggle, title: String(localized: "Stop Scrolling Capture")),
        ShortcutBinding(name: .captureText, title: AppCommand.captureText.title),
    ]

    static var names: [String] { all.map(\.name.rawValue) }

    var command: AppCommand? {
        switch name {
        case .captureRegion: .captureRegion
        case .captureDisplay: .captureDisplay
        case .captureWindow: .captureWindow
        case .captureMenu: .captureMenu
        case .captureWithDelay: .captureWithDelay
        case .repeatLastRegion: .repeatLastRegion
        case .scrollingCapture: .scrollingCapture
        case .captureText: .captureText
        default: nil
        }
    }
}

/// The macOS-style default shortcuts (ADR-005): seeded once per table version, and restorable.
enum ShortcutDefaults {
    /// The table version already offered, kept beside the shortcuts in the same defaults domain.
    static let versionKey = "RecortiaShortcutDefaultsVersion"

    private static var table: [(name: String, shortcut: KeyboardShortcuts.Shortcut)] {
        ShortcutBinding.all.compactMap { binding in
            binding.defaultShortcut.map { (name: binding.name.rawValue, shortcut: $0) }
        }
    }

    /// Gives unassigned commands their default, once, never onto keys another command uses.
    /// Runs on a normal launch only; the E2E runner calls it against its own cleared domain.
    static func seedIfNeeded(in defaults: UserDefaults = .standard) {
        var assigned: [String: KeyboardShortcuts.Shortcut] = [:]
        for binding in ShortcutBinding.all {
            assigned[binding.name.rawValue] = KeyboardShortcuts.getShortcut(for: binding.name)
        }
        let names = ShortcutDefaultsPlan.namesToSeed(
            defaults: table, assigned: assigned, seededVersion: defaults.integer(forKey: versionKey))
        for name in names {
            let shortcut = table.first { $0.name == name }?.shortcut
            KeyboardShortcuts.setShortcut(shortcut, for: KeyboardShortcuts.Name(name))
        }
        defaults.set(ShortcutDefaultsPlan.version, forKey: versionKey)
    }

    /// Restore Defaults: every command back to the table, the rest cleared.
    static func restore() {
        let restored = ShortcutDefaultsPlan.restored(names: ShortcutBinding.names, defaults: table)
        // Clear first, so a default never lands on keys another command still holds.
        for (name, shortcut) in restored where shortcut == nil {
            KeyboardShortcuts.setShortcut(nil, for: KeyboardShortcuts.Name(name))
        }
        for (name, shortcut) in restored {
            if let shortcut { KeyboardShortcuts.setShortcut(shortcut, for: KeyboardShortcuts.Name(name)) }
        }
    }
}

/// Registers, holds, and probes global shortcuts through KeyboardShortcuts. A shortcut an enabled
/// macOS shortcut also uses is held (disabled) rather than registered, so one key press never
/// drives both apps. The Carbon probe cannot report every shortcut other apps observe, so a
/// passing probe is not a guarantee; the Settings copy says so.
final class KeyboardShortcutsRegistry: ShortcutRegistrationProbe {
    private let takenBySystem: (KeyboardShortcuts.Shortcut) -> Bool

    /// `takenBySystem` defaults to the enabled shortcuts macOS reports (`CopySymbolicHotKeys`);
    /// the E2E runner passes a fixed list so its results do not depend on the host's settings.
    init(takenBySystem: @escaping (KeyboardShortcuts.Shortcut) -> Bool = { $0.isTakenBySystem }) {
        self.takenBySystem = takenBySystem
    }

    func isAssigned(shortcutNamed name: String) -> Bool {
        KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(name)) != nil
    }

    func isTakenBySystem(shortcutNamed name: String) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: KeyboardShortcuts.Name(name)) else { return false }
        return takenBySystem(shortcut)
    }

    func setRegistered(_ registered: Bool, shortcutNamed name: String) {
        if registered {
            KeyboardShortcuts.enable(KeyboardShortcuts.Name(name))
        } else {
            KeyboardShortcuts.disable(KeyboardShortcuts.Name(name))
        }
    }

    /// Temporarily releases Recortia's own registration, asks Carbon for an exclusive hot key, and
    /// restores the registration.
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
