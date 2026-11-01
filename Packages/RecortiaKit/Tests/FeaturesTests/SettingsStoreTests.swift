import Domain
import Foundation
import Testing

@testable import Features

// Failure modes: missing data (first launch), corrupted bytes, a blob from a newer schema,
// out-of-range values (hand-edited defaults), and storage that must never gain content keys.
@Suite("SettingsStore (FR-14, PRIV-01)")
@MainActor
struct SettingsStoreTests {

    @Test("Corrupted data falls back to defaults without crashing or overwriting it")
    func corruptedData() {
        let storage = MemoryPreferenceStorage()
        storage.values[SettingsStore.storageKey] = Data("{not json".utf8)
        let store = SettingsStore(storage: storage)
        #expect(store.preferences == Preferences())
        #expect(store.loadIssue == .corrupted)
        #expect(storage.writeCount == 0)
    }

    @Test("A newer schema version is not misread")
    func newerSchema() throws {
        let storage = MemoryPreferenceStorage()
        var future = Preferences()
        future.schemaVersion = Preferences.currentSchemaVersion + 1
        future.autoCopy = true
        storage.values[SettingsStore.storageKey] = try JSONEncoder().encode(future)
        let store = SettingsStore(storage: storage)
        #expect(store.preferences == Preferences())
        #expect(store.loadIssue == .unsupportedSchema(Preferences.currentSchemaVersion + 1))
    }

    @Test("Out-of-range values are clamped on load and on update")
    func clamping() throws {
        let storage = MemoryPreferenceStorage()
        var odd = Preferences()
        odd.captureDelaySeconds = 99
        odd.jpegQuality = 7
        odd.defaultExportScale = -1
        odd.pinDefaultOpacity = 3
        storage.values[SettingsStore.storageKey] = try JSONEncoder().encode(odd)
        let store = SettingsStore(storage: storage)
        #expect(store.preferences.captureDelaySeconds == 10)
        #expect(store.preferences.jpegQuality == 1)
        #expect(store.preferences.defaultExportScale == 1)
        #expect(store.preferences.pinDefaultOpacity == 1)

        store.update {
            $0.captureDelaySeconds = -3
            $0.pinDefaultOpacity = .nan
        }
        #expect(store.preferences.captureDelaySeconds == 0)
        #expect(store.preferences.pinDefaultOpacity == 1)
    }

    @Test("The stored blob contains only preference keys, never content")
    func storesNoContent() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        store.update {
            $0.autoCopy = true
            $0.keepsRunningInMenuBar = false
        }
        let data = try #require(storage.values[SettingsStore.storageKey])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "schemaVersion", "hasCompletedOnboarding", "captureDelaySeconds", "captureShowsCursor",
            "captureIncludesWindowShadow", "autoCopy", "autoSave", "launchAtLogin", "updateChecksEnabled",
            "automaticScrollingEnabled", "defaultExportFormat", "jpegQuality", "defaultExportScale", "ocrTextMode",
            "pinDefaultOpacity", "preferredSaveFolderBookmark", "editorContentSize", "keepsRunningInMenuBarChoice",
        ]
        #expect(Set(object.keys).isSubset(of: allowed))
    }

    @Test("The editor window size persists, and blobs written before it existed still load")
    func editorContentSize() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        store.update { $0.editorContentSize = Size(width: 1240, height: 790) }
        #expect(SettingsStore(storage: storage).preferences.editorContentSize == Size(width: 1240, height: 790))
        // A 0.12.1 blob has no editorContentSize key: it must load without a load issue.
        let legacy = MemoryPreferenceStorage()
        var old = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        old.removeValue(forKey: "editorContentSize")
        old["captureDelaySeconds"] = 3
        legacy.setPreferenceData(try JSONSerialization.data(withJSONObject: old), forKey: SettingsStore.storageKey)
        let loaded = SettingsStore(storage: legacy)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.captureDelaySeconds == 3)
        #expect(loaded.preferences.editorContentSize == nil)
    }

    // Failure mode: a required Bool added to the synthesized Codable makes every older blob fail
    // to decode, which resets all settings and drops the sealed export consent.
    @Test("Keeping Recortia in the menu bar defaults on, persists off, and older blobs still load")
    func keepsRunningInMenuBar() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        #expect(store.preferences.keepsRunningInMenuBar)
        store.update { $0.keepsRunningInMenuBar = false }
        #expect(SettingsStore(storage: storage).preferences.keepsRunningInMenuBar == false)

        // A 0.12 blob has no menu-bar key.
        var old = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        old = old.filter { !$0.key.localizedCaseInsensitiveContains("menuBar") }
        old["captureDelaySeconds"] = 5
        let legacy = MemoryPreferenceStorage()
        legacy.setPreferenceData(try JSONSerialization.data(withJSONObject: old), forKey: SettingsStore.storageKey)
        let loaded = SettingsStore(storage: legacy)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.captureDelaySeconds == 5)
        #expect(loaded.preferences.keepsRunningInMenuBar)
    }

    @Test("Works against a real, isolated UserDefaults suite")
    func userDefaultsSuite() throws {
        let suiteName = "dev.mvneves.Recortia.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(storage: defaults)
        store.update {
            $0.pinDefaultOpacity = 0.5
            $0.keepsRunningInMenuBar = false
        }
        let reloaded = SettingsStore(storage: defaults).preferences
        #expect(reloaded.pinDefaultOpacity == 0.5)
        #expect(!reloaded.keepsRunningInMenuBar)
    }

}

@Suite("OnboardingModel (FR-01)")
@MainActor
struct OnboardingModelTests {

}
