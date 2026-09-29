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
}

/// Opens one editor window per document (FR-04). The composition root calls
/// `open(_:environment:)` for every new document; closing a window releases its model and the
/// asset pixels it held.
final class EditorWindowManager {
    private var controllers: [DocumentID: EditorWindowController] = [:]

    init() {}

    /// Opens `session` in a new window, or brings its existing window forward.
    @discardableResult
    func open(
        _ session: DocumentSession, environment: EditorEnvironment, initialAction: EditorInitialAction = .none
    ) -> EditorModel {
        let id = session.document.id
        if let existing = controllers[id] {
            existing.present()
            return existing.model
        }
        let model = EditorModel(session: session, environment: environment)
        let controller = EditorWindowController(model: model)
        controller.onClosed = { [weak self] in self?.controllers[id] = nil }
        controllers[id] = controller
        controller.present()
        if initialAction == .recognizeText {
            Task { await model.recognizeText() }
        }
        return model
    }

    var openDocumentIDs: [DocumentID] { Array(controllers.keys) }

    func model(for id: DocumentID) -> EditorModel? { controllers[id]?.model }
}

/// One editor window: hosts the SwiftUI chrome around the AppKit canvas, asks before discarding
/// unexported edits, and closes the model when the window closes.
final class EditorWindowController: NSWindowController, NSWindowDelegate, EditorWindowActions {
    let model: EditorModel
    var onClosed: (() -> Void)?
    private let canvas: EditorCanvasView
    private var discardConfirmed = false

    init(model: EditorModel) {
        self.model = model
        canvas = EditorCanvasView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = String(localized: "Recortia Editor", table: "Editor")
        // Follows the active Space instead of pulling the user back to another one (FR-01).
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.contentMinSize = NSSize(width: 980, height: 560)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        canvas.actions = self
        let root = EditorRootView(model: model, canvas: canvas, actions: self)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(Self.initialContentSize(for: model.document, on: targetScreen()))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows the window on the capture's display (or the one with the pointer) and focuses it once.
    func present() {
        guard let window else { return }
        if !window.isVisible, let visible = targetScreen()?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    private func targetScreen() -> NSScreen? {
        let assets = model.document.assets.values
        if assets.count == 1, case .captured(let geometry)? = assets.first?.origin {
            let displayID: UInt32 =
                switch geometry.source {
                case .display(let id): id
                case .window(_, let id): id
                case .region(let id): id
                }
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
            }) {
                return screen
            }
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    /// Room for the image at its captured point size plus the side panels, within the screen.
    private static func initialContentSize(for document: Domain.Document, on screen: NSScreen?) -> NSSize {
        let screenScale = Double(screen?.backingScaleFactor ?? 2)
        let captureScale: Double? = document.assets.values.first.flatMap(\.pointPixelScale)
        let scale = captureScale ?? screenScale
        let chromeWidth = 200.0 + 290.0 + 48, chromeHeight = 48.0 + 30 + 48
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(max(document.canvasSize.width / scale + chromeWidth, 980), visible.width * 0.92)
        let height = min(max(document.canvasSize.height / scale + chromeHeight, 560), visible.height * 0.92)
        return NSSize(width: width, height: height)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.finishTextEditing(commit: true)
        guard model.isDirty, !discardConfirmed else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Discard your edits?", table: "Editor")
        alert.informativeText = String(
            localized: "This image has changes that were not copied, saved, dragged, or pinned. Closing discards them.",
            table: "Editor")
        let discard = alert.addButton(withTitle: String(localized: "Discard", table: "Editor"))
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel", table: "Editor"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.discardConfirmed = true
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        window?.contentViewController = nil
        onClosed?()
        onClosed = nil
    }

    // MARK: EditorWindowActions

    func copyImage() {
        commitPendingText()
        Task { await model.export(.copy) }
    }

    func saveImage() {
        commitPendingText()
        guard let window else { return }
        let format = model.environment.export.exportOptions(for: .saveToFolder(FileManager.default.temporaryDirectory))
            .format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? UTType.png : UTType.jpeg]
        panel.nameFieldStringValue = ExportFilename.make(for: Date(), format: format)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.saveImage(to: url) }
        }
    }

    /// Exclusive creation closes the save-panel race. A collision requires fresh, explicit consent.
    @discardableResult
    func saveImage(to url: URL, confirmReplacement: (() async -> Bool)? = nil) async -> ExportOutcome {
        let outcome = await model.export(.save(url, overwriteConfirmed: false))
        guard outcome == .failed(.destinationExists) else { return outcome }
        model.dismissNotice()
        let confirmed: Bool
        if let confirmReplacement {
            confirmed = await confirmReplacement()
        } else {
            confirmed = await self.confirmReplacement()
        }
        guard confirmed else { return .canceled }
        return await model.export(.save(url, overwriteConfirmed: true))
    }

    private func confirmReplacement() async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Replace Existing File?", table: "Editor")
        alert.informativeText = String(localized: "A file exists at this destination. Replace it?", table: "Editor")
        alert.addButton(withTitle: String(localized: "Replace", table: "Editor")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel", table: "Editor"))
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    func saveToPreferredFolder() {
        commitPendingText()
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
        Task { await model.export(.drag) }
    }
}
