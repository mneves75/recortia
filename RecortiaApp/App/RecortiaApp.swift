import AppKit
import Features
import MacPlatform
import SwiftUI

/// Menu-bar-only app (LSUIElement). Relaunching reuses this process; Settings stays reachable
/// from the menu when no other window is open.
@main
struct RecortiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            Label(String(localized: "Recortia"), systemImage: "viewfinder")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Integration: pass the live `AppServices` built from Imaging and MacPlatform here. With nil,
    // commands needing a backend are disabled and nothing is faked.
    private let integrity = KeychainPreferenceIntegrity()
    let model: AppModel

    override init() {
        #if RECORTIA_E2E
            // The E2E binary exists only for the scenario runner and its probe processes: it never
            // reads or writes the user's preferences or keychain, whatever it was launched with.
            let settings = SettingsStore.e2eInMemory()
        #else
            let settings = SettingsStore(storage: UserDefaults.standard, integrity: integrity)
        #endif
        model = AppModel(settings: settings, services: .live(), shortcutRegistry: KeyboardShortcutsRegistry())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if RECORTIA_E2E
            // Only in the RecortiaE2E target: `-RecortiaE2E <dir>` runs the scenario runner
            // (RecortiaApp/E2E) instead of the normal launch; the process exits with its result.
            if E2ERunner.startIfRequested() { return }
        #else
            integrity.prepare()
            ShortcutDefaults.seedIfNeeded(isNewInstall: !model.settings.preferences.hasCompletedOnboarding)
        #endif
        model.launch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.shouldTerminate() ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showSettings() }
        return true
    }
}
