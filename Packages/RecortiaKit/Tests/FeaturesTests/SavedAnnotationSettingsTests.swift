import Domain
import Features
import Foundation
import Testing

@Suite("Saved annotation preferences (FR-14, PRIV-01, NET-01)")
@MainActor
struct SavedAnnotationSettingsTests {
    @Test("A sealed schema-1 blob gains saved colors without resetting preferences or upload consent")
    func sealedLegacyPreferences() throws {
        let data = Data(
            """
            {"schemaVersion":1,"hasCompletedOnboarding":true,"captureDelaySeconds":4,
             "captureShowsCursor":true,"captureIncludesWindowShadow":false,"autoCopy":true,
             "autoSave":true,"launchAtLogin":false,"updateChecksEnabled":false,
             "automaticScrollingEnabled":true,"defaultExportFormat":"jpeg","jpegQuality":0.7,
             "defaultExportScale":2,"ocrTextMode":"raw","pinDefaultOpacity":0.6,
             "preferredSaveFolderBookmark":"AQID",
             "githubUpload":{"destination":{"owner":"fixture","repository":"captures"},"automatic":true}}
            """.utf8)
        let storage = MemoryPreferenceStorage()
        let integrity = FixedKeyPreferenceIntegrity()
        storage.values[SettingsStore.storageKey] = data
        storage.values[SettingsStore.sealKey] = integrity.seal(data)
        let store = SettingsStore(storage: storage, integrity: integrity)
        #expect(store.loadIssue == nil)
        #expect(store.preferences.schemaVersion == 2)
        #expect(store.preferences.annotationPalette == nil)
        #expect(storage.writeCount == 0)
        #expect(store.preferences.autoCopy && store.preferences.autoSave)
        #expect(store.preferences.automaticScrollingEnabled)
        #expect(store.preferences.preferredSaveFolderBookmark == Data([1, 2, 3]))
        #expect(store.preferences.githubUpload?.automatic == true)
        #expect(store.preferences.hasCompletedOnboarding)
        #expect(store.preferences.captureDelaySeconds == 4)
        #expect(store.preferences.exportOptions == ExportOptions(format: .jpeg(quality: 0.7), scale: 2))
        let identity = store.githubUploadConsentID
        var expected = store.preferences
        var palette = SavedAnnotationPalette()
        palette.insert(.yellow)
        expected.annotationPalette = palette
        store.update { $0.annotationPalette = palette }
        #expect(store.preferences == expected)
        #expect(store.githubUploadConsentID == identity)
        let reloaded = SettingsStore(storage: storage, integrity: integrity)
        #expect(reloaded.loadIssue == nil)
        #expect(reloaded.preferences == expected)
        #expect(Set(storage.values.keys) == [SettingsStore.storageKey, SettingsStore.sealKey])
    }

    @Test("A future schema stays protected even when its palette format is incompatible")
    func futurePaletteFormat() throws {
        let storage = MemoryPreferenceStorage()
        var future = Preferences()
        future.schemaVersion = 3
        let encoded = try JSONEncoder().encode(future)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["annotationPalette"] = ["futureFormat": [1, 2, 3]]
        let data = try JSONSerialization.data(withJSONObject: object)
        storage.values[SettingsStore.storageKey] = data
        let settings = SettingsStore(storage: storage)
        #expect(settings.loadIssue == .unsupportedSchema(3))
        let h = EditorHarness(settings: settings)
        defer { h.model.close() }
        #expect(!h.model.canSaveStrokeColor)
        #expect(!h.model.saveCurrentStrokeColor())
        settings.update { $0.hasCompletedOnboarding = true }
        #expect(storage.values[SettingsStore.storageKey] == data)
        #expect(storage.writeCount == 0)
    }

    @Test("An unsealed palette still loads while every unverified side-effect consent is dropped")
    func unsealedPaletteDoesNotGrantConsent() throws {
        let storage = MemoryPreferenceStorage()
        var preferences = Preferences()
        var palette = SavedAnnotationPalette()
        palette.insert(.red)
        preferences.annotationPalette = palette
        preferences.autoCopy = true
        preferences.autoSave = true
        preferences.automaticScrollingEnabled = true
        preferences.preferredSaveFolderBookmark = Data([1, 2, 3])
        preferences.githubUpload = GitHubUploadPreferences(
            destination: GitHubDestination(owner: "fixture", repository: "captures"), automatic: true)
        let data = try JSONEncoder().encode(preferences)
        storage.values[SettingsStore.storageKey] = data
        let settings = SettingsStore(storage: storage)
        #expect(settings.loadIssue == .unverifiedConsent)
        #expect(settings.preferences.annotationPalette == palette)
        #expect(settings.preferences == preferences.withoutSideEffectConsent)
        #expect(storage.values[SettingsStore.storageKey] == data)
        #expect(storage.writeCount == 0)
    }

    @Test("A malformed current-schema palette remains a corruption without a load-time write")
    func malformedCurrentPalette() throws {
        let storage = MemoryPreferenceStorage()
        let encoded = try JSONEncoder().encode(Preferences())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["annotationPalette"] = [["r": 256, "g": 0, "b": 0, "a": 255]]
        let data = try JSONSerialization.data(withJSONObject: object)
        storage.values[SettingsStore.storageKey] = data
        let settings = SettingsStore(storage: storage)
        #expect(settings.loadIssue == .corrupted)
        #expect(settings.preferences == Preferences())
        #expect(storage.values[SettingsStore.storageKey] == data)
        #expect(storage.writeCount == 0)
    }
}
