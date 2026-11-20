import AppKit
import Features
import MacPlatform
import SwiftUI
import os

/// Menu-bar app (LSUIElement) that joins ⌘Tab and the Dock while a window is open (ADR-007).
/// Relaunching reuses this process; Settings stays reachable from the menu when no window is open.
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
        // The app menu is visible while Recortia is regular (ADR-007).
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(AppCommand.settings.title) { appDelegate.model.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {}
        }
        // Settings is an AppKit window (SettingsWindowController) so it follows the active Space.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let integrity = KeychainPreferenceIntegrity()
    let model: AppModel
    #if RECORTIA_E2E
        private let e2eRequest: E2ELaunchRequest
    #endif

    override init() {
        #if RECORTIA_E2E
            // The E2E binary exists only for the scenario runner and its probe processes: it never
            // reads or writes the user's preferences or keychain, whatever it was launched with,
            // and it refuses to launch at all without a valid runner or probe request.
            e2eRequest = E2ERunner.admit()
            let settings = SettingsStore.e2eInMemory()
        #else
            let settings = SettingsStore(storage: UserDefaults.standard, integrity: integrity)
        #endif
        model = AppModel(
            settings: settings, services: .live(settings: settings), shortcutRegistry: KeyboardShortcutsRegistry())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if RECORTIA_E2E
            // Only in the RecortiaE2E target: the admitted request (the scenario runner in
            // RecortiaApp/E2E, or one of its probes) replaces the normal launch.
            E2ERunner.start(e2eRequest)
        #else
            integrity.prepare()
            ShortcutDefaults.seedIfNeeded(isNewInstall: !model.settings.preferences.hasCompletedOnboarding)
            let kind = LaunchKind(openEvent: NSAppleEventManager.shared().currentAppleEvent)
            // Content-free: lets a real login confirm whether macOS marks Open at login (ADR-007).
            Logger(subsystem: "dev.mvneves.Recortia", category: "launch").notice(
                "launch kind: \(String(describing: kind), privacy: .public)")
            model.launch(kind: kind)
        #endif
    }

    /// Open With, a drop on the Dock icon and `open -a` (FR-03). A cold launch delivers this before
    /// `applicationDidFinishLaunching`; the model keeps the files until launch wires the editors.
    func application(_ application: NSApplication, open urls: [URL]) {
        #if RECORTIA_E2E
            E2ERunner.openFiles?(urls)
        #else
            model.openFiles(urls)
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.shouldTerminate() ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.handleReopen(hasVisibleWindows: flag)
        return true
    }
}
