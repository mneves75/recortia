import Foundation
import Synchronization
import Testing

@testable import MacPlatform

// Failure modes (FP-024, PRIV-01): a build without the update signing key starts Sparkle and
// offers a check that can never verify anything; a started updater asks the feed before the
// person chose to; Sparkle's own stored setting turns background checks on behind Recortia's
// preference; a Sparkle configuration error throws through launch. The fake engine stands in for
// Sparkle, so no test starts a real updater or touches the network.
@Suite("Sparkle update service (FP-024)")
@MainActor
struct SparkleUpdateServiceTests {
    /// Not a key: the service checks only that one is present.
    static let testKey = "placeholder-public-key"
    static let feed = "https://mneves75.github.io/recortia/appcast.xml"
    static let configured: [String: Any] = ["SUPublicEDKey": testKey, "SUFeedURL": feed]

    @MainActor
    final class Engines {
        var made: [FakeEngine] = []
        var startError: (any Error)?
        var result = UpdateCheckResult.noUpdate
        /// What Sparkle would read from the app's user defaults and Info.plist before Recortia
        /// writes anything: by default a clean install of the shipping plist.
        var stored = SparkleSettings(
            feedURL: nil, sendsSystemProfile: false, allowsAutomaticUpdates: false,
            automaticallyDownloadsUpdates: false)
        /// A Sparkle that keeps its stored values whatever Recortia writes.
        var ignoresOverrides = false

        func make() -> any UpdaterEngine {
            let engine = FakeEngine(startError: startError, result: result, stored: stored)
            engine.ignoresOverrides = ignoresOverrides
            made.append(engine)
            return engine
        }
    }

    final class FakeEngine: UpdaterEngine {
        var automaticallyChecksForUpdates = false
        private(set) var starts = 0
        private(set) var probes = 0
        private(set) var updateWindows = 0
        private(set) var mayCheckInBackground: (@MainActor () -> Bool)?
        private(set) var automaticAtStart: Bool?
        private(set) var overriddenFeed: URL?
        private(set) var overridesBeforeStart = false
        var ignoresOverrides = false
        private(set) var settings: SparkleSettings
        let startError: (any Error)?
        let result: UpdateCheckResult

        init(startError: (any Error)?, result: UpdateCheckResult, stored: SparkleSettings) {
            self.startError = startError
            self.result = result
            settings = stored
        }

        /// Like the real engine: the delegate feed and written profile and download switches replace
        /// stored values; `allowsAutomaticUpdates` follows the plist only.
        func overrideStoredSettings(feed: URL) {
            overriddenFeed = feed
            overridesBeforeStart = starts == 0
            guard !ignoresOverrides else { return }
            settings.feedURL = feed
            settings.sendsSystemProfile = false
            settings.automaticallyDownloadsUpdates = false
        }

        func start(mayCheckInBackground: @escaping @MainActor () -> Bool) throws {
            starts += 1
            automaticAtStart = automaticallyChecksForUpdates
            self.mayCheckInBackground = mayCheckInBackground
            if let startError { throw startError }
        }

        func checkForUpdateInformation() async -> UpdateCheckResult {
            probes += 1
            return result
        }

        func showUpdate() { updateWindows += 1 }
    }

    private func service(_ info: [String: Any]?, _ engines: Engines) -> SparkleUpdateService {
        SparkleUpdateService(info: info, makeEngine: { engines.make() })
    }

    @Test("Without SUPublicEDKey the updater is unavailable, never created and never asks the feed")
    func keyAbsent() async {
        let infos: [[String: Any]?] = [
            nil, [:], ["SUFeedURL": Self.feed], ["SUFeedURL": Self.feed, "SUPublicEDKey": ""],
            ["SUFeedURL": Self.feed, "SUPublicEDKey": "  \n"], ["SUFeedURL": Self.feed, "SUPublicEDKey": 42],
        ]
        for info in infos {
            let engines = Engines()
            let updates = service(info, engines)
            #expect(!SparkleUpdateService.isConfigured(info))
            #expect(updates.start(mayCheckInBackground: { true }) == .unavailable)
            #expect(await updates.checkForUpdates() == .failed)
            updates.setChecksAutomatically(true)
            updates.installUpdate()
            #expect(engines.made.isEmpty, "\(String(describing: info)) created a Sparkle updater")
        }
    }

    @Test("A key without an https feed is unavailable too")
    func feedRequired() {
        let feeds: [Any?] = [nil, "", "http://mneves75.github.io/recortia/appcast.xml", "appcast.xml", 7]
        for feed in feeds {
            var info: [String: Any] = ["SUPublicEDKey": Self.testKey]
            info["SUFeedURL"] = feed
            let engines = Engines()
            #expect(service(info, engines).start(mayCheckInBackground: { false }) == .unavailable)
            #expect(engines.made.isEmpty)
        }
    }

    @Test("With a key the updater starts once with automatic checks off and makes no request")
    func keyPresent() throws {
        let engines = Engines()
        let updates = service(Self.configured, engines)
        #expect(SparkleUpdateService.isConfigured(Self.configured))
        #expect(updates.start(mayCheckInBackground: { false }) == .started)
        #expect(updates.start(mayCheckInBackground: { true }) == .started, "a second start changes nothing")
        let engine = try #require(engines.made.first)
        #expect(engines.made.count == 1 && engine.starts == 1)
        #expect(engine.automaticAtStart == false, "Sparkle schedules from this value as it starts")
        #expect(engine.probes == 0 && engine.updateWindows == 0)
        let mayCheck = try #require(engine.mayCheckInBackground)
        #expect(!mayCheck(), "a scheduled check is refused while the person has not opted in")
    }

    @Test("Opting in turns Sparkle's schedule on and admits scheduled checks; preference reset refuses them live")
    func optIn() throws {
        let engines = Engines()
        let updates = service(Self.configured, engines)
        let allowed = Mutex(false)
        _ = updates.start(mayCheckInBackground: { allowed.withLock { $0 } })
        let engine = try #require(engines.made.first)
        let mayCheck = try #require(engine.mayCheckInBackground)
        allowed.withLock { $0 = true }
        updates.setChecksAutomatically(true)
        #expect(engine.automaticallyChecksForUpdates && mayCheck())
        // Preference reset or drift outside setChecksAutomatically immediately refuses scheduled checks.
        allowed.withLock { $0 = false }
        engine.automaticallyChecksForUpdates = true
        #expect(!mayCheck())
        updates.setChecksAutomatically(false)
        #expect(!engine.automaticallyChecksForUpdates && !mayCheck())
        #expect(engine.probes == 0)
    }

    @Test("A Sparkle start failure is reported as failed, never thrown, and disables checks")
    func startFailure() async throws {
        let engines = Engines()
        engines.startError = CocoaError(.featureUnsupported)
        let updates = service(Self.configured, engines)
        #expect(updates.start(mayCheckInBackground: { false }) == .failed)
        #expect(updates.start(mayCheckInBackground: { false }) == .failed)
        #expect(await updates.checkForUpdates() == .failed)
        updates.installUpdate()
        let engine = try #require(engines.made.first)
        #expect(engines.made.count == 1 && engine.probes == 0 && engine.updateWindows == 0)
    }

    @Test("An explicit check asks the engine once and returns what it found")
    func explicitCheck() async throws {
        for result in [UpdateCheckResult.noUpdate, .updateAvailable(version: "0.16.0"), .failed, .inProgress] {
            let engines = Engines()
            engines.result = result
            let updates = service(Self.configured, engines)
            _ = updates.start(mayCheckInBackground: { false })
            #expect(await updates.checkForUpdates() == result)
            updates.installUpdate()
            let engine = try #require(engines.made.first)
            #expect(engine.probes == 1 && engine.updateWindows == 1)
        }
    }

    // Failure modes (review P1s): values an earlier run left in the app's user defaults outrank the
    // Info.plist in Sparkle. A stored SUFeedURL sends checks to a server Recortia never validated,
    // a stored SUSendProfileInfo appends the system profile even to a manual check, and a stored
    // SUAutomaticallyUpdate downloads and installs without the person choosing it.
    @Test("Stored feed and profile values are overridden before Sparkle starts")
    func storedValuesOverridden() throws {
        let engines = Engines()
        engines.stored = SparkleSettings(
            feedURL: URL(string: "https://updates.example.com/appcast.xml"), sendsSystemProfile: true,
            allowsAutomaticUpdates: false, automaticallyDownloadsUpdates: false)
        let updates = service(Self.configured, engines)
        #expect(updates.start(mayCheckInBackground: { false }) == .started)
        let engine = try #require(engines.made.first)
        #expect(engine.overriddenFeed == URL(string: Self.feed), "the validated plist feed, exactly")
        #expect(engine.overridesBeforeStart)
        #expect(engine.settings.feedURL == URL(string: Self.feed) && !engine.settings.sendsSystemProfile)
    }

    @Test("A stored value Sparkle keeps fails the start, and Sparkle never starts")
    func storedValuesThatStick() async throws {
        let foreign = URL(string: "https://updates.example.com/appcast.xml")
        let cases: [(String, SparkleSettings, Bool)] = [
            (
                "foreign feed",
                SparkleSettings(
                    feedURL: foreign, sendsSystemProfile: false, allowsAutomaticUpdates: false,
                    automaticallyDownloadsUpdates: false), true
            ),
            (
                "system profile",
                SparkleSettings(
                    feedURL: nil, sendsSystemProfile: true, allowsAutomaticUpdates: false,
                    automaticallyDownloadsUpdates: false), true
            ),
            (
                "automatic-update option",
                SparkleSettings(
                    feedURL: nil, sendsSystemProfile: false, allowsAutomaticUpdates: true,
                    automaticallyDownloadsUpdates: false), false
            ),
            (
                "automatic downloads",
                SparkleSettings(
                    feedURL: nil, sendsSystemProfile: false, allowsAutomaticUpdates: false,
                    automaticallyDownloadsUpdates: true), true
            ),
        ]
        for (name, stored, ignoresOverrides) in cases {
            let engines = Engines()
            engines.stored = stored
            engines.ignoresOverrides = ignoresOverrides
            let updates = service(Self.configured, engines)
            #expect(updates.start(mayCheckInBackground: { true }) == .failed, "\(name)")
            #expect(await updates.checkForUpdates() == .failed, "\(name)")
            let engine = try #require(engines.made.first)
            #expect(engine.starts == 0 && engine.probes == 0, "\(name): Sparkle started anyway")
        }
    }

    @Test("Probe preflight returns failed when Sparkle cannot check without an active session")
    func probePreflight() {
        #expect(
            SparkleEngine.probePreflight(probeActive: false, sessionInProgress: false, canCheckForUpdates: false)
                == .failed)
        #expect(
            SparkleEngine.probePreflight(probeActive: false, sessionInProgress: false, canCheckForUpdates: true)
                == .start)
        #expect(
            SparkleEngine.probePreflight(probeActive: true, sessionInProgress: false, canCheckForUpdates: true)
                == .inProgress)
        #expect(
            SparkleEngine.probePreflight(probeActive: false, sessionInProgress: true, canCheckForUpdates: false)
                == .inProgress)
    }

    @Test("Sparkle's no-update error is no update; any other error is a failed check")
    func probeOutcome() {
        let domain = "SUSparkleErrorDomain"
        #expect(SparkleEngine.outcome(foundVersion: nil, error: nil) == .noUpdate)
        #expect(SparkleEngine.outcome(foundVersion: nil, error: NSError(domain: domain, code: 1001)) == .noUpdate)
        #expect(SparkleEngine.outcome(foundVersion: "0.16.0", error: nil) == .updateAvailable(version: "0.16.0"))
        #expect(SparkleEngine.outcome(foundVersion: nil, error: NSError(domain: domain, code: 2001)) == .failed)
        #expect(SparkleEngine.outcome(foundVersion: nil, error: NSError(domain: "other", code: 1001)) == .failed)
        #expect(SparkleEngine.outcome(foundVersion: nil, error: URLError(.notConnectedToInternet)) == .failed)
        #expect(SparkleEngine.outcome(foundVersion: "0.16.0", error: URLError(.timedOut)) == .failed)
    }
}
