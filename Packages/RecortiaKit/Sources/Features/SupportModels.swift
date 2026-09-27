import Foundation
import Observation

/// Launch-at-login state as the system reports it; off until the user selects it (FR-01).
@MainActor
@Observable
public final class LoginItemModel {
    public private(set) var isEnabled: Bool
    public private(set) var lastErrorOccurred = false
    @ObservationIgnored private let service: any LoginItemService

    public init(service: any LoginItemService) {
        self.service = service
        isEnabled = service.isEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            try service.setEnabled(enabled)
            lastErrorOccurred = false
        } catch {
            lastErrorOccurred = true
        }
        isEnabled = service.isEnabled
    }

    public func refresh() {
        isEnabled = service.isEnabled
    }
}

/// Recognition languages discovered at runtime (FR-08); nothing is assumed to be installed.
@MainActor
@Observable
public final class OCRLanguagesModel {
    public enum State: Hashable, Sendable {
        case notLoaded
        case loading
        case loaded([Locale.Language])
        case unavailable
    }

    public private(set) var state: State = .notLoaded
    @ObservationIgnored private let service: any TextRecognitionService

    public init(service: any TextRecognitionService) {
        self.service = service
    }

    public func load() async {
        state = .loading
        let languages = await service.supportedLanguages()
        state = languages.isEmpty ? .unavailable : .loaded(languages)
    }
}

/// Where one global shortcut stands (FR-01, ADR-005).
public enum ShortcutState: Hashable, Sendable {
    case unassigned
    /// Registered with the system and handled by Recortia.
    case active
    /// An enabled macOS shortcut uses the same keys; Recortia keeps it unregistered until the user
    /// turns the macOS one off, so one key press never drives both.
    case heldBySystem
    /// The system refused the registration (another app may hold it).
    case failed
}

/// Global shortcut status per shortcut name, for Settings, onboarding, and the menu (FR-01). It
/// also decides which shortcuts are registered: one that macOS claims is held. Detection is
/// best-effort: other apps' shortcuts cannot all be known.
@MainActor
@Observable
public final class ShortcutStatusModel {
    public private(set) var states: [String: ShortcutState] = [:]
    @ObservationIgnored private let probe: any ShortcutRegistrationProbe
    @ObservationIgnored private let names: [String]

    public init(probe: any ShortcutRegistrationProbe, names: [String]) {
        self.probe = probe
        self.names = names
    }

    public func state(of name: String) -> ShortcutState { states[name] ?? .unassigned }
    public func hasFailed(_ name: String) -> Bool { state(of: name) == .failed }
    /// True while a shortcut waits for macOS to let its keys go, so the caller keeps checking.
    public var isHoldingAny: Bool { states.values.contains(.heldBySystem) }

    public func refreshAll() {
        for name in names { refresh(named: name) }
    }

    /// Re-checks only the held shortcuts, for the periodic watch while macOS claims one; active
    /// registrations are left alone.
    public func refreshHeld() {
        for name in names where states[name] == .heldBySystem { refresh(named: name) }
    }

    /// Re-reads one shortcut (after a recording, a reset, or a System Settings change) and
    /// registers or holds it.
    public func refresh(named name: String) {
        let state: ShortcutState
        if !probe.isAssigned(shortcutNamed: name) {
            probe.setRegistered(true, shortcutNamed: name)
            state = .unassigned
        } else if probe.isTakenBySystem(shortcutNamed: name) {
            probe.setRegistered(false, shortcutNamed: name)
            state = .heldBySystem
        } else {
            probe.setRegistered(true, shortcutNamed: name)
            state = probe.canRegister(shortcutNamed: name) ? .active : .failed
        }
        if states[name] != state { states[name] = state }
    }

    /// Called when the shortcut fires. A press that arrives while macOS also claims the keys (the
    /// user turned its shortcut back on) does nothing, and the shortcut is held from then on.
    public func shouldPerform(named name: String) -> Bool {
        guard probe.isTakenBySystem(shortcutNamed: name) else { return true }
        refresh(named: name)
        return false
    }
}

/// Default global shortcuts (ADR-005): which commands receive them, and what Restore Defaults
/// sets. Generic over the key combination so it stays free of the shortcut library.
public enum ShortcutDefaultsPlan {
    /// Raised when the default table changes, so the new defaults are offered once more.
    public static let version = 1

    /// Commands that receive their default: only when this version was never seeded, only
    /// commands without a shortcut, and never keys another command already uses.
    public static func namesToSeed<Shortcut: Hashable>(
        defaults: [(name: String, shortcut: Shortcut)], assigned: [String: Shortcut], seededVersion: Int
    ) -> [String] {
        guard seededVersion < version else { return [] }
        var inUse = Set(assigned.values)
        var seeded: [String] = []
        for entry in defaults where assigned[entry.name] == nil && !inUse.contains(entry.shortcut) {
            inUse.insert(entry.shortcut)
            seeded.append(entry.name)
        }
        return seeded
    }

    /// Every command back to the table: its default, or no shortcut.
    public static func restored<Shortcut: Hashable>(
        names: [String], defaults: [(name: String, shortcut: Shortcut)]
    ) -> [String: Shortcut?] {
        var result: [String: Shortcut?] = [:]
        for name in names {
            result.updateValue(defaults.first { $0.name == name }?.shortcut, forKey: name)
        }
        return result
    }
}
