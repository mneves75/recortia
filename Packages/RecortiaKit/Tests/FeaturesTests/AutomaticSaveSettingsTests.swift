import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (owner request 2026-10-31): automatic saving writes screenshots to disk, so it
// must never be on without a folder the person chose. Turning it on without a reachable folder,
// canceling the folder panel, a folder whose access cannot be remembered, and clearing the
// folder must all leave a state where nothing is written silently or anywhere else.
@Suite("Automatic save needs a chosen folder (FR-07)")
@MainActor
struct AutomaticSaveSettingsTests {
    private struct Refused: Error {}

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "recortia-autosave-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Turning automatic save on without a reachable folder asks for one; cancel or failure changes nothing")
    func enablingNeedsAFolder() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        let folders = FakeSaveFolders()
        var asked = 0
        try store.setAutomaticSave(true, folders: folders) {
            asked += 1
            return nil
        }
        #expect(asked == 1)
        #expect(!store.preferences.autoSave && store.preferences.preferredSaveFolderBookmark == nil)
        #expect(storage.writeCount == 0, "a canceled choice writes nothing")

        #expect(throws: Refused.self) { try store.setAutomaticSave(true, folders: folders) { throw Refused() } }
        #expect(!store.preferences.autoSave && storage.writeCount == 0)

        let chosen = try folder()
        defer { try? FileManager.default.removeItem(at: chosen) }
        try store.setAutomaticSave(true, folders: folders) { chosen }
        let bookmark = try #require(store.preferences.preferredSaveFolderBookmark)
        #expect(store.preferences.autoSave)
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        #expect(resolved.resolvingSymlinksInPath().path == chosen.resolvingSymlinksInPath().path)

        // A remembered folder that no longer resolves is not reused: the person chooses again.
        try store.setAutomaticSave(false, folders: folders) {
            Issue.record("turning off asks nothing"); return nil
        }
        #expect(!store.preferences.autoSave && store.preferences.preferredSaveFolderBookmark == bookmark)
        asked = 0
        try store.setAutomaticSave(true, folders: folders) {
            asked += 1
            return nil
        }
        #expect(asked == 1 && !store.preferences.autoSave)
        #expect(store.preferences.preferredSaveFolderBookmark == bookmark, "the unavailable folder stays remembered")
        #expect(store.automaticSaveFolder(resolvingWith: folders) == .unavailable)

        folders.folder = chosen
        try store.setAutomaticSave(true, folders: folders) {
            Issue.record("a reachable folder asks nothing"); return nil
        }
        #expect(store.preferences.autoSave && store.automaticSaveFolder(resolvingWith: folders) == .available(chosen))
    }

    @Test("Clearing the folder turns automatic save off in the same change, and saving never stays on without one")
    func clearingDisables() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        store.update {
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1, 2, 3])
        }
        let writes = storage.writeCount
        store.clearAutomaticSaveFolder()
        #expect(!store.preferences.autoSave && store.preferences.preferredSaveFolderBookmark == nil)
        #expect(storage.writeCount == writes + 2, "one persisted change: the blob and its seal")
        let reloaded = SettingsStore(storage: storage)
        #expect(!reloaded.preferences.autoSave && reloaded.preferences.preferredSaveFolderBookmark == nil)

        store.update { $0.autoSave = true }
        #expect(!store.preferences.autoSave, "automatic save cannot be on without a folder")

        // A sealed blob that has automatic save on without a folder loads with it off.
        var legacy = Preferences()
        legacy.autoSave = true
        legacy.captureDelaySeconds = 4
        let old = MemoryPreferenceStorage()
        let data = try JSONEncoder().encode(legacy)
        old.values[SettingsStore.storageKey] = data
        old.values[SettingsStore.sealKey] = FixedKeyPreferenceIntegrity().seal(data)
        let loaded = SettingsStore(storage: old)
        #expect(!loaded.preferences.autoSave && loaded.preferences.captureDelaySeconds == 4)
        #expect(loaded.loadIssue == nil)
    }
}
