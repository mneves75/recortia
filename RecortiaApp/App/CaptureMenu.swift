import AppKit

/// Recortia's ⇧⌘5 (ADR-005): every capture mode in a menu at the pointer, the counterpart of the
/// macOS Screenshot options. It adds no capture logic; each item performs an `AppCommand`.
@MainActor
final class CaptureMenuPresenter: NSObject {
    /// The focus operations around the menu; tests replace them so no real app is activated.
    struct Focus {
        var frontmost: @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
        var activate: @MainActor () -> Void = { NSApp.activate() }
        var popUp: @MainActor (NSMenu) -> Void = { $0.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
        var returnFocus: @MainActor (NSRunningApplication) -> Void = { app in
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    private weak var actions: (any AppActions)?
    private let focus: Focus
    private var isPresenting = false
    private var didChoose = false

    init(actions: any AppActions, focus: Focus = Focus()) {
        self.actions = actions
        self.focus = focus
    }

    /// The menu for the current state: a mode whose backend is unavailable is disabled.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: AppCommand.captureMenu.title)
        menu.autoenablesItems = false
        for command in AppCommand.captureModes {
            let item = NSMenuItem(title: command.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
            item.isEnabled = actions?.isEnabled(command) == true
            menu.addItem(item)
        }
        return menu
    }

    /// Shows the menu at the pointer. A second shortcut press while it is open does nothing.
    func present() {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }
        // The menu needs Recortia active for keyboard navigation. Escape or a click outside must
        // hand focus back to the app the user was in; a chosen mode keeps it for the capture.
        let previous = focus.frontmost()
        didChoose = false
        focus.activate()
        focus.popUp(makeMenu())
        if !didChoose, let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            focus.returnFocus(previous)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = AppCommand(rawValue: raw) else { return }
        didChoose = true
        // After the menu closes, so the capture UI does not open under the menu's tracking loop.
        Task { @MainActor [weak actions] in actions?.perform(command) }
    }
}
