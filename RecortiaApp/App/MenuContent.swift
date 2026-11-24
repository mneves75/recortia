import Features
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
            item(.reopenClosedCapture)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Menu(String(localized: "Pins")) {
                item(.bringPinsForward)
                item(.closeAllPins)
                item(.unlockAllPins)
            }
            Divider()
            item(.settings)
                .keyboardShortcut(",")
            item(.about)
            if model.features.updater.isOffered {
                item(.checkForUpdates)
            }
            item(.featureTour)
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

/// Whether Reopen Closed Capture can act, for the app's menu bar: SwiftUI re-reads menu-bar
/// commands only through `@ObservedObject` (see `PinMenuState`), so this republishes the slot.
final class ReopenMenuState: ObservableObject {
    @Published private(set) var canReopen = false
    private var loop: ObservationLoop?

    init(slot: ClosedCaptureSlot) {
        loop = ObservationLoop { [weak self, weak slot] in
            guard let self, let slot, canReopen == slot.isEmpty else { return }
            canReopen = !slot.isEmpty
        }
    }
}

/// File › Reopen Closed Capture (⇧⌘T, B-6), after Open Image… and Paste Image.
struct ReopenMenuCommands: Commands {
    @ObservedObject var state: ReopenMenuState
    let app: any AppActions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(AppCommand.reopenClosedCapture.title) { app.perform(.reopenClosedCapture) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!state.canReopen)
        }
    }
}

extension View {
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
