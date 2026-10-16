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
    public private(set) var assignmentRevision = 0
    @ObservationIgnored private let registry: any ShortcutRegistry
    @ObservationIgnored private let names: [String]
    /// Called whenever a refresh holds a shortcut (a launch, a recording forced onto macOS's keys, a
    /// press macOS reclaimed), so the caller can watch for macOS to let the keys go.
    @ObservationIgnored public var onHold: (() -> Void)?
    /// Called when the person looks at shortcut settings, so a held key they free next is
    /// noticed quickly instead of at the watch's backed-off interval.
    @ObservationIgnored public var onAttention: (() -> Void)?

    public init(registry: any ShortcutRegistry, names: [String]) {
        self.registry = registry
        self.names = names
    }

    public func state(of name: String) -> ShortcutState { states[name] ?? .unassigned }
    public func hasFailed(_ name: String) -> Bool { state(of: name) == .failed }
    /// True while a shortcut waits for macOS to let its keys go, so the caller keeps checking.
    public var isHoldingAny: Bool { states.values.contains(.heldBySystem) }

    public func refreshAll() {
        for name in names { refresh(named: name) }
    }

    /// The shortcut settings became visible: re-check now and resume quick checks.
    public func noteUserAttention() {
        refreshAll()
        onAttention?()
    }

    /// Keep the old and new combinations unregistered while assignments are changed. The
    /// shortcut library registers a new stored combination synchronously if its handler is active.
    public func reassign(_ change: () -> Void) {
        for name in names { registry.setRegistered(false, shortcutNamed: name) }
        change()
        refreshAll()
        assignmentRevision += 1
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
        if !registry.isAssigned(shortcutNamed: name) {
            registry.setRegistered(true, shortcutNamed: name)
            state = .unassigned
        } else if registry.isTakenBySystem(shortcutNamed: name) {
            registry.setRegistered(false, shortcutNamed: name)
            state = .heldBySystem
        } else {
            registry.setRegistered(true, shortcutNamed: name)
            state = registry.canRegister(shortcutNamed: name) ? .active : .failed
        }
        if states[name] != state { states[name] = state }
        if state == .heldBySystem { onHold?() }
    }

    /// Called when the shortcut fires. A press that arrives while macOS also claims the keys (the
    /// user turned its shortcut back on) does nothing, and the shortcut is held from then on.
    public func admitPress(named name: String) -> Bool {
        guard registry.isTakenBySystem(shortcutNamed: name) else { return true }
        refresh(named: name)
        return false
    }
}

/// One command's default key combination (ADR-005), generic over the combination type so the
/// plan stays free of the shortcut library.
public struct DefaultShortcut<Shortcut: Hashable>: Hashable {
    public let name: String
    public let shortcut: Shortcut

    public init(name: String, shortcut: Shortcut) {
        self.name = name
        self.shortcut = shortcut
    }
}

/// Default global shortcuts (ADR-005): which commands receive them, and what Restore Defaults sets.
public enum ShortcutDefaultsPlan {
    /// The defaults to apply: each default is offered once (a later version's new default is
    /// offered on its first launch), only to a command without a shortcut, and never onto keys
    /// another command already uses. A default the user cleared is never offered again.
    public static func defaultsToSeed<Shortcut: Hashable>(
        _ defaults: [DefaultShortcut<Shortcut>], assigned: [String: Shortcut], alreadyOffered: Set<String>
    ) -> [DefaultShortcut<Shortcut>] {
        var inUse = Set(assigned.values)
        var seeded: [DefaultShortcut<Shortcut>] = []
        for entry in defaults
        where !alreadyOffered.contains(entry.name) && assigned[entry.name] == nil && !inUse.contains(entry.shortcut) {
            inUse.insert(entry.shortcut)
            seeded.append(entry)
        }
        return seeded
    }

    /// Every command back to the table: its default, or no shortcut.
    public static func restored<Shortcut: Hashable>(
        names: [String], defaults: [DefaultShortcut<Shortcut>]
    ) -> [String: Shortcut?] {
        var result: [String: Shortcut?] = [:]
        for name in names {
            // `updateValue`, not subscript assignment: assigning nil would drop the key.
            result.updateValue(defaults.first { $0.name == name }?.shortcut, forKey: name)
        }
        return result
    }
}
