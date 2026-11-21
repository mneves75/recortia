import AppKit
import Domain
import Features
import SwiftUI
import UniformTypeIdentifiers

/// The quick-action thumbnail after a capture (B-1, ADR-009): a non-activating panel on every
/// Space (`SpacePolicy`), above the normal level so it never counts as a switchable window
/// (`AppPresence`). It shows the sanitizing renderer's preview, never stored pixels, and every
/// action goes through `QuickActionsModel` to the export pipeline or the pins model.
final class QuickActionsUIController {
    private let model: QuickActionsModel
    private(set) var panel: HostingPanel?
    private var shownID: UUID?
    private var loop: ObservationLoop?
    /// Orders the panel in; scenarios park it offscreen instead.
    var present: @MainActor (HostingPanel) -> Void = { $0.presentInCorner() }
    /// A destination for Save when Settings names no folder; scenarios never show a panel.
    var chooseSaveDestination: @MainActor () async -> (url: URL, format: ExportFormatChoice)?
    var confirmReplacement: @MainActor (_ existing: URL) async -> Bool = { MessagePresenter.confirmReplacement(of: $0) }

    init(model: QuickActionsModel, settings: SettingsStore) {
        self.model = model
        chooseSaveDestination = { Self.chooseDestination(options: settings.exportOptions) }
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let shown = model.isShown ? model.capture : nil
        guard shown?.id != shownID else { return }
        panel?.close()
        panel = nil
        shownID = shown?.id
        guard let shown else { return }
        let panel = Self.makePanel()
        // One owner of the size: fixed once from the content, which never changes size (a status
        // overlays the preview). Tracked sizing looped through constraint passes until AppKit threw.
        panel.setContent(QuickActionsView(capture: shown, model: model, actions: self), fixedToFittingSize: true)
        self.panel = panel
        present(panel)
    }

    static func makePanel() -> HostingPanel {
        let panel = HostingPanel(title: String(localized: "Quick Actions"), activating: false, keyOnClick: true)
        panel.reservesTitleBarArea = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.setAccessibilityLabel(String(localized: "Quick Actions"))
        return panel
    }

    // MARK: Actions (each returns the text to show when it did not complete)

    func copy() async -> String? { Self.failure(await model.copy()) }

    func save() async -> String? {
        Self.failure(await model.save(choosing: chooseSaveDestination, confirmReplacement: confirmReplacement))
    }

    func drag() async -> String? { Self.failure(await model.drag()) }

    func pin() async -> String? { (await model.pin()).map { EditorStrings.message(.pinFailed($0)) } }

    /// Copies the upload link as text; the thumbnail stays (it exports nothing of the capture).
    func copyLink() -> String? { model.copyLink() ? nil : String(localized: "Could not copy the link.") }

    func openInEditor() { model.openInEditor() }

    func dismiss() { model.dismiss() }

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
                button(String(localized: "Open in Editor"), "square.and.pencil", id: "edit", whileActing: true) {
                    actions.openInEditor()
                }
                button(String(localized: "Pin", table: "Editor"), "pin", id: "pin") { perform(actions.pin) }
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
        .background(QuickActionsHoverTracker { model.setPointerInside($0) })
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
