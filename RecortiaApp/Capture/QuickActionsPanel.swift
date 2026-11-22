import AppKit
import Domain
import Features
import SwiftUI
import UniformTypeIdentifiers

/// The quick-action thumbnail after a capture (B-1, ADR-009): a non-activating panel on every
/// Space (`SpacePolicy`), above the normal level so it never counts as a switchable window
/// (`AppPresence`). It shows the sanitizing renderer's preview, never stored pixels, and every
/// action goes through `QuickActionsModel` to the export pipeline or the pins model.
final class QuickActionsUIController: NSObject, NSWindowDelegate {
    private let model: QuickActionsModel
    private(set) var panel: HostingPanel?
    private(set) var previewPanel: HostingPanel?
    private var shownID: UUID?
    private var captureSuspended = false
    private var loop: ObservationLoop?
    /// Orders the panel in; scenarios park it offscreen instead.
    var present: @MainActor (HostingPanel) -> Void = { $0.presentInCorner() }
    /// A destination for Save when Settings names no folder; scenarios never show a panel.
    var chooseSaveDestination: @MainActor () async -> (url: URL, format: ExportFormatChoice)?
    var confirmReplacement: @MainActor (_ existing: URL) async -> Bool = { MessagePresenter.confirmReplacement(of: $0) }
    /// Lets the synthetic scenario supply destinations without opening actual save panels.
    var optimizedSaveDialogs:
        (
            chooseDestination: @MainActor (OptimizedSaveDetails) async -> URL?,
            confirmReplacement: @MainActor (URL) async -> Bool
        )?

    init(model: QuickActionsModel, settings: SettingsStore) {
        self.model = model
        chooseSaveDestination = { Self.chooseDestination(options: settings.exportOptions) }
        super.init()
        loop = ObservationLoop { [weak self] in
            self?.renderThumbnail()
            self?.renderPreview()
        }
    }

    private func renderThumbnail() {
        let shown = model.isShown ? model.capture : nil
        guard shown?.id != shownID else { return }
        closePreviewPanel()
        panel?.close()
        panel = nil
        shownID = nil
        guard !captureSuspended, let shown else { return }
        shownID = shown.id
        let panel = Self.makePanel()
        panel.handleEscape = { [weak self] in self?.model.closePreview() == true }
        // One owner of the size: fixed once from the content, which never changes size (a status
        // overlays the preview). Tracked sizing looped through constraint passes until AppKit threw.
        panel.setContent(QuickActionsView(capture: shown, model: model, actions: self), fixedToFittingSize: true)
        self.panel = panel
        present(panel)
    }

    static func makePanel(title: String = String(localized: "Quick Actions")) -> HostingPanel {
        let panel = HostingPanel(title: title, activating: false, keyOnClick: true)
        panel.reservesTitleBarArea = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.setAccessibilityLabel(title)
        return panel
    }

    private func renderPreview() {
        guard let image = model.expandedPreview else {
            closePreviewPanel()
            return
        }
        guard previewPanel == nil, !captureSuspended, panel?.isVisible == true,
            let screen = panel?.screen ?? ScreenChoice.screen()
        else { return }
        let bounds = screen.visibleFrame.insetBy(dx: DesignTokens.Space.m, dy: DesignTokens.Space.m)
        let panel = Self.makePanel(title: String(localized: "Capture Preview"))
        panel.handleEscape = { [weak self] in self?.model.closePreview() == true }
        panel.delegate = self
        panel.setContent(
            QuickActionsPreviewView(
                image: image, bounds: bounds.size, backingScale: screen.backingScaleFactor, actions: self),
            fixedToFittingSize: true)
        panel.center(on: screen)
        previewPanel = panel
        panel.orderFrontRegardless()
    }

    private func closePreviewPanel() {
        previewPanel?.close()
        previewPanel = nil
    }

    func captureVisibilityChanged(suspended: Bool) {
        captureSuspended = suspended
        if suspended {
            model.suspendPreview(keepingVisiblePreview: previewPanel?.isVisible == true)
        } else {
            renderThumbnail()
            // Back ordering restores the existing panels without their former keyboard focus.
            let pointer = NSEvent.mouseLocation
            model.setPointerInside(panel?.isVisible == true && panel?.frame.contains(pointer) == true)
            model.setPointerInsidePreview(
                previewPanel?.isVisible == true && previewPanel?.frame.contains(pointer) == true)
        }
    }

    func hoverThumbnail(_ inside: Bool, for captureID: UUID) {
        guard !captureSuspended, model.capture?.id == captureID else { return }
        model.setPointerInside(inside)
    }

    func hoverPreview(_ inside: Bool) {
        guard !captureSuspended else { return }
        model.setPointerInsidePreview(inside)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !captureSuspended, notification.object as? NSWindow === previewPanel else { return }
        model.setPreviewKey(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === previewPanel else { return }
        model.setPreviewKey(false)
    }

    // MARK: Actions (each returns the text to show when it did not complete)

    func openPreview() async -> String? {
        guard !captureSuspended, panel?.isVisible == true else { return nil }
        do {
            try await model.openPreview()
            return nil
        } catch {
            return EditorStrings.message(.previewFailed)
        }
    }

    func closePreview() { model.closePreview() }

    func copy() async -> String? { Self.failure(await model.copy()) }

    func save() async -> String? {
        Self.failure(await model.save(choosing: chooseSaveDestination, confirmReplacement: confirmReplacement))
    }

    func saveOptimized() async -> String? {
        guard let panel, let captureID = shownID, canPresentOptimizedSave(captureID, from: panel) else { return nil }
        let choose = optimizedSaveDialogs?.chooseDestination ?? Self.chooseOptimizedDestination
        let confirm =
            optimizedSaveDialogs?.confirmReplacement ?? { await Self.confirmOptimizedReplacement($0, in: panel) }
        let dialogs = OptimizedSaveDialogs(
            chooseDestination: { [weak self] details in
                guard self?.canPresentOptimizedSave(captureID, from: panel) == true else { return nil }
                return await choose(details)
            },
            confirmReplacement: { [weak self] url in
                guard self?.canPresentOptimizedSave(captureID, from: panel) == true else { return false }
                return await confirm(url)
            })
        return Self.failure(await model.saveOptimized(using: dialogs))
    }

    private func canPresentOptimizedSave(_ captureID: UUID, from panel: HostingPanel) -> Bool {
        !Task.isCancelled && !captureSuspended && self.panel === panel && panel.isVisible
            && model.isShown && model.capture?.id == captureID
    }

    func drag() async -> String? { Self.failure(await model.drag()) }

    func pin() async -> String? { (await model.pin()).map { EditorStrings.message(.pinFailed($0)) } }

    /// Copies the upload link as text; the thumbnail stays (it exports nothing of the capture).
    func copyLink() -> String? { model.copyLink() ? nil : String(localized: "Could not copy the link.") }

    func openInEditor() { model.openInEditor() }

    func dismiss() {
        model.dismiss()
        renderThumbnail()
    }

    private static func failure(_ outcome: ExportOutcome) -> String? {
        switch outcome {
        case .failed, .rejectedBusy: EditorStrings.exportMessage(outcome)
        default: nil
        }
    }

    /// The editor's Save panel, app-modal because the thumbnail has no window to attach a sheet to.
    private static func chooseDestination(options: ExportOptions) -> (url: URL, format: ExportFormatChoice)? {
        let format = options.formatChoice
        let panel = NSSavePanel()
        // Automatic offers the PNG name; the save then takes the extension of the format chosen.
        panel.allowedContentTypes =
            switch format {
            case .fixed(.png): [.png]
            case .fixed(.jpeg): [.jpeg]
            case .fixed(.heic): [.heic]
            case .automatic: [.png, .jpeg]
            }
        panel.nameFieldStringValue = options.filenameTemplate.name(for: Date(), format: options.format).name(attempt: 1)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        AppPresence.shared.activate()
        // A finished save panel is ordered out, not closed: re-evaluate the Dock presence.
        defer { AppPresence.shared.setNeedsRefresh() }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, format)
    }

    private static func chooseOptimizedDestination(_ details: OptimizedSaveDetails) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let panel = NSSavePanel()
        let type: (String, UTType) =
            switch details.format {
            case .png: ("PNG", .png)
            case .jpeg: ("JPEG", .jpeg)
            case .heic: ("HEIC", .heic)
            }
        panel.title = String(localized: "Save Optimized Copy…")
        panel.message = String(
            localized:
                "\(type.0) · \(details.pixelSize.width) × \(details.pixelSize.height) px · \(details.byteCount) bytes")
        panel.allowedContentTypes = [type.1]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = details.suggestedFilename
        panel.directoryURL = details.preferredFolder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        SpacePolicy.follow(panel)
        AppPresence.shared.activate()
        defer {
            panel.orderOut(nil)
            AppPresence.shared.setNeedsRefresh()
        }
        let response = await OptimizedSavePrompt().run(
            begin: { panel.begin(completionHandler: $0) }, dismiss: { panel.cancel(nil) })
        return response == .OK ? panel.url : nil
    }

    private static func confirmOptimizedReplacement(_ existing: URL, in parent: NSWindow) async -> Bool {
        guard parent.isVisible, parent.attachedSheet == nil else { return false }
        let alert = MessagePresenter.makeReplacement(of: existing)
        let response = await OptimizedSavePrompt().run(
            begin: { alert.beginSheetModal(for: parent, completionHandler: $0) },
            dismiss: {
                if alert.window.sheetParent === parent { parent.endSheet(alert.window, returnCode: .abort) }
            })
        return response == .alertFirstButtonReturn
    }
}

@MainActor
private final class OptimizedSavePrompt {
    private var completion: CheckedContinuation<NSApplication.ModalResponse, Never>?

    func run(
        begin: (@escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) async -> NSApplication.ModalResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .abort)
                    return
                }
                completion = continuation
                begin { [weak self] in self?.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.completion != nil else { return }
                dismiss()
                self.finish(.abort)
            }
        }
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        let continuation = completion
        completion = nil
        continuation?.resume(returning: response)
    }
}

extension HostingPanel {
    /// The lower-right corner of the screen with the pointer, without activating Recortia.
    func presentInCorner() {
        sizeToContentIfUnsized()
        if let visible = ScreenChoice.screen()?.visibleFrame {
            let inset = DesignTokens.Space.l
            setFrameOrigin(CGPoint(x: visible.maxX - frame.width - inset, y: visible.minY + inset))
        }
        orderFrontRegardless()
    }
}

struct QuickActionsView: View {
    let capture: QuickCapture
    let model: QuickActionsModel
    let actions: QuickActionsUIController
    /// The last action that did not complete, in the editor's words; cleared by the next action.
    @State private var status: String?

    static let maxThumbnail = CGSize(width: 240, height: 160)

    private var thumbnailSize: CGSize {
        guard let preview = capture.preview, preview.width > 0, preview.height > 0 else { return Self.maxThumbnail }
        let scale = min(
            Self.maxThumbnail.width / Double(preview.width), Self.maxThumbnail.height / Double(preview.height))
        return CGSize(width: Double(preview.width) * scale, height: Double(preview.height) * scale)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Space.s) {
            QuickActionsThumbnail(preview: capture.preview) { perform(actions.drag) }
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .overlay(alignment: .bottom) {
                    if let status {
                        Text(status)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .noticeStyle()
                            .padding(DesignTokens.Space.xs)
                            .accessibilityIdentifier("quickActions.status")
                    }
                }
            HStack(spacing: DesignTokens.Space.s) {
                button(String(localized: "Copy", table: "Editor"), "doc.on.doc", id: "copy") { perform(actions.copy) }
                    .keyboardShortcut("c")
                button(String(localized: "Save", table: "Editor"), "square.and.arrow.down", id: "save") {
                    perform(actions.save)
                }
                .keyboardShortcut("s")
                button(String(localized: "Save Optimized Copy…"), "arrow.down.to.line", id: "saveOptimized") {
                    perform(actions.saveOptimized)
                }
                button(String(localized: "Open in Editor"), "square.and.pencil", id: "edit", whileActing: true) {
                    actions.openInEditor()
                }
                button(String(localized: "Pin", table: "Editor"), "pin", id: "pin") { perform(actions.pin) }
                button(String(localized: "Preview"), "eye", id: "preview") {
                    perform(actions.openPreview)
                }
                .disabled(!model.canOpenPreview)
                // Only when this capture's own automatic upload returned a link.
                if capture.uploadedURL != nil {
                    button(String(localized: "Copy Link"), "link", id: "copyLink", whileActing: true) {
                        perform(actions.copyLink)
                    }
                }
                Divider().frame(height: 16)
                button(String(localized: "Dismiss", table: "Editor"), "xmark", id: "dismiss", whileActing: true) {
                    actions.dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(DesignTokens.Space.m)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(QuickActionsHoverTracker { actions.hoverThumbnail($0, for: capture.id) })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickActions")
    }

    private func button(
        _ title: String, _ symbol: String, id: String, whileActing: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .labelStyle(.iconOnly)
        .help(Text(title))
        .disabled(model.isActing && !whileActing)
        .accessibilityIdentifier("quickActions.\(id)")
    }

    private func perform(_ action: @escaping @MainActor () async -> String?) {
        status = nil
        Task {
            let text = await action()
            // A completed action closes the thumbnail; a failure stays until the next action.
            if let text {
                status = text
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }
}

private struct QuickActionsPreviewView: View {
    let image: CGImage
    let bounds: CGSize
    let backingScale: CGFloat
    let actions: QuickActionsUIController
    private let controlsHeight: CGFloat = 28

    private var imageSize: CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let horizontal = DesignTokens.Space.m * 2
        let vertical = horizontal + DesignTokens.Space.s + controlsHeight
        let thumbnail = QuickActionsView.maxThumbnail
        let inspectionScale = 2 * min(thumbnail.width / width, thumbnail.height / height)
        let preferredScale = max(1 / backingScale, inspectionScale)
        let scale = min(preferredScale, (bounds.width - horizontal) / width, (bounds.height - vertical) / height)
        return CGSize(width: width * scale, height: height * scale)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Space.s) {
            QuickActionsExpandedImage(image: image, displaySize: imageSize)
            Button(String(localized: "Close", table: "Editor"), action: actions.closePreview)
                .controlSize(.small)
                .frame(height: controlsHeight)
                .accessibilityIdentifier("quickActions.closePreview")
        }
        .padding(DesignTokens.Space.m)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(QuickActionsHoverTracker(onChange: actions.hoverPreview))
    }
}

private struct QuickActionsExpandedImage: NSViewRepresentable {
    let image: CGImage
    let displaySize: CGSize

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        displaySize
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.setAccessibilityLabel(String(localized: "Capture Preview"))
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = NSImage(cgImage: image, size: displaySize)
    }
}

/// The preview, which is user content: an AppKit view, so a drag that starts on it can begin the
/// export, and the appearance checks can mask it out.
struct QuickActionsThumbnail: NSViewRepresentable {
    let preview: CGImage?
    let onDrag: @MainActor () -> Void

    func makeNSView(context: Context) -> QuickActionsThumbnailView {
        let view = QuickActionsThumbnailView()
        view.onDrag = onDrag
        view.image =
            preview.map { NSImage(cgImage: $0, size: .zero) }
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        return view
    }

    func updateNSView(_ view: QuickActionsThumbnailView, context: Context) {
        view.onDrag = onDrag
    }
}

/// Dragging the preview starts the drag-out export: the sanitized snapshot is then offered on the
/// drag chip at the pointer (ADR-004), as the editor's Drag Out does.
final class QuickActionsThumbnailView: NSImageView {
    var onDrag: @MainActor () -> Void = {}
    private var dragStarted = false

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Captured image. Drag it to export."))
        setAccessibilityIdentifier("quickActions.thumbnail")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    /// SwiftUI gives the preview its size; the image's own size must not feed back into layout.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        dragStarted = true
        onDrag()
    }
}

/// Reports the pointer over the whole thumbnail even while Recortia is not the active app, which
/// it usually is not after a capture.
struct QuickActionsHoverTracker: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: HoverTrackingView, context: Context) {
        view.onChange = onChange
    }

    final class HoverTrackingView: NSView {
        var onChange: @MainActor (Bool) -> Void = { _ in }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }

        override func mouseExited(with event: NSEvent) { onChange(false) }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
