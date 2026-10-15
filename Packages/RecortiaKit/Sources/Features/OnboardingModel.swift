import Domain
import Observation

/// First-launch feature tour (FR-01). Replaying it never resets persisted preferences.
/// No permission is requested here; Screen Recording is asked for on the first capture.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Hashable, Sendable {
        case localProcessing
        case capture
        case editing
        case recognition
        case composition
        case sharing
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
    public var canGoBack: Bool { step != .localProcessing && step != .done }
    public var pageNumber: Int { min(step.rawValue + 1, Self.pageCount) }
    public static var pageCount: Int { Step.allCases.count - 1 }

    public func next() {
        switch step {
        case .localProcessing: step = .capture
        case .capture: step = .editing
        case .editing: step = .recognition
        case .recognition: step = .composition
        case .composition: step = .sharing
        case .sharing: step = .shortcuts
        case .shortcuts: finish()
        case .done: break
        }
    }

    public func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    public func beginTour() {
        step = .localProcessing
    }

    /// Completes onboarding (also used by Skip). Shortcuts stay unassigned unless the user set them.
    public func finish() {
        step = .done
        settings.update { $0.hasCompletedOnboarding = true }
    }
}
