import KeyboardShortcuts
import SwiftUI

/// The menu-bar menu (FR-01). Every item calls `AppActions`; items whose backend is not wired are
/// disabled. A global shortcut hint appears next to an item only while that shortcut works: not
/// while macOS still uses its keys (ADR-005).
struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Group {
            item(.captureRegion, shortcut: .captureRegion)
            item(.captureDisplay, shortcut: .captureDisplay)
            item(.captureWindow, shortcut: .captureWindow)
            item(.captureWithDelay, shortcut: .captureWithDelay)
            item(.repeatLastRegion, shortcut: .repeatLastRegion)
            Divider()
            item(.scrollingCapture, shortcut: .scrollingCapture)
            item(.captureText, shortcut: .captureText)
            Divider()
            item(.openImage)
            item(.pasteImage)
            Divider()
            Menu(String(localized: "Pins")) {
                item(.bringPinsForward)
                item(.closeAllPins)
            }
            Divider()
            item(.settings)
                .keyboardShortcut(",")
            item(.about)
            Divider()
            item(.quit)
                .keyboardShortcut("q")
        }
    }

    private func item(_ command: AppCommand, shortcut: KeyboardShortcuts.Name? = nil) -> some View {
        Button(command.title) { model.perform(command) }
            .disabled(!model.isEnabled(command))
            .globalShortcut(shortcut.flatMap { model.shortcutStatus.state(of: $0.rawValue) == .active ? $0 : nil })
    }
}

extension View {
    /// Shows an active global shortcut as the menu item's key equivalent hint.
    @ViewBuilder
    fileprivate func globalShortcut(_ name: KeyboardShortcuts.Name?) -> some View {
        if let name, let shortcut = KeyboardShortcuts.getShortcut(for: name)?.toSwiftUI {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}

#if DEBUG
    #Preview("Menu") {
        MenuContent(model: PreviewSupport.appModel())
            .padding()
    }
#endif
