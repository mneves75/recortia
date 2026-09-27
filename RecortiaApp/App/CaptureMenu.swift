import AppKit

/// Recortia's ⇧⌘5 (ADR-005): every capture mode in a menu at the pointer, the counterpart of the
/// macOS Screenshot options. It adds no capture logic; each item performs an `AppCommand`.
@MainActor
final class CaptureMenuPresenter: NSObject {
    private weak var actions: (any AppActions)?
    private var isPresenting = false

    init(actions: any AppActions) {
        self.actions = actions
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
        NSApp.activate()
        makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = AppCommand(rawValue: raw) else { return }
        // After the menu closes, so the capture UI does not open under the menu's tracking loop.
        Task { @MainActor [weak actions] in actions?.perform(command) }
    }
}
