import SwiftUI

/// Menu-bar-only app (LSUIElement). Commands are wired by the composition root in `AppModel`.
@main
struct FramepinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Framepin", systemImage: "viewfinder") {
            Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            Divider()
            Button("Quit Framepin") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            Text("Framepin")
                .padding()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {}
