import Domain
import MacPlatform
import Observation

/// The signed updater the menu and Settings use (FP-024). Production adapts
/// `SparkleUpdateService`; the E2E run uses a synthetic one that touches no network.
@MainActor
public protocol UpdateService: AnyObject {
    /// Starts the updater once, without a request. `mayCheckInBackground` is read live before any
    /// scheduled background check runs.
    func start(mayCheckInBackground: @escaping @MainActor () -> Bool) -> UpdaterStart
    func setChecksAutomatically(_ enabled: Bool)
    func checkForUpdates() async -> UpdateCheckResult
    /// The updater's own window for an update a check found.
    func installUpdate()
}

/// Check for Updates… and the "Check automatically" toggle. Both are hidden in a build that cannot
/// verify an update (no signing key yet), and disabled when the updater failed to start.
@MainActor
@Observable
public final class UpdaterModel {
    /// Nil until launch starts the updater.
    public private(set) var status: UpdaterStart?
    public private(set) var isChecking = false
    @ObservationIgnored private let service: (any UpdateService)?
    @ObservationIgnored private let settings: SettingsStore

    public init(service: (any UpdateService)?, settings: SettingsStore) {
        self.service = service
        self.settings = settings
    }

    /// Once, at launch. Returns at once whatever happens; asks the feed nothing.
    public func start() {
        guard status == nil else { return }
        status =
            service?.start(mayCheckInBackground: { [weak self] in
                self?.settings.preferences.checksForUpdatesAutomatically == true
            }) ?? .unavailable
    }

    /// Whether the menu item and the Settings toggle are shown.
    public var isOffered: Bool { status == .started || status == .failed }

    public var canCheck: Bool { status == .started && !isChecking }

    public var checksAutomatically: Bool { settings.preferences.checksForUpdatesAutomatically }

    public func setChecksAutomatically(_ enabled: Bool) {
        guard status == .started, let service else { return }
        settings.update { $0.checksForUpdatesAutomatically = enabled }
        service.setChecksAutomatically(settings.preferences.checksForUpdatesAutomatically)
    }

    /// One explicit check; nil when none may run now (unavailable, failed, or one running).
    public func check() async -> UpdateCheckResult? {
        guard canCheck, let service else { return nil }
        isChecking = true
        defer { isChecking = false }
        return await service.checkForUpdates()
    }

    public func install() {
        guard status == .started else { return }
        service?.installUpdate()
    }
}
