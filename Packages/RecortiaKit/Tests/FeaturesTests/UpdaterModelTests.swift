import Domain
import Foundation
import MacPlatform
import Testing

@testable import Features

// Failure modes (FP-024, PRIV-01): a fresh install checks for updates on its own; the menu item
// or the Settings toggle shows in a build that cannot verify an update; a failed updater start
// blocks launch or leaves a check that cannot work enabled; a check runs twice at once; a
// preference blob that Recortia did not seal turns automatic checks on.
@Suite("Updater model (FP-024)")
@MainActor
struct UpdaterModelTests {
    final class FakeUpdates: UpdateService {
        var startResult = UpdaterStart.started
        var result = UpdateCheckResult.noUpdate
        private(set) var starts: [Bool] = []
        private(set) var mayCheckInBackground: (@MainActor () -> Bool)?
        private(set) var automatic: [Bool] = []
        private(set) var checks = 0
        private(set) var installs = 0
        /// Holds a check open until the test releases it.
        var gate: CheckedContinuation<Void, Never>?
        var holdsChecks = false

        func start(mayCheckInBackground: @escaping @MainActor () -> Bool) -> UpdaterStart {
            self.mayCheckInBackground = mayCheckInBackground
            starts.append(mayCheckInBackground())
            return startResult
        }

        func setChecksAutomatically(_ enabled: Bool) { automatic.append(enabled) }

        func checkForUpdates() async -> UpdateCheckResult {
            checks += 1
            if holdsChecks { await withCheckedContinuation { gate = $0 } }
            return result
        }

        func installUpdate() { installs += 1 }
    }

    private func settings() -> SettingsStore { SettingsStore(storage: MemoryPreferenceStorage()) }

    @Test("Automatic checks are off by default, and start passes that to the updater")
    func defaultOff() {
        let updates = FakeUpdates()
        let store = settings()
        let model = UpdaterModel(service: updates, settings: store)
        #expect(!Preferences().checksForUpdatesAutomatically)
        #expect(!model.checksAutomatically)
        model.start()
        model.start()
        #expect(updates.starts == [false], "started once, with automatic checks off")
        #expect(updates.checks == 0, "starting asks nothing")
    }

    @Test("A preference blob without the choice loads with automatic checks off")
    func legacyBlob() throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        #expect(object["checksForUpdatesAutomaticallyChoice"] == nil, "an unchanged default writes no key")
        object.removeValue(forKey: "checksForUpdatesAutomaticallyChoice")
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.checksForUpdatesAutomatically)
    }

    @Test("An unsealed blob that turns automatic checks on loads with them off")
    func unsealedConsent() throws {
        let storage = MemoryPreferenceStorage()
        var preferences = Preferences()
        preferences.checksForUpdatesAutomatically = true
        storage.values[SettingsStore.storageKey] = try JSONEncoder().encode(preferences)
        let store = SettingsStore(storage: storage)
        #expect(store.loadIssue == .unverifiedConsent)
        #expect(!store.preferences.checksForUpdatesAutomatically)
    }

    @Test("A build without a signing key hides the entry points and never checks")
    func unavailable() async {
        for updates in [
            FakeUpdates?.none,
            {
                let u = FakeUpdates(); u.startResult = .unavailable; return u
            }(),
        ] {
            let model = UpdaterModel(service: updates, settings: settings())
            #expect(!model.isOffered, "hidden before start")
            model.start()
            #expect(model.status == .unavailable)
            #expect(!model.isOffered && !model.canCheck)
            #expect(await model.check() == nil)
            model.setChecksAutomatically(true)
            model.install()
            #expect(!model.checksAutomatically)
            #expect((updates?.checks ?? 0) == 0 && (updates?.installs ?? 0) == 0 && (updates?.automatic ?? []).isEmpty)
        }
    }

    @Test("A failed start returns at once and shows the entry point disabled")
    func startFailure() async {
        let updates = FakeUpdates()
        updates.startResult = .failed
        let model = UpdaterModel(service: updates, settings: settings())
        model.start()
        #expect(model.status == .failed)
        #expect(model.isOffered && !model.canCheck)
        #expect(await model.check() == nil)
        model.setChecksAutomatically(true)
        model.install()
        #expect(updates.checks == 0 && updates.installs == 0 && updates.automatic.isEmpty)
    }

    @Test("An explicit check goes to the updater and returns what it found, one at a time")
    func explicitCheck() async throws {
        let updates = FakeUpdates()
        let model = UpdaterModel(service: updates, settings: settings())
        #expect(await model.check() == nil, "nothing is checked before launch starts the updater")
        model.start()
        #expect(model.canCheck)
        updates.result = .updateAvailable(version: "0.16.0")
        updates.holdsChecks = true
        let first = Task { await model.check() }
        while updates.gate == nil { await Task.yield() }
        #expect(model.isChecking && !model.canCheck)
        #expect(await model.check() == nil, "a second check while one runs is refused")
        try #require(updates.gate).resume()
        #expect(await first.value == .updateAvailable(version: "0.16.0"))
        #expect(updates.checks == 1 && !model.isChecking && model.canCheck)
        model.install()
        #expect(updates.installs == 1)
    }

    @Test("The toggle stores the choice, tells the updater, and live background authorization follows settings resets")
    func toggle() throws {
        let updates = FakeUpdates()
        let store = settings()
        let model = UpdaterModel(service: updates, settings: store)
        model.start()
        let mayCheck = try #require(updates.mayCheckInBackground)
        #expect(!mayCheck())
        model.setChecksAutomatically(true)
        #expect(store.preferences.checksForUpdatesAutomaticallyChoice == true && model.checksAutomatically)
        #expect(mayCheck())
        // A direct preference reset (bypassing setChecksAutomatically) immediately revokes background checks.
        store.update { $0.checksForUpdatesAutomatically = false }
        #expect(!mayCheck())
        model.setChecksAutomatically(false)
        #expect(store.preferences.checksForUpdatesAutomaticallyChoice == false && !model.checksAutomatically)
        #expect(updates.automatic == [true, false])
        #expect(updates.checks == 0, "changing the preference checks nothing")
    }
}
