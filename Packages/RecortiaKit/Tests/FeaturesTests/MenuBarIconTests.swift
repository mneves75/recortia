import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-01, ADR-007 amendment): the icon is hidden by default or after an update;
// a required key resets every older blob; the explanation never appears, appears on every
// change, or appears again after the person has read it once; hiding the icon turns keep
// running off, so closing the last window would quit; opening Recortia stops showing Settings,
// the only way back once the icon is hidden (hosted CI runs no E2E, so this guard is a unit test).
@Suite("Menu-bar icon (FR-01)")
@MainActor
struct MenuBarIconTests {
    @Test("The icon shows by default, hiding it persists, and older blobs still show it")
    func preference() throws {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        #expect(store.preferences.showsMenuBarIcon)
        store.setShowsMenuBarIcon(false)
        #expect(SettingsStore(storage: storage).preferences.showsMenuBarIcon == false)

        let written = try #require(storage.values[SettingsStore.storageKey])
        var old = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        old = old.filter { !$0.key.localizedCaseInsensitiveContains("icon") }
        old["captureDelaySeconds"] = 7
        let legacy = MemoryPreferenceStorage()
        legacy.setPreferenceData(try JSONSerialization.data(withJSONObject: old), forKey: SettingsStore.storageKey)
        let loaded = SettingsStore(storage: legacy)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.captureDelaySeconds == 7)
        #expect(loaded.preferences.showsMenuBarIcon)
    }

    @Test("Only the first time the icon is hidden asks for the explanation, also after a relaunch")
    func explainsOnce() {
        let storage = MemoryPreferenceStorage()
        let store = SettingsStore(storage: storage)
        #expect(store.setShowsMenuBarIcon(true) == false, "showing a shown icon explains nothing")
        #expect(store.setShowsMenuBarIcon(false))
        #expect(store.setShowsMenuBarIcon(false) == false, "already hidden")
        #expect(store.setShowsMenuBarIcon(true) == false)
        #expect(store.setShowsMenuBarIcon(false) == false, "explained before")
        #expect(!store.preferences.showsMenuBarIcon)

        let relaunched = SettingsStore(storage: storage)
        relaunched.setShowsMenuBarIcon(true)
        #expect(relaunched.setShowsMenuBarIcon(false) == false)
    }

    @Test("Hiding the icon leaves keep running in the menu bar on")
    func keepRunningUnchanged() {
        let store = SettingsStore(storage: MemoryPreferenceStorage())
        store.setShowsMenuBarIcon(false)
        #expect(store.preferences.keepsRunningInMenuBar)
    }

    @Test("Opening Recortia shows Settings once onboarding is done; Open at login stays silent")
    func launchWindow() {
        #expect(LaunchWindow.choose(onboardingPending: false, kind: .user, opensFiles: false) == .settings)
        #expect(LaunchWindow.choose(onboardingPending: false, kind: .loginItem, opensFiles: false) == .none)
        #expect(LaunchWindow.choose(onboardingPending: true, kind: .user, opensFiles: false) == .onboarding)
        #expect(LaunchWindow.choose(onboardingPending: true, kind: .loginItem, opensFiles: false) == .onboarding)
        #expect(LaunchWindow.choose(onboardingPending: false, kind: .user, opensFiles: true) == .none)
        #expect(LaunchWindow.choose(onboardingPending: true, kind: .user, opensFiles: true) == .none)
    }
}
