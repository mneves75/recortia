import AppKit
import SwiftUI

/// Recortia's Settings window (FR-14), owned in AppKit with native toolbar tabs.
///
/// SwiftUI's `Settings` scene creates and orders its window inside `openSettings`, before any
/// Space policy can exist; on macOS 27 a fresh one switched the user out of another app's
/// fullscreen Space. This window follows the active Space from the moment it exists (FR-01).
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    /// Orders the window onto the current Space, then activates: the window moves to the user
    /// instead of macOS switching to the Space where it was last shown.
    func show() {
        if window == nil {
            let created = Self.makeWindow(model: model)
            created.center(on: ScreenChoice.screen())
            window = created
        }
        AppPresence.shared.windowWillAppear()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func makeWindow(model: AppModel) -> NSWindow {
        let window = NSWindow(contentViewController: makeTabs(model: model))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        SpacePolicy.follow(window)
        return window
    }

    /// One toolbar tab per area, as macOS Settings windows show them; the window title follows
    /// the selected tab.
    static func makeTabs(model: AppModel) -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add<Content: View>(_ title: String, _ symbol: String, _ content: Content) {
            let pane = NSHostingController(rootView: content.frame(width: 560).frame(minHeight: 360))
            pane.sizingOptions = [.preferredContentSize]
            pane.title = title
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        add(
            String(localized: "General"), "gearshape",
            GeneralSettingsTab(settings: model.settings, loginItem: model.features?.loginItem))
        add(
            String(localized: "Shortcuts"), "keyboard",
            ShortcutsSettingsTab(status: model.shortcutStatus, onRestoreDefaults: model.restoreDefaultShortcuts))
        add(String(localized: "Capture"), "camera.viewfinder", CaptureSettingsTab(settings: model.settings))
        add(
            String(localized: "Export"), "square.and.arrow.up",
            ExportSettingsTab(settings: model.settings, folders: model.features?.services.folders))
        add(
            String(localized: "GitHub"), "icloud.and.arrow.up",
            GitHubUploadSettings(settings: model.settings, credentials: model.features?.services.githubCredentials))
        add(String(localized: "Privacy"), "hand.raised", PrivacySettingsTab())
        add(
            String(localized: "Text Recognition"), "text.viewfinder",
            OCRSettingsTab(settings: model.settings, languages: model.features?.ocrLanguages))
        add(String(localized: "Pins"), "pin", PinsSettingsTab(settings: model.settings))
        add(
            String(localized: "Scrolling"), "arrow.up.and.down.text.horizontal",
            ScrollingSettingsTab(settings: model.settings, accessibility: model.features?.services.accessibility))
        return tabs
    }
}
