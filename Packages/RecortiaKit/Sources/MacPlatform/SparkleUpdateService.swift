import Foundation
import Sparkle

/// How the updater came up at launch (FP-024).
public enum UpdaterStart: Hashable, Sendable {
    /// This build has no update signing key or no https feed, so Sparkle is never created and the
    /// feed is never asked.
    case unavailable
    case started
    /// Sparkle refused to start, a configuration error; the app keeps working without updates.
    case failed
}

/// What one explicit check found.
public enum UpdateCheckResult: Hashable, Sendable {
    case noUpdate
    case updateAvailable(version: String)
    case failed
    /// A scheduled check or Sparkle's update window is already running; Sparkle brings it forward.
    case inProgress
}

/// What Sparkle will use, as it reports it. Values an earlier run stored in the app's user
/// defaults outrank the Info.plist, so the service reads these back before it starts Sparkle.
struct SparkleSettings: Hashable {
    var feedURL: URL?
    var sendsSystemProfile: Bool
    /// False only with the Info.plist's `SUAllowsAutomaticUpdates` disallow, which also hides the
    /// update window's "automatically download and install" option.
    var allowsAutomaticUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
}

/// The part of Sparkle `SparkleUpdateService` drives, so tests use a fake and never start a real
/// updater or touch the network.
@MainActor
protocol UpdaterEngine: AnyObject {
    /// Sparkle's stored schedule switch; `start` reads it to plan the first cycle.
    var automaticallyChecksForUpdates: Bool { get set }
    /// Replaces what the user defaults can hold: the feed becomes `feed`, and neither the system
    /// profile nor automatic downloads stay on. Called before `start`.
    func overrideStoredSettings(feed: URL)
    /// Read back from Sparkle after `overrideStoredSettings`.
    var settings: SparkleSettings { get }
    /// Starts Sparkle without a check. `mayCheckInBackground` answers every scheduled check.
    func start(mayCheckInBackground: @escaping @MainActor () -> Bool) throws
    /// Reads the feed without showing Sparkle's windows.
    func checkForUpdateInformation() async -> UpdateCheckResult
    /// Sparkle's update window: release notes, download, signature check, install.
    func showUpdate()
}

/// The signed updater (FP-024). It starts only in a build whose Info.plist carries the EdDSA
/// public key and an https feed; otherwise it reports `.unavailable` and Sparkle never exists.
/// A started updater asks the feed only when the person checks, or on Sparkle's schedule after
/// they opt in; Recortia's preference, not Sparkle's stored value, admits each scheduled check.
@MainActor
public final class SparkleUpdateService {
    public static let publicKeyKey = "SUPublicEDKey"
    public static let feedURLKey = "SUFeedURL"

    /// The validated `SUFeedURL`; nil when this build cannot verify updates.
    private let feed: URL?
    private let makeEngine: @MainActor () -> any UpdaterEngine
    private var engine: (any UpdaterEngine)?
    private var started: UpdaterStart?

    /// `info` is the app's Info.plist dictionary.
    public convenience init(info: [String: Any]?) {
        self.init(info: info, makeEngine: { SparkleEngine() })
    }

    init(info: [String: Any]?, makeEngine: @escaping @MainActor () -> any UpdaterEngine) {
        feed = Self.feed(info)
        self.makeEngine = makeEngine
    }

    /// Whether `info` lets Sparkle verify an update: a non-empty `SUPublicEDKey` and an https
    /// `SUFeedURL`. A malformed key passes here and fails Sparkle's own start.
    public static func isConfigured(_ info: [String: Any]?) -> Bool { feed(info) != nil }

    private static func feed(_ info: [String: Any]?) -> URL? {
        let key = (info?[publicKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, let feed = (info?[feedURLKey] as? String).flatMap({ URL(string: $0) }),
            feed.scheme == "https", feed.host() != nil
        else { return nil }
        return feed
    }

    /// Starts Sparkle once; later calls return the first result. Never throws and never checks.
    /// `mayCheckInBackground` is the live source of truth for scheduled background checks.
    public func start(mayCheckInBackground: @escaping @MainActor () -> Bool) -> UpdaterStart {
        if let started { return started }
        let result = startEngine(mayCheckInBackground: mayCheckInBackground)
        started = result
        return result
    }

    private func startEngine(mayCheckInBackground: @escaping @MainActor () -> Bool) -> UpdaterStart {
        guard let feed else { return .unavailable }
        let engine = makeEngine()
        engine.automaticallyChecksForUpdates = mayCheckInBackground()
        engine.overrideStoredSettings(feed: feed)
        // Fail closed: a value Sparkle still takes from storage would ask another server, send the
        // system profile or install without the person choosing it (PRIV-01).
        let expected = SparkleSettings(
            feedURL: feed, sendsSystemProfile: false, allowsAutomaticUpdates: false,
            automaticallyDownloadsUpdates: false)
        guard engine.settings == expected else { return .failed }
        do {
            try engine.start(mayCheckInBackground: mayCheckInBackground)
        } catch {
            return .failed
        }
        self.engine = engine
        return .started
    }

    public func setChecksAutomatically(_ enabled: Bool) {
        guard let engine else { return }
        engine.automaticallyChecksForUpdates = enabled
    }

    public func checkForUpdates() async -> UpdateCheckResult {
        guard let engine else { return .failed }
        return await engine.checkForUpdateInformation()
    }

    public func installUpdate() {
        engine?.showUpdate()
    }
}

/// Sparkle's standard controller and user driver. Created only by a configured service.
@MainActor
final class SparkleEngine: NSObject, UpdaterEngine, SPUUpdaterDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var mayCheckInBackground: @MainActor () -> Bool = { false }
    /// Answered to `feedURLString(for:)`, which outranks a feed stored in the user defaults.
    private var feed: URL?
    private var probe: CheckedContinuation<UpdateCheckResult, Never>?
    private var foundVersion: String?

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        // Sparkle persists every write and resets its cycle, so write only a change.
        set {
            if controller.updater.automaticallyChecksForUpdates != newValue {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    func overrideStoredSettings(feed: URL) {
        self.feed = feed
        let updater = controller.updater
        _ = updater.clearFeedURLFromUserDefaults()
        if updater.sendsSystemProfile { updater.sendsSystemProfile = false }
        if updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = false }
    }

    var settings: SparkleSettings {
        let updater = controller.updater
        return SparkleSettings(
            feedURL: updater.feedURL, sendsSystemProfile: updater.sendsSystemProfile,
            allowsAutomaticUpdates: updater.allowsAutomaticUpdates,
            automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates)
    }

    func start(mayCheckInBackground: @escaping @MainActor () -> Bool) throws {
        self.mayCheckInBackground = mayCheckInBackground
        try controller.updater.start()
    }

    enum ProbePreflight: Equatable {
        case start
        case inProgress
        case failed
    }

    static func probePreflight(probeActive: Bool, sessionInProgress: Bool, canCheckForUpdates: Bool) -> ProbePreflight {
        if probeActive || sessionInProgress { return .inProgress }
        return canCheckForUpdates ? .start : .failed
    }

    func checkForUpdateInformation() async -> UpdateCheckResult {
        let updater = controller.updater
        switch Self.probePreflight(
            probeActive: probe != nil, sessionInProgress: updater.sessionInProgress,
            canCheckForUpdates: updater.canCheckForUpdates)
        {
        case .inProgress:
            // A probe does nothing while a session runs, and would then never finish.
            updater.checkForUpdates()
            return .inProgress
        case .failed:
            return .failed
        case .start:
            foundVersion = nil
            return await withCheckedContinuation { continuation in
                probe = continuation
                updater.checkForUpdateInformation()
            }
        }
    }

    func showUpdate() {
        controller.updater.checkForUpdates()
    }

    static func outcome(foundVersion: String?, error: (any Error)?) -> UpdateCheckResult {
        guard let error else { return foundVersion.map { .updateAvailable(version: $0) } ?? .noUpdate }
        let nsError = error as NSError
        let noUpdate = nsError.domain == "SUSparkleErrorDomain" && nsError.code == 1001
        return noUpdate && foundVersion == nil ? .noUpdate : .failed
    }

    // MARK: SPUUpdaterDelegate

    /// Recortia's Settings toggle is the only way to turn on automatic checks: no second-launch prompt.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func feedURLString(for updater: SPUUpdater) -> String? { feed?.absoluteString }

    /// No system profile and no extra query parameters, whatever the user defaults say.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        []
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, !mayCheckInBackground() else { return }
        if updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = false }
        throw NSError(
            domain: "dev.mvneves.Recortia.updates", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Automatic update checks are off."])
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundVersion = item.displayVersionString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard updateCheck == .updateInformation, let probe else { return }
        self.probe = nil
        probe.resume(returning: Self.outcome(foundVersion: foundVersion, error: error))
    }
}
