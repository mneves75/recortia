import AppKit
import Features
import SwiftUI

/// The two collapsible columns of an editor window.
enum EditorPane {
    case sidebar, inspector
}

/// Which columns of one editor window are collapsed. The status bar reads it to carry the
/// cosmetic-effect warning (FR-06) while the inspector is hidden.
@Observable
final class EditorPanes {
    var sidebarCollapsed = false
    var inspectorCollapsed = false
}

/// The editor window that is key, for the View and Arrange menus: their commands act on that
/// editor alone and are disabled while any other window (or none) is key. Menu-bar commands
/// re-read state only through `@ObservedObject`, so this publishes a change whenever the key
/// editor or its columns change. The editor is held weakly, so a closed editor is never kept.
final class EditorCommands: ObservableObject {
    static let shared = EditorCommands()

    private(set) weak var keyEditor: EditorWindowController?
    @Published private var revision = 0

    func editorBecameKey(_ editor: EditorWindowController) {
        keyEditor = editor
        revision &+= 1
    }

    func editorResignedKey(_ editor: EditorWindowController) {
        guard keyEditor === editor else { return }
        keyEditor = nil
        revision &+= 1
    }

    func panesChanged(_ editor: EditorWindowController) {
        if keyEditor === editor { revision &+= 1 }
    }

    /// The editor a menu command acts on, resolved when the command runs rather than when the
    /// menu was built: the editor whose window is key with no sheet attached, or none.
    static func targetEditor() -> EditorWindowController? {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return nil }
        return window.windowController as? EditorWindowController
    }
}

/// One Arrange command: a z-order change, an alignment, or Duplicate.
enum EditorArrangeCommand: Hashable {
    case order(EditorZOrder)
    case align(EditorAlignment)
    case duplicate

    static let orders: [EditorZOrder] = [.forward, .backward, .front, .back]

    var title: String {
        switch self {
        case .order(.forward): String(localized: "Bring Forward", table: "Editor")
        case .order(.backward): String(localized: "Send Backward", table: "Editor")
        case .order(.front): String(localized: "Bring to Front", table: "Editor")
        case .order(.back): String(localized: "Send to Back", table: "Editor")
        case .align(let alignment): EditorStrings.name(alignment)
        case .duplicate: String(localized: "Duplicate", table: "Editor")
        }
    }

    static var alignTitle: String { String(localized: "Align", table: "Editor") }

    @MainActor
    func perform(on model: EditorModel) {
        switch self {
        case .order(let order): model.reorderSelection(order)
        case .align(let alignment): model.align(alignment)
        case .duplicate: model.duplicateSelection()
        }
    }

    /// Arrange acts on a selection, never while text input owns the keyboard.
    @MainActor
    static func isAvailable(for model: EditorModel) -> Bool { model.canArrangeSelection }
}

// MARK: - Menu bar

/// View › Show/Hide Sidebar (⌃⌘S) and Show/Hide Inspector (⌃⌘I), and the Arrange menu, for the
/// key editor window.
struct EditorMenuCommands: Commands {
    @ObservedObject var commands: EditorCommands

    var body: some Commands {
        let editor = commands.keyEditor
        let panes = editor?.panes
        CommandGroup(replacing: .sidebar) {
            Button(
                panes?.sidebarCollapsed == true
                    ? String(localized: "Show Sidebar", table: "Editor")
                    : String(localized: "Hide Sidebar", table: "Editor")
            ) {
                guard let target = EditorCommands.targetEditor() else { return NSSound.beep() }
                target.toggle(.sidebar)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(editor == nil)
            Button(
                panes?.inspectorCollapsed == true
                    ? String(localized: "Show Inspector", table: "Editor")
                    : String(localized: "Hide Inspector", table: "Editor")
            ) {
                guard let target = EditorCommands.targetEditor() else { return NSSound.beep() }
                target.toggle(.inspector)
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(editor == nil)
        }
        // Enabled for a key editor. When chosen, a command refuses while text input (IME included)
        // or automatic masking owns the editor, and never commits pending text itself.
        CommandMenu(String(localized: "Arrange", table: "Editor")) {
            EditorArrangeMenuItems(isAvailable: editor != nil) { command in
                guard let target = EditorCommands.targetEditor(), target.model.canArrangeSelection else {
                    return NSSound.beep()
                }
                command.perform(on: target.model)
            }
        }
    }
}

/// The Arrange menu for the key editor window; the object list's context menu shows the same items.
struct EditorArrangeMenuItems: View {
    let isAvailable: Bool
    var showsShortcuts = true
    let perform: (EditorArrangeCommand) -> Void

    var body: some View {
        Group {
            ForEach(EditorArrangeCommand.orders, id: \.self) { order in
                Button(EditorArrangeCommand.order(order).title) { perform(.order(order)) }
            }
            Divider()
            Menu(EditorArrangeCommand.alignTitle) {
                ForEach(EditorAlignment.allCases, id: \.self) { alignment in
                    Button(EditorArrangeCommand.align(alignment).title) { perform(.align(alignment)) }
                }
            }
            Divider()
            if showsShortcuts {
                Button(EditorArrangeCommand.duplicate.title) { perform(.duplicate) }
                    .keyboardShortcut("d")
            } else {
                Button(EditorArrangeCommand.duplicate.title) { perform(.duplicate) }
            }
        }
        .disabled(!isAvailable)
    }
}

// MARK: - Canvas context menu

extension EditorArrangeCommand {
    /// The canvas's context menu: the Arrange items, then Delete (which lives in Edit).
    @MainActor
    static func contextMenu(for model: EditorModel) -> NSMenu {
        let menu = NSMenu()
        for order in orders {
            let command = EditorArrangeCommand.order(order)
            menu.addItem(ClosureMenuItem.make(command.title) { command.perform(on: model) })
        }
        menu.addItem(.separator())
        let align = NSMenuItem(title: alignTitle, action: nil, keyEquivalent: "")
        let alignMenu = NSMenu(title: alignTitle)
        for alignment in EditorAlignment.allCases {
            alignMenu.addItem(
                ClosureMenuItem.make(EditorArrangeCommand.align(alignment).title) {
                    EditorArrangeCommand.align(alignment).perform(on: model)
                })
        }
        align.submenu = alignMenu
        menu.addItem(align)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem.make(duplicate.title) { duplicate.perform(on: model) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem.make(String(localized: "Delete", table: "Editor")) { model.deleteSelection() })
        return menu
    }
}
