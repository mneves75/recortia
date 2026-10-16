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

    /// The command a shortcut performs; names match `AppCommand` raw values. Stop Scrolling
    /// Capture has no command of its own.
    var command: AppCommand? { AppCommand(rawValue: name.rawValue) }
}

/// The macOS-style default shortcuts (ADR-005): each offered once, and restorable.
enum ShortcutDefaults {
    /// Names whose default was already offered, kept beside the shortcuts in the same defaults
    /// domain. KeyboardShortcuts stores a cleared shortcut as no value, so this is what keeps a
    /// cleared default cleared.
    static let offeredKey = "RecortiaShortcutDefaultsOffered"

    private static var table: [DefaultShortcut<KeyboardShortcuts.Shortcut>] {
        ShortcutBinding.all.compactMap { binding in
            binding.defaultShortcut.map { DefaultShortcut(name: binding.name.rawValue, shortcut: $0) }
        }
    }

    /// Gives unassigned commands their not-yet-offered default, never onto keys another command
    /// uses, on a new install only: someone upgrading may have given these keys to another app,
    /// so they are marked offered and left to Restore Defaults. Runs on a normal launch; the E2E
    /// runner calls it against its own cleared domain.
    static func seedIfNeeded(isNewInstall: Bool, in defaults: UserDefaults = .standard) {
        var assigned: [String: KeyboardShortcuts.Shortcut] = [:]
        for binding in ShortcutBinding.all {
            assigned[binding.name.rawValue] = KeyboardShortcuts.getShortcut(for: binding.name)
        }
        let offered = Set(defaults.stringArray(forKey: offeredKey) ?? [])
        let seeds =
            isNewInstall ? ShortcutDefaultsPlan.defaultsToSeed(table, assigned: assigned, alreadyOffered: offered) : []
        for seed in seeds {
            KeyboardShortcuts.setShortcut(seed.shortcut, for: KeyboardShortcuts.Name(seed.name))
        }
        defaults.set(offered.union(table.map(\.name)).sorted(), forKey: offeredKey)
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
/// drives both apps. Carbon reports neither macOS's shortcuts nor another app's ordinary hot keys
/// as a registration failure, so a passing probe is not a guarantee; the Settings copy says so.
final class KeyboardShortcutsRegistry: ShortcutRegistry {
    private let takenBySystem: @MainActor (KeyboardShortcuts.Shortcut) -> Bool
    private let probe: @MainActor (KeyboardShortcuts.Shortcut) -> Bool

    /// The E2E runner passes a fixed macOS list and a probe that never touches Carbon, so its
    /// results do not depend on the host and it never takes the host's keys.
    init(
        takenBySystem: @escaping @MainActor (KeyboardShortcuts.Shortcut) -> Bool = SystemShortcuts.isTaken,
        probe: @escaping @MainActor (KeyboardShortcuts.Shortcut) -> Bool = SystemShortcuts.canRegisterExclusively
    ) {
        self.takenBySystem = takenBySystem
        self.probe = probe
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

    /// Temporarily releases Recortia's own registration, probes, and restores the registration.
    func canRegister(shortcutNamed name: String) -> Bool {
        let shortcutName = KeyboardShortcuts.Name(name)
        guard let shortcut = KeyboardShortcuts.getShortcut(for: shortcutName) else { return true }
        KeyboardShortcuts.disable(shortcutName)
        defer { KeyboardShortcuts.enable(shortcutName) }
        return probe(shortcut)
    }
}

/// The enabled macOS keyboard shortcuts (System Settings › Keyboard), read with Carbon's public
/// `CopySymbolicHotKeys`, which asks the window server each time.
enum SystemShortcuts {
    private struct Keys: Hashable {
        let code: Int
        let modifiers: Int

        /// The Fn bit is dropped: macOS adds it to arrow and function keys on its own.
        init(code: Int, modifiers: Int) {
            self.code = code
            self.modifiers = modifiers & ~Int(kEventKeyModifierFnMask)
        }
    }

    /// Fails closed: when macOS cannot list its shortcuts, every shortcut counts as taken, so a
    /// default is held rather than risk both apps reacting to one press.
    static func isTaken(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else {
            return true
        }
        let wanted = Keys(code: shortcut.carbonKeyCode, modifiers: shortcut.carbonModifiers)
        return entries.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                let code = entry[kHISymbolicHotKeyCode] as? Int,
                let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int
            else { return false }
            return Keys(code: code, modifiers: modifiers) == wanted
        }
    }

    /// Asks Carbon for an exclusive hot key and releases it at once. It fails only when another app
    /// registered the keys exclusively.
    static func canRegisterExclusively(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4650_5042), id: 1)  // 'FPPB'
        let status = RegisterEventHotKey(
            UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers), hotKeyID, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status == noErr
    }
}
