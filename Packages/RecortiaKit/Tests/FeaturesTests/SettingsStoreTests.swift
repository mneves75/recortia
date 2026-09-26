import Domain
import Foundation
import Testing

@testable import Features

// Failure modes: missing data (first launch), corrupted bytes, a blob from a newer schema,
// out-of-range values (hand-edited defaults), and storage that must never gain content keys.
@Suite("SettingsStore (FR-14, PRIV-01)")
@MainActor
struct SettingsStoreTests {
    @Test("First launch uses defaults with every side-effect toggle off")
    func defaults() {
        let store = SettingsStore(storage: MemoryPreferenceStorage())
        #expect(store.preferences == Preferences())
        #expect(store.preferences.autoCopy == false)
        #expect(store.preferences.autoSave == false)
        #expect(store.preferences.launchAtLogin == false)
        #expect(store.preferences.updateChecksEnabled == false)
        #expect(store.preferences.automaticScrollingEnabled == false)
        #expect(store.loadIssue == nil)
    }

    @Test("Updates persist as one JSON blob and reload")
    func roundTrip() {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        store.update {
            $0.captureDelaySeconds = 4
            $0.ocrTextMode = .raw
        }
        #expect(storage.values.keys.sorted() == [SettingsStore.storageKey])
        let reloaded = SettingsStore(storage: storage)
        #expect(reloaded.preferences.captureDelaySeconds == 4)
        #expect(reloaded.preferences.ocrTextMode == .raw)
    }

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
        store.update { $0.autoCopy = true }
        let data = try #require(storage.values[SettingsStore.storageKey])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "schemaVersion", "hasCompletedOnboarding", "captureDelaySeconds", "captureShowsCursor",
            "captureIncludesWindowShadow", "autoCopy", "autoSave", "launchAtLogin", "updateChecksEnabled",
            "automaticScrollingEnabled", "defaultExportFormat", "jpegQuality", "defaultExportScale", "ocrTextMode",
            "pinDefaultOpacity", "preferredSaveFolderBookmark",
        ]
        #expect(Set(object.keys).isSubset(of: allowed))
    }

    @Test("Works against a real, isolated UserDefaults suite")
    func userDefaultsSuite() throws {
        let suiteName = "dev.mvneves.Recortia.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(storage: defaults)
        store.update { $0.pinDefaultOpacity = 0.5 }
        #expect(SettingsStore(storage: defaults).preferences.pinDefaultOpacity == 0.5)
    }

    @Test("Reset restores defaults")
    func reset() {
        let store = SettingsStore(storage: MemoryPreferenceStorage())
        store.update { $0.autoSave = true }
        store.resetToDefaults()
        #expect(store.preferences == Preferences())
    }
}

@Suite("OnboardingModel (FR-01)")
@MainActor
struct OnboardingModelTests {
    @Test("First launch walks local processing → shortcuts → done and persists completion")
    func flow() {
        let storage = MemoryPreferenceStorage()
        let settings = SettingsStore(storage: storage)
        let model = OnboardingModel(settings: settings)
        #expect(model.shouldPresent)
        #expect(model.step == .localProcessing)
        #expect(model.canGoBack == false)
        model.next()
        #expect(model.step == .shortcuts)
        #expect(model.canGoBack)
        model.back()
        #expect(model.step == .localProcessing)
        model.next()
        model.next()
        #expect(model.step == .done)
        #expect(settings.preferences.hasCompletedOnboarding)
        #expect(OnboardingModel(settings: SettingsStore(storage: storage)).shouldPresent == false)
    }

    @Test("Skipping finishes onboarding without assigning any shortcut")
    func skip() {
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        let model = OnboardingModel(settings: settings)
        model.finish()
        #expect(model.step == .done)
        #expect(model.shouldPresent == false)
    }
}
