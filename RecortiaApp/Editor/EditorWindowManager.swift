import AppKit
import Domain
import Features
import SwiftUI
import UniformTypeIdentifiers

/// What the chrome (toolbar, inspector) and the canvas ask of their window.
protocol EditorWindowActions: AnyObject {
    func copyImage()
    func saveImage()
    func saveToPreferredFolder()
    func pin()
    func addImageFromFile()
    func pasteImageLayer()
    /// Ends any in-progress text editing (before a toolbar action changes the tool or document).
    func commitPendingText()
    /// Drag-out through the export pipeline: `ExportCoordinator`'s drag action hands the
    /// sanitized snapshot to the app's drag sink, which offers it to other apps.
    func dragOut()
}

enum EditorInitialAction {
    case none
    /// Capture Text: open the editor and recognize text right away.
    case recognizeText
    /// A new capture whose e-mail addresses and phone numbers are masked before it is shown (FR-06).
    case maskSensitiveText
}

/// Opens one editor window per document (FR-04). The composition root calls
/// `open(_:environment:)` for every new document; closing a window releases its model and the
/// asset pixels it held.
final class EditorWindowManager {
    /// The shipped default (decisions 2026-11-21, A-13 step 2): off, because a spare can only be
    /// the window shell, and the editor's cost is its document-bound content, not the shell.
    static let prebuildsSpareByDefault = false

    private enum Spare { case next }

    private var controllers: [DocumentID: EditorWindowController] = [:]
    /// With pre-building, one hidden editor window shell, without a document, for the next editor.
    private let spares: WindowSparePool<Spare, NSWindow>

    init(prebuildsSpare: Bool = EditorWindowManager.prebuildsSpareByDefault) {
        spares = WindowSparePool(isEnabled: prebuildsSpare) { _ in EditorWindowController.makeWindow() }
    }

    /// Builds the spare shell when pre-building and none is held.
    func prepareSpare() {
        spares.prepare([.next])
    }

    /// The hidden shell kept for the next editor, if any.
    var spareWindow: NSWindow? { spares.spare(for: .next) }

    /// Opens `session` in a new window, or brings its existing window forward.
    @discardableResult
    func open(
        _ session: DocumentSession, environment: EditorEnvironment, importedFileName: String? = nil,
        initialAction: EditorInitialAction = .none
    ) -> EditorModel {
        let id = session.document.id
        if let existing = controllers[id] {
            existing.present()
            return existing.model
        }
        let model = EditorModel(
            session: session, environment: environment, autoRedacts: initialAction == .maskSensitiveText)
        let controller = EditorWindowController(
            model: model, importedFileName: importedFileName, window: spares.take(.next))
        controller.onClosed = { [weak self] in self?.controllers[id] = nil }
        controllers[id] = controller
        if spares.isEnabled {
            // The next spare is built after this editor's first frame, never in its way.
            controller.whenFirstDrawn { [weak self] in Task { @MainActor in self?.prepareSpare() } }
        }
        controller.present()
        if initialAction == .recognizeText {
            Task { await model.recognizeText() }
        }
        return model
    }

    /// Editors whose edits were never copied or saved (a drag out saves; a pin does not).
    var unexportedEditCount: Int { controllers.values.filter { $0.hasUnexportedEdits() }.count }

    /// The window of `model`'s editor, while it is open.
    func window(for model: EditorModel) -> NSWindow? {
        controllers.values.first { $0.model === model }?.window
    }
}

/// One editor window: hosts the SwiftUI chrome around the AppKit canvas in a system split view, asks before discarding
/// unexported edits, and closes the model when the window closes.
final class EditorWindowController: NSWindowController, NSWindowDelegate, EditorWindowActions {
    let model: EditorModel
    let panes = EditorPanes()
    var onClosed: (() -> Void)?
    private let canvas: EditorCanvasView
    private var discardConfirmed = false

    /// The window shell, without a document: what a spare holds (A-13 step 2) and what every
    /// editor is built in. Its Space policy is set here, at construction (FR-01).
    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The capture result follows the current Space, including another app's fullscreen
        // Space. Primary and auxiliary fullscreen behavior are mutually exclusive.
        window.collectionBehavior = SpacePolicy.followsActiveSpace
        window.contentMinSize = NSSize(
            width: EditorWindowSizing.minimumContentSize.width, height: EditorWindowSizing.minimumContentSize.height)
        window.tabbingMode = .disallowed
        return window
    }

    /// `window` is a spare shell from `makeWindow()` that was never shown; nil builds one.
    init(
        model: EditorModel, importedFileName: String? = nil,
        noticePresentation: EditorNoticePresentation = EditorNoticePresentation(), window: NSWindow? = nil
    ) {
        let openedAt = Date.now
        self.model = model
        canvas = EditorCanvasView(model: model)
        let window = window ?? Self.makeWindow()
        let origin = model.document.layers.first.flatMap { model.document.assets[$0.assetID]?.origin }
        let time = Date.FormatStyle.dateTime.hour().minute()
        switch origin {
        case .captured(let geometry):
            window.title = String(localized: "Capture \(geometry.capturedAt.formatted(time))", table: "Editor")
        case .scrollCapture:
            window.title = String(localized: "Scrolling Capture \(openedAt.formatted(time))", table: "Editor")
        case .pasted:
            window.title = String(localized: "Pasted Image \(openedAt.formatted(time))", table: "Editor")
        case .imported, nil:
            if let importedFileName, !importedFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                window.title = importedFileName
            } else {
                window.title = String(localized: "Image \(openedAt.formatted(time))", table: "Editor")
            }
        }
        super.init(window: window)
        window.delegate = self
        canvas.actions = self
        window.contentViewController = Self.splitController(
            model: model, canvas: canvas, actions: self, panes: panes, noticePresentation: noticePresentation)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.initialFirstResponder = canvas
        let visible = targetScreen()?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = EditorWindowSizing.initialContentSize(
            remembered: model.environment.settings.preferences.editorContentSize,
            visibleFrame: Size(width: visible.width, height: visible.height))
        window.setContentSize(NSSize(width: size.width, height: size.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Object list, canvas column and inspector as split items. The columns are opaque
    /// (`.default` behaviour over the window background) rather than the glass sidebar material,
    /// which `cacheDisplay` screenshots cannot render (decisions 2026-11-20). The canvas column
    /// carries the SwiftUI `.toolbar`, which becomes this window's NSToolbar.
    private static func splitController(
        model: EditorModel, canvas: EditorCanvasView, actions: any EditorWindowActions, panes: EditorPanes,
        noticePresentation: EditorNoticePresentation
    ) -> EditorSplitViewController {
        let sidebar = NSHostingController(rootView: EditorSidebarView(model: model))
        let content = NSHostingController(
            rootView: EditorRootView(
                model: model, canvas: canvas, actions: actions, panes: panes, noticePresentation: noticePresentation))
        content.sceneBridgingOptions = [.toolbars]
        let inspector = NSHostingController(rootView: EditorInspectorView(model: model, actions: actions, panes: panes))
        // The split items own the column widths; the hosted views fill whatever they are given.
        sidebar.sizingOptions = []
        content.sizingOptions = []
        inspector.sizingOptions = []
        sidebar.view.frame.size.width = 210
        inspector.view.frame.size.width = 290

        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.holdingPriority = .defaultLow + 10
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 360
        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 380
        inspectorItem.holdingPriority = .defaultLow + 10
        let split = EditorSplitViewController(panes: panes)
        split.splitView.dividerStyle = .thin
        for item in [sidebarItem, contentItem, inspectorItem] { split.addSplitViewItem(item) }
        return split
    }

    /// Runs `body` once, after the canvas first draws the document's image.
    func whenFirstDrawn(_ body: @escaping () -> Void) {
        canvas.onFirstImageDraw = body
    }

    /// The split item that holds `pane`.
    func splitItem(_ pane: EditorPane) -> NSSplitViewItem? {
        let items = (window?.contentViewController as? NSSplitViewController)?.splitViewItems ?? []
        guard items.count == 3 else { return nil }
        return pane == .sidebar ? items[0] : items[2]
    }

    /// Collapses or restores a column (View menu). Keyboard focus inside a column that collapses
    /// returns to the canvas.
    func toggle(_ pane: EditorPane) {
        guard let window, let item = splitItem(pane) else { return }
        let collapse = !item.isCollapsed
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            item.isCollapsed = collapse
        } else {
            item.animator().isCollapsed = collapse
        }
        (window.contentViewController as? EditorSplitViewController)?.syncPanes()
        EditorCommands.shared.panesChanged(self)
        if collapse, let responder = window.firstResponder as? NSView,
            responder.isDescendant(of: item.viewController.view)
        {
            window.makeFirstResponder(canvas)
        }
    }

    /// View › Inspector › Format or Image: shows that tab, and the inspector if it is hidden.
    func showInspectorTab(_ tab: EditorInspectorTab) {
        panes.chosenInspectorTab = tab
        if splitItem(.inspector)?.isCollapsed == true { toggle(.inspector) }
    }

    /// Shows the window on the capture's display (or the one with the pointer) and focuses it once.
    func present() {
        guard let window else { return }
        let wasVisible = window.isVisible
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible, let visible = targetScreen()?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        AppPresence.shared.present(window)
        // SwiftUI attaches the canvas lazily. It must belong to this window before AppKit
        // can accept it as first responder, including on the first capture after launch.
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(canvas)
        // Cooperative activation is asynchronous and can be declined. A completed, explicit
        // capture must still show its result; normal-level ordering does not force activation.
        if !NSApp.isActive { window.orderFrontRegardless() }
        if !wasVisible {
            canvas.firstDrawInterval = LatencySignposts.begin(.editorToFirstDraw)
        }
    }

    private func targetScreen() -> NSScreen? {
        let assets = model.document.assets.values
        var displayID: CGDirectDisplayID?
        if assets.count == 1, case .captured(let geometry)? = assets.first?.origin {
            displayID =
                switch geometry.source {
                case .display(let id): id
                case .window(_, let id): id
                case .region(let id): id
                }
        }
        return ScreenChoice.screen(displayID: displayID)
    }

    /// Commits in-progress text first, so typed text counts as an edit.
    func hasUnexportedEdits() -> Bool {
        canvas.finishTextEditing(commit: true)
        return model.isDirty && !model.isClosed
    }

    // MARK: NSWindowDelegate

    /// What closing an edited editor discards. Only a copy or save keeps edits; a pin does not.
    static var discardOnCloseDetail: String {
        String(
            localized: "This image has changes that were not copied or saved. Closing discards them.", table: "Editor")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.finishTextEditing(commit: true)
        guard model.isDirty, !discardConfirmed else { return true }
        let alert = MessagePresenter.makeConfirmation(
            title: String(localized: "Discard your edits?", table: "Editor"), detail: Self.discardOnCloseDetail,
            action: String(localized: "Discard", table: "Editor"), cancel: String(localized: "Cancel", table: "Editor"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.discardConfirmed = true
            self.window?.close()
        }
        return false
    }

    /// A size the user dragged to becomes every new editor's size.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        let size = Size<DesktopSpace>(width: content.width, height: content.height)
        model.environment.settings.update { $0.editorContentSize = EditorWindowSizing.rememberable(size) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        EditorCommands.shared.editorBecameKey(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        EditorCommands.shared.editorResignedKey(self)
    }

    func windowWillClose(_ notification: Notification) {
        // A sheet still open or queued gets its answer: Replace and Save cancel, Discard does
        // nothing, and an unread failure becomes an app alert (`MessagePresenter.beginSheet`).
        if let window {
            for sheet in window.sheets { window.endSheet(sheet, returnCode: .abort) }
        }
        EditorCommands.shared.editorResignedKey(self)
        model.close()
        window?.contentViewController = nil
        onClosed?()
        onClosed = nil
    }

    // MARK: EditorWindowActions

    func copyImage() {
        commitPendingText()
        guard exportSlotIsFree() else { return }
        Task { await model.export(.copy) }
    }

    /// Another editor holds the shared export slot: beep and submit nothing, like a disabled
    /// toolbar button (R3-D04a). A Save sheet confirmed after the slot was taken is not reserved;
    /// its request gets the existing busy message and writes nothing.
    private func exportSlotIsFree() -> Bool {
        guard model.canStartExport else {
            NSSound.beep()
            return false
        }
        return true
    }

    func saveImage() {
        commitPendingText()
        guard let window, exportSlotIsFree() else { return }
        let options = model.environment.settings.preferences.exportOptions
        let format = options.formatChoice
        let panel = NSSavePanel()
        // Automatic offers the PNG name; the save then takes the extension of the format chosen.
        panel.allowedContentTypes =
            switch format {
            case .fixed(.png): [.png]
            case .fixed(.jpeg): [.jpeg]
            case .automatic: [.png, .jpeg]
            }
        panel.nameFieldStringValue = options.filenameTemplate.name(for: Date(), format: options.format).name(attempt: 1)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.saveImage(to: url, format: format) }
        }
    }

    /// Exclusive creation closes the save-panel race. A collision requires fresh, explicit consent
    /// for the file it names; a retry that resolves to another existing file asks about that one.
    @discardableResult
    func saveImage(
        to url: URL, format: ExportFormatChoice, confirmReplacement: ((_ existing: URL) async -> Bool)? = nil
    ) async -> ExportOutcome {
        var outcome = await model.export(.save(url, format: format, replacing: nil))
        var asked: Set<URL> = []
        while case .failed(.destinationExists(let existing?)) = outcome, asked.insert(existing).inserted {
            model.dismissNotice()
            let confirmed: Bool
            if let confirmReplacement {
                confirmed = await confirmReplacement(existing)
            } else {
                confirmed = await self.confirmReplacement(of: existing)
            }
            guard confirmed else { return .canceled }
            outcome = await model.export(.save(url, format: format, replacing: existing))
        }
        return outcome
    }

    private func confirmReplacement(of existing: URL) async -> Bool {
        guard let window else { return false }
        let alert = MessagePresenter.makeReplacement(of: existing)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    func saveToPreferredFolder() {
        commitPendingText()
        guard exportSlotIsFree() else { return }
        Task { await model.export(.saveToPreferredFolder) }
    }

    func pin() {
        commitPendingText()
        Task { await model.pin() }
    }

    func addImageFromFile() {
        commitPendingText()
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.model.addImageLayer(from: .file(url)) }
        }
    }

    func pasteImageLayer() {
        commitPendingText()
        Task { await model.addImageLayer(from: .pasteboard) }
    }

    func commitPendingText() {
        canvas.finishTextEditing(commit: true)
    }

    func dragOut() {
        commitPendingText()
        guard exportSlotIsFree() else { return }
        Task { await model.export(.drag) }
    }
}

/// Keeps `EditorPanes` in step with the columns when the person drags a divider closed or open.
final class EditorSplitViewController: NSSplitViewController {
    private let panes: EditorPanes

    init(panes: EditorPanes) {
        self.panes = panes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        syncPanes()
    }

    func syncPanes() {
        guard splitViewItems.count == 3 else { return }
        let sidebar = splitViewItems[0].isCollapsed
        let inspector = splitViewItems[2].isCollapsed
        guard panes.sidebarCollapsed != sidebar || panes.inspectorCollapsed != inspector else { return }
        panes.sidebarCollapsed = sidebar
        panes.inspectorCollapsed = inspector
        if let editor = view.window?.windowController as? EditorWindowController {
            EditorCommands.shared.panesChanged(editor)
        }
    }
}
