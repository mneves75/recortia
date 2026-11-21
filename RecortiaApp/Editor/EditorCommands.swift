import AppKit
import Features
import SwiftUI

/// The two collapsible columns of an editor window.
enum EditorPane {
    case sidebar, inspector
}

/// Which columns of one editor window are collapsed, and the inspector tab the person picked. The
/// status bar reads it to carry the cosmetic-effect warning (FR-06) while the inspector is hidden.
@Observable
final class EditorPanes {
    var sidebarCollapsed = false
    var inspectorCollapsed = false
    /// The person's own choice (the tab control or View › Inspector), cleared whenever the
    /// selection or the tool changes.
    var chosenInspectorTab: EditorInspectorTab?
}

/// The inspector's two tabs. Without the person's choice the shown tab follows the selection and
/// the active tool: Format while either has properties to show, Image otherwise.
enum EditorInspectorTab: Hashable, CaseIterable {
    case format, image

    /// Tools whose options live in the Format tab.
    static let formatTools: Set<EditorTool> = [
        .text, .arrow, .line, .rectangle, .ellipse, .freehand, .highlighter, .step, .redact, .blur, .pixelate,
        .loupe, .ruler, .colorPicker, .crop,
    ]

    var title: String {
        switch self {
        case .format: String(localized: "Format", table: "Editor")
        case .image: String(localized: "Image", table: "Editor")
        }
    }

    static func hasFormat(_ model: EditorModel) -> Bool {
        !model.selection.isEmpty || formatTools.contains(model.tool)
    }

    static func shown(chosen: EditorInspectorTab?, model: EditorModel) -> EditorInspectorTab {
        chosen ?? (hasFormat(model) ? .format : .image)
    }
}

extension EditorTool {
    /// The tools the toolbar shows directly, in its order; the Effects and Measure menus follow.
    static let toolbarTools: [EditorTool] = [
        .select, .hand, .crop, .text, .arrow, .line, .rectangle, .ellipse, .freehand, .highlighter, .step, .redact,
    ]

    /// The Tools menu's sections: the toolbar's order, one section per toolbar group.
    static let menuSections: [[EditorTool]] = [toolbarTools] + ToolMenuGroup.allCases.map(\.tools)
}

/// The editor window that is key, for the editor's main-menu commands: they act on that editor
/// alone and are disabled while any other window (or none) is key. Menu-bar commands re-read state
/// only through `@ObservedObject`, so this publishes a change whenever the key editor, its columns
/// or the state a command shows changes. The editor is held weakly, so a closed editor is never kept.
final class EditorCommands: ObservableObject {
    static let shared = EditorCommands()

    private(set) weak var keyEditor: EditorWindowController?
    @Published private var revision = 0

    func editorBecameKey(_ editor: EditorWindowController) {
        keyEditor = editor
        changed()
        observeMenuState(of: editor)
    }

    /// Republishes whenever the key editor changes what a command shows: whether Arrange can act
    /// (selection, text input, masking), the checked tool, Zoom to Selection, the output preview,
    /// whether an export can start, and the inspector tab.
    private func observeMenuState(of editor: EditorWindowController) {
        withObservationTracking {
            let model = editor.model
            _ = model.canArrangeSelection
            _ = model.canTransformImage
            _ = model.canTransformLayers
            _ = model.tool
            _ = model.selection
            _ = model.showsOutputPreview
            _ = model.canStartExport
            _ = editor.panes.chosenInspectorTab
        } onChange: { [weak self, weak editor] in
            Task { @MainActor in
                guard let self, let editor, self.keyEditor === editor else { return }
                self.changed()
                self.observeMenuState(of: editor)
            }
        }
    }

    func editorResignedKey(_ editor: EditorWindowController) {
        guard keyEditor === editor else { return }
        keyEditor = nil
        changed()
    }

    func panesChanged(_ editor: EditorWindowController) {
        if keyEditor === editor { changed() }
    }

    /// SwiftUI applies a command's title, check mark and enabled state to its menu item only when
    /// the menu updates (`menuNeedsUpdate`), and a key equivalent never updates it: until a menu
    /// was opened, ⌘W would stay disabled in a new editor and a stale Tools item would stay enabled
    /// (decisions 2026-11-20). After SwiftUI re-evaluates the commands, on the next main-queue
    /// turn, each top-level menu is brought up to date as opening it would.
    private func changed() {
        revision &+= 1
        DispatchQueue.main.async {
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)
            }
        }
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

/// The editor's main-menu commands, for the key editor window: File (open, paste, close, save),
/// View (columns, zoom, output preview, inspector tab), Tools and Arrange. Edit's standard Undo,
/// Redo, Copy, Delete and Select All reach the canvas through the responder chain. Each command
/// rechecks its live target when chosen and beeps without one.
///
/// Tool letters are real key equivalents without modifiers. AppKit offers an unmodified key to the
/// first responder's `keyDown` before any menu, so the canvas, a text annotation (marked text
/// included) and every text field keep their letters; the menu acts only when the focused view
/// ignores the key (decisions 2026-11-20).
struct EditorMenuCommands: Commands {
    @ObservedObject var commands: EditorCommands
    /// Open Image… and Paste Image open a new editor, so they need none.
    let app: any AppActions

    var body: some Commands {
        let editor = commands.keyEditor
        let model = editor?.model
        let panes = editor?.panes
        let canExport = model?.canStartExport == true
        CommandGroup(replacing: .newItem) {
            appCommand(.openImage)
                .keyboardShortcut("o")
            appCommand(.pasteImage)
        }
        CommandGroup(replacing: .saveItem) {
            Button(String(localized: "Close", table: "Editor")) { onKeyEditor { $0.window?.performClose(nil) } }
                .keyboardShortcut("w")
                .disabled(editor == nil)
            Button(String(localized: "Save…", table: "Editor")) { onKeyEditor { $0.saveImage() } }
                .keyboardShortcut("s")
                .disabled(!canExport)
            Button(String(localized: "Save to Preferred Folder", table: "Editor")) {
                onKeyEditor { $0.saveToPreferredFolder() }
            }
            .disabled(!canExport)
        }
        CommandGroup(replacing: .sidebar) {
            Button(
                panes?.sidebarCollapsed == true
                    ? String(localized: "Show Sidebar", table: "Editor")
                    : String(localized: "Hide Sidebar", table: "Editor")
            ) {
                onKeyEditor { $0.toggle(.sidebar) }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(editor == nil)
            Button(
                panes?.inspectorCollapsed == true
                    ? String(localized: "Show Inspector", table: "Editor")
                    : String(localized: "Hide Inspector", table: "Editor")
            ) {
                onKeyEditor { $0.toggle(.inspector) }
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(editor == nil)
            let shownTab = model.map { EditorInspectorTab.shown(chosen: panes?.chosenInspectorTab, model: $0) }
            Menu(String(localized: "Inspector", table: "Editor")) {
                ForEach(EditorInspectorTab.allCases, id: \.self) { tab in
                    Toggle(tab.title, isOn: checked(shownTab == tab) { $0.showInspectorTab(tab) })
                }
            }
            .disabled(editor == nil)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Group {
                Button(String(localized: "Zoom In", table: "Editor")) { onKeyEditor { $0.model.zoomIn() } }
                    .keyboardShortcut("+")
                Button(String(localized: "Zoom Out", table: "Editor")) { onKeyEditor { $0.model.zoomOut() } }
                    .keyboardShortcut("-")
                Button(String(localized: "Actual Pixels", table: "Editor")) {
                    onKeyEditor { $0.model.zoomToActualPixels() }
                }
                .keyboardShortcut("1")
                Button(String(localized: "Zoom to Fit", table: "Editor")) { onKeyEditor { $0.model.zoomToFit() } }
                    .keyboardShortcut("0")
            }
            .disabled(editor == nil)
            Button(String(localized: "Zoom to Selection", table: "Editor")) {
                onKeyEditor { $0.model.zoomToSelection() }
            }
            .disabled(model?.selection.isEmpty != false)
            Divider()
            // Like the inspector's toggle; pending text is committed first, never discarded.
            Toggle(
                String(localized: "Show Output Preview", table: "Editor"),
                isOn: Binding(
                    get: { model?.showsOutputPreview == true },
                    set: { shows in
                        onKeyEditor {
                            $0.commitPendingText()
                            $0.model.setShowsOutputPreview(shows)
                        }
                    })
            )
            .disabled(editor == nil)
        }
        // Like the toolbar's tool buttons: pending text is committed, then the tool is chosen.
        CommandMenu(String(localized: "Tools", table: "Editor")) {
            ForEach(Array(EditorTool.menuSections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section, id: \.self) { tool in
                    Toggle(
                        EditorStrings.name(tool),
                        isOn: checked(model?.tool == tool) {
                            $0.commitPendingText()
                            $0.model.selectTool(tool)
                        }
                    )
                    .keyboardShortcut(KeyEquivalent(tool.shortcutKey), modifiers: [])
                    .disabled(editor == nil)
                }
            }
        }
        // Enabled exactly when the key editor can arrange its selection: never during text input
        // (IME included) or automatic masking. A command rechecks its live target when chosen and
        // never commits pending text itself.
        CommandMenu(String(localized: "Arrange", table: "Editor")) {
            EditorArrangeMenuItems(isAvailable: model?.canArrangeSelection ?? false) { command in
                guard let target = EditorCommands.targetEditor(), target.model.canArrangeSelection else {
                    return NSSound.beep()
                }
                command.perform(on: target.model)
            }
        }
        CommandMenu(String(localized: "Image", table: "Editor")) {
            EditorImageMenuItems(model: model)
        }
    }

    /// Runs `action` on the editor that is key when the command runs, or beeps.
    private func onKeyEditor(_ action: (EditorWindowController) -> Void) {
        guard let target = EditorCommands.targetEditor() else { return NSSound.beep() }
        action(target)
    }

    /// A checked menu item's binding: choosing the unchecked item runs `choose`; choosing the
    /// checked one again leaves it as it is.
    private func checked(_ isOn: Bool, choose: @escaping (EditorWindowController) -> Void) -> Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                guard on else { return }
                onKeyEditor(choose)
            })
    }

    private func appCommand(_ command: AppCommand) -> some View {
        Button(command.title) {
            guard app.isEnabled(command) else { return NSSound.beep() }
            app.perform(command)
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
