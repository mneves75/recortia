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
            "autoRedactsSensitiveTextChoice",
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

    // Failure mode: a required zoom key would make every older blob fail to decode and reset all
    // settings; a choice that does not persist turns wheel zoom off at every launch.
    @Test("Wheel zoom defaults off, persists, and older blobs still load")
    func editorZoomPreferences() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        store.update {
            $0.zoomsWithScrollWheel = true
            $0.reversesScrollWheelZoom = true
        }
        let reloaded = SettingsStore(storage: storage).preferences
        #expect(reloaded.zoomsWithScrollWheel && reloaded.reversesScrollWheelZoom)

        let written = try #require(storage.values[SettingsStore.storageKey])
        var old = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        old = old.filter { !$0.key.localizedCaseInsensitiveContains("zoom") }
        old["captureDelaySeconds"] = 2
        let legacy = MemoryPreferenceStorage()
        legacy.setPreferenceData(try JSONSerialization.data(withJSONObject: old), forKey: SettingsStore.storageKey)
        let loaded = SettingsStore(storage: legacy)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.captureDelaySeconds == 2)
        #expect(!loaded.preferences.zoomsWithScrollWheel && !loaded.preferences.reversesScrollWheelZoom)
    }

    // Failure modes: a translucent background colour (a hand-edited blob) would leave alpha in an
    // export that promises none; a required key would reset every older blob.
    @Test("The window background defaults to transparent, is always opaque, persists, and older blobs load")
    func windowCaptureBackground() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        #expect(store.preferences.windowCaptureBackground == .transparent)
        store.update { $0.windowCaptureBackground = .solid(RGBA(r: 1, g: 2, b: 3, a: 40)) }
        #expect(store.preferences.windowCaptureBackground == .solid(RGBA(r: 1, g: 2, b: 3)))
        #expect(SettingsStore(storage: storage).preferences.windowCaptureBackground == .solid(RGBA(r: 1, g: 2, b: 3)))

        let written = try #require(storage.values[SettingsStore.storageKey])
        var old = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        old = old.filter { !$0.key.localizedCaseInsensitiveContains("background") }
        old["captureDelaySeconds"] = 6
        let legacy = MemoryPreferenceStorage()
        legacy.setPreferenceData(try JSONSerialization.data(withJSONObject: old), forKey: SettingsStore.storageKey)
        let loaded = SettingsStore(storage: legacy)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.captureDelaySeconds == 6)
        #expect(loaded.preferences.windowCaptureBackground == .transparent)
    }

    // Failure mode (PREF-01): a blob written while the legacy launchAtLogin key was dropped loaded as
    // defaults, and a blob without the key cannot be read by 0.14.0 after a rollback.
    @Test("A blob without launchAtLogin loads, and the next write restores the key for 0.14")
    func keylessLaunchAtLoginBlob() throws {
        var old = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        old.removeValue(forKey: "launchAtLogin")
        old["captureDelaySeconds"] = 4
        let storage = MemoryPreferenceStorage()
        storage.setPreferenceData(try JSONSerialization.data(withJSONObject: old), forKey: SettingsStore.storageKey)
        let store = SettingsStore(storage: storage)
        #expect(store.loadIssue == nil)
        #expect(store.preferences.captureDelaySeconds == 4)
        store.update { $0.autoCopy = true }
        let written = try #require(storage.values[SettingsStore.storageKey])
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["launchAtLogin"] as? Bool == false, "0.14.0 requires the key")
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

    // Failure mode: the masking choice as a required key would make every 0.14 blob fail to
    // decode, resetting all settings and the sealed export consent.
    @Test("Automatic masking defaults off, persists on, and blobs written before it existed still load")
    func autoRedactsSensitiveText() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        #expect(!store.preferences.autoRedactsSensitiveText)
        store.update { $0.autoRedactsSensitiveText = true }
        #expect(SettingsStore(storage: storage).preferences.autoRedactsSensitiveText)

        var old = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        old = old.filter { !$0.key.localizedCaseInsensitiveContains("autoRedacts") }
        old["captureDelaySeconds"] = 2
        let legacy = MemoryPreferenceStorage()
        legacy.setPreferenceData(try JSONSerialization.data(withJSONObject: old), forKey: SettingsStore.storageKey)
        let loaded = SettingsStore(storage: legacy)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.captureDelaySeconds == 2)
        #expect(!loaded.preferences.autoRedactsSensitiveText)
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
