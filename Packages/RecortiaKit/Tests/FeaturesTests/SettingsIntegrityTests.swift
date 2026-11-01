import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (audit: auto-export consent from unauthenticated preferences): Recortia is not
// sandboxed, so any same-user process can rewrite its preferences domain. Side-effect consent
// (automatic copy/save, the save folder, automatic scrolling) must then not survive a blob that
// Recortia did not seal: a missing seal, a wrong seal, a seal over other bytes, and an
// unavailable secret all fail closed, while harmless numeric settings still load.
@Suite("SettingsStore seals side-effect consent")
@MainActor
struct SettingsIntegrityTests {
    private func consenting() -> Preferences {
        var preferences = Preferences()
        preferences.autoCopy = true
        preferences.autoSave = true
        preferences.automaticScrollingEnabled = true
        preferences.preferredSaveFolderBookmark = Data([1, 2, 3])
        preferences.captureDelaySeconds = 3
        return preferences
    }

    private func expectConsentDropped(_ store: SettingsStore) {
        #expect(store.preferences.autoCopy == false)
        #expect(store.preferences.autoSave == false)
        #expect(store.preferences.automaticScrollingEnabled == false)
        #expect(store.preferences.preferredSaveFolderBookmark == nil)
        #expect(store.preferences.captureDelaySeconds == 3, "numeric settings still load")
        #expect(store.loadIssue == .unverifiedConsent)
    }

    @Test("A seal copied from other bytes does not verify")
    func mismatchedSeal() throws {
        let storage = MemoryPreferenceStorage()
        let integrity = FixedKeyPreferenceIntegrity()
        let store = SettingsStore(storage: storage, integrity: integrity)
        store.update { $0.captureDelaySeconds = 3 }
        storage.values[SettingsStore.storageKey] = try JSONEncoder().encode(consenting())
        expectConsentDropped(SettingsStore(storage: storage, integrity: integrity))
    }

    @Test("A seal from another secret does not verify")
    func foreignSecret() throws {
        let storage = MemoryPreferenceStorage()
        SettingsStore(storage: storage, integrity: FixedKeyPreferenceIntegrity(key: Data(repeating: 9, count: 32)))
            .update { $0 = consenting() }
        expectConsentDropped(SettingsStore(storage: storage, integrity: FixedKeyPreferenceIntegrity()))
    }

    @Test("A sealed blob written before the menu-bar preference existed keeps its consent")
    func sealedLegacyBlob() throws {
        let storage = MemoryPreferenceStorage()
        let integrity = FixedKeyPreferenceIntegrity()
        var preferences = consenting()
        preferences.githubUpload = GitHubUploadPreferences(
            destination: GitHubDestination(owner: "fixture", repository: "private-captures"), automatic: true)
        // What 0.12 sealed: the same settings without any menu-bar key.
        let current = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        let data = try JSONSerialization.data(
            withJSONObject: current.filter { !$0.key.localizedCaseInsensitiveContains("menuBar") })
        storage.values[SettingsStore.storageKey] = data
        storage.values[SettingsStore.sealKey] = integrity.seal(data)
        let loaded = SettingsStore(storage: storage, integrity: integrity)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences == preferences)
        #expect(loaded.preferences.keepsRunningInMenuBar)
    }

    @Test("Without the secret nothing is sealed and consent does not survive a relaunch")
    func unavailableSecret() {
        let storage = MemoryPreferenceStorage()
        let integrity = FixedKeyPreferenceIntegrity(available: false)
        let store = SettingsStore(storage: storage, integrity: integrity)
        store.update { $0 = consenting() }
        #expect(store.preferences.autoCopy, "the running session keeps what the user just chose")
        expectConsentDropped(SettingsStore(storage: storage, integrity: integrity))
    }

}
