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

/// Global shortcut registration status per shortcut name, for Settings (FR-01). Detection is
/// best-effort: other apps' shortcuts cannot all be known.
@MainActor
@Observable
public final class ShortcutStatusModel {
    public private(set) var failedNames: Set<String> = []
    @ObservationIgnored private let probe: any ShortcutRegistrationProbe

    public init(probe: any ShortcutRegistrationProbe) {
        self.probe = probe
    }

    public func shortcutChanged(named name: String, isAssigned: Bool) {
        if isAssigned, !probe.canRegister(shortcutNamed: name) {
            failedNames.insert(name)
        } else {
            failedNames.remove(name)
        }
    }

    public func hasFailed(_ name: String) -> Bool { failedNames.contains(name) }
}
