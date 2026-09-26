import Domain
import Observation

/// First-launch flow (FR-01): explain local processing, offer shortcut assignment, then done.
/// No permission is requested here; Screen Recording is asked for on the first capture.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Hashable, Sendable {
        case localProcessing
        case shortcuts
        case done
    }

    public private(set) var step: Step = .localProcessing
    @ObservationIgnored private let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
        if settings.preferences.hasCompletedOnboarding { step = .done }
    }

    public var shouldPresent: Bool { !settings.preferences.hasCompletedOnboarding }
    public var canGoBack: Bool { step == .shortcuts }

    public func next() {
        switch step {
        case .localProcessing: step = .shortcuts
        case .shortcuts: finish()
        case .done: break
        }
    }

    public func back() {
        if step == .shortcuts { step = .localProcessing }
    }

    /// Completes onboarding (also used by Skip). Shortcuts stay unassigned unless the user set them.
    public func finish() {
        step = .done
        settings.update { $0.hasCompletedOnboarding = true }
    }
}
