import AppKit
import Domain
import Features
import SwiftUI

/// The editor window's content: object list, canvas, inspector, and status bar. Its tools and
/// actions are bridged into the window's own toolbar (`EditorToolbarContent`).
struct EditorRootView: View {
    let model: EditorModel
    let canvas: EditorCanvasView
    let actions: any EditorWindowActions
    var noticePresentation = EditorNoticePresentation()

    var body: some View {
        VStack(spacing: 0) {
            if let reason = model.partialScrollCaptureReason {
                Label("Partial result. \(ScrollReviewView.describe(reason))", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .accessibilityElement(children: .combine)
                Divider()
            }
            HStack(spacing: 0) {
                EditorSidebarView(model: model)
                    .frame(width: 220)
                Divider()
                CanvasHost(canvas: canvas)
                    .frame(minWidth: 320, minHeight: 240)
                    .accessibilityElement(children: .contain)
                Divider()
                EditorInspectorView(model: model, actions: actions)
                    .frame(width: 290)
            }
            Divider()
            EditorStatusBar(model: model, presentation: noticePresentation)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar { EditorToolbarContent(model: model, actions: actions) }
    }
}

/// How an editor presents notices: how long a notice that needs no action stays, and how each
/// notice reaches VoiceOver. Injected per editor window; the E2E runner records announcements and
/// shortens the delay instead of changing shared state.
@MainActor
struct EditorNoticePresentation {
    var autoDismissDelay: Duration = .seconds(8)
    var announce: @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

    /// Failures, and notices that carry a link or ask the person to act, stay until dismissed.
    /// Only success and passive information dismisses itself.
    static func persists(_ notice: EditorNotice) -> Bool {
        switch notice {
        case .copyFailed, .recognitionFailed, .linkNotAllowed, .previewFailed, .redactionRefused, .importFailed,
            .pinFailed, .noPreferredFolder, .arrowGeometryRefused:
            true
        case .exported(let outcome): persists(outcome)
        case .noTextFound, .recognitionLanguagesUnavailable, .textCopied, .recognitionDiscarded,
            .recognitionInvalidated, .noQRCodeFound, .payloadCopied, .colorCopied, .previewNotReady, .pinned,
            .pinsInvalidated, .undoHistoryTrimmed:
            false
        }
    }

    private static func persists(_ outcome: ExportOutcome) -> Bool {
        switch outcome {
        case .failed, .uploaded: true
        case .alreadyCompleted(let completed): persists(completed)
        case .copied, .saved, .dragged, .canceled, .rejectedBusy: false
        }
    }
}

/// Hosts the AppKit canvas created by the window controller.
private struct CanvasHost: NSViewRepresentable {
    let canvas: EditorCanvasView

    func makeNSView(context: Context) -> EditorCanvasView { canvas }

    func updateNSView(_ nsView: EditorCanvasView, context: Context) {}
}

// MARK: - Tool bar

/// The window toolbar: tools on the leading edge, history and output on the trailing edge.
/// Separate groups give the visual grouping; nothing here needs more than macOS 15.
struct EditorToolbarContent: ToolbarContent {
    let model: EditorModel
    let actions: any EditorWindowActions

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            tools([.select, .hand, .crop])
        }
        ToolbarItemGroup(placement: .navigation) {
            tools([.text, .arrow, .line, .rectangle, .ellipse, .freehand, .highlighter, .step])
        }
        ToolbarItem(placement: .navigation) {
            ToolButton(tool: .redact, model: model, actions: actions)
        }
        ToolbarItem(placement: .navigation) {
            ToolMenu(group: .effects, model: model, actions: actions)
        }
        ToolbarItem(placement: .navigation) {
            ToolMenu(group: .measure, model: model, actions: actions)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.undo()
            } label: {
                Label(String(localized: "Undo", table: "Editor"), systemImage: "arrow.uturn.backward")
            }
            .help(String(localized: "Undo (⌘Z)", table: "Editor"))
            .disabled(!model.canUndo)
            .accessibilityIdentifier("toolbar.undo")
            Button {
                model.redo()
            } label: {
                Label(String(localized: "Redo", table: "Editor"), systemImage: "arrow.uturn.forward")
            }
            .help(String(localized: "Redo (⇧⌘Z)", table: "Editor"))
            .disabled(!model.canRedo)
            .accessibilityIdentifier("toolbar.redo")
        }
        // Keeps Copy out of the history group's capsule.
        ToolbarItem(placement: .primaryAction) {
            Spacer(minLength: 8)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ExportButtons(model: model, actions: actions)
        }
    }

    private func tools(_ tools: [EditorTool]) -> some View {
        ForEach(tools, id: \.self) { tool in
            ToolButton(tool: tool, model: model, actions: actions)
        }
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let model: EditorModel
    let actions: any EditorWindowActions

    var body: some View {
        let isSelected = model.tool == tool
        Toggle(
            isOn: Binding(
                get: { isSelected },
                set: { on in
                    guard on else { return }
                    select()
                })
        ) {
            Label(EditorStrings.name(tool), systemImage: EditorStrings.symbol(tool))
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(EditorStrings.help(tool))
        // In a bridged toolbar a Toggle reports its on/off state as its value, hiding the
        // "Selected tool" value; a button representation keeps the name, value and Press.
        .accessibilityRepresentation {
            Button(EditorStrings.name(tool)) { select() }
                .accessibilityValue(isSelected ? String(localized: "Selected tool", table: "Editor") : "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .accessibilityIdentifier("tool.\(tool.rawValue)")
    }

    private func select() {
        actions.commitPendingText()
        model.selectTool(tool)
    }
}

/// Tools that share one toolbar menu button.
private enum ToolMenuGroup {
    case effects, measure

    var tools: [EditorTool] {
        switch self {
        case .effects: [.blur, .pixelate, .spotlight, .magnifier]
        case .measure: [.loupe, .ruler, .colorPicker]
        }
    }

    var name: String {
        switch self {
        case .effects: String(localized: "Effects", table: "Editor")
        case .measure: String(localized: "Measure", table: "Editor")
        }
    }

    var symbol: String {
        switch self {
        case .effects: "camera.filters"
        case .measure: "level"
        }
    }

    var help: String {
        switch self {
        case .effects: String(localized: "Effects: blur, pixelate, spotlight and magnifier", table: "Editor")
        case .measure: String(localized: "Measure: loupe, ruler and color picker", table: "Editor")
        }
    }

    var identifier: String {
        switch self {
        case .effects: "toolMenu.effects"
        case .measure: "toolMenu.measure"
        }
    }
}

/// A menu of tools. While one of them is active the button shows that tool and reads as the
/// selected tool; otherwise it shows the group.
private struct ToolMenu: View {
    let group: ToolMenuGroup
    let model: EditorModel
    let actions: any EditorWindowActions

    var body: some View {
        let active = group.tools.first { $0 == model.tool }
        Menu {
            ForEach(group.tools, id: \.self) { tool in
                Toggle(
                    isOn: Binding(
                        get: { model.tool == tool },
                        set: { on in
                            guard on else { return }
                            actions.commitPendingText()
                            model.selectTool(tool)
                        })
                ) {
                    Label(EditorStrings.name(tool), systemImage: EditorStrings.symbol(tool))
                }
            }
        } label: {
            // A bridged toolbar menu exposes its Label text as its accessible name, so the text
            // names the group and, while one of its tools is active, that tool.
            Label {
                Text(active.map { "\(group.name), \(EditorStrings.name($0))" } ?? group.name)
            } icon: {
                Image(systemName: active.map(EditorStrings.symbol) ?? group.symbol)
                    .foregroundStyle(active == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            }
        }
        .help(group.help)
        .accessibilityValue(active == nil ? "" : String(localized: "Selected tool", table: "Editor"))
        .accessibilityIdentifier(group.identifier)
    }
}

private struct ExportButtons: View {
    let model: EditorModel
    let actions: any EditorWindowActions

    var body: some View {
        Button {
            actions.copyImage()
        } label: {
            Label(String(localized: "Copy", table: "Editor"), systemImage: "doc.on.doc")
        }
        .help(String(localized: "Copy the image as PNG (⌘C)", table: "Editor"))
        .disabled(model.isExporting)
        .accessibilityIdentifier("toolbar.copy")
        Menu {
            Button(String(localized: "Save…", table: "Editor")) { actions.saveImage() }
            Button(String(localized: "Save to Preferred Folder", table: "Editor")) {
                actions.saveToPreferredFolder()
            }
        } label: {
            Label(String(localized: "Save", table: "Editor"), systemImage: "square.and.arrow.down")
        } primaryAction: {
            actions.saveImage()
        }
        .help(String(localized: "Save the image (⌘S)", table: "Editor"))
        .disabled(model.isExporting)
        .accessibilityIdentifier("toolbar.save")
        Button {
            actions.pin()
        } label: {
            Label(String(localized: "Pin", table: "Editor"), systemImage: "pin")
        }
        .help(String(localized: "Pin the image in a floating window", table: "Editor"))
        .disabled(model.isExporting)
        .accessibilityIdentifier("toolbar.pin")
        Button {
            actions.dragOut()
        } label: {
            Label(String(localized: "Drag Out", table: "Editor"), systemImage: "hand.draw")
        }
        .help(String(localized: "Prepare the image for dragging into another app", table: "Editor"))
        .disabled(model.isExporting)
        .accessibilityIdentifier("toolbar.dragOut")
    }
}

// MARK: - Status bar

struct EditorStatusBar: View {
    let model: EditorModel
    var presentation = EditorNoticePresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(EditorFormat.size(model.document.canvasSize))
                .monospacedDigit()
                .help(String(localized: "Canvas size in document pixels", table: "Editor"))
            Divider().frame(height: 14)
            ZoomMenu(model: model)
            if model.baseImage == nil {
                Text(String(localized: "Rendering preview…", table: "Editor"))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let notice = model.notice {
                Label {
                    Text(EditorStrings.message(notice))
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }
                .transition(reduceMotion ? .identity : .opacity)
                if EditorNoticePresentation.persists(notice) {
                    Button(String(localized: "Dismiss", table: "Editor")) { model.dismissNotice() }
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Dismiss notice", table: "Editor"))
                }
            }
            if model.isExporting {
                ProgressView().controlSize(.small)
                Button(String(localized: "Cancel Export", table: "Editor")) { model.cancelExport() }
                    .controlSize(.small)
            }
            if case .exported(let outcome) = model.notice, let url = outcome.uploadedURL {
                Link("View on GitHub", destination: url).controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .animation(reduceMotion ? nil : .default, value: model.noticeSerial)
        .task(id: model.noticeSerial) {
            guard let notice = model.notice else { return }
            // Status text is silent for VoiceOver unless it is posted, and a timeout must not
            // remove it before a person who needs more time has read it.
            presentation.announce(EditorStrings.message(notice))
            guard !EditorNoticePresentation.persists(notice) else { return }
            do {
                try await Task.sleep(for: presentation.autoDismissDelay)
            } catch {
                return
            }
            model.dismissNotice()
        }
    }
}

private struct ZoomMenu: View {
    let model: EditorModel

    var body: some View {
        Menu {
            Button(String(localized: "Zoom to Fit (⌘0)", table: "Editor")) { model.zoomToFit() }
            Button(String(localized: "Actual Pixels (⌘1)", table: "Editor")) { model.zoomToActualPixels() }
            Button(String(localized: "Zoom In (⌘+)", table: "Editor")) { model.zoomIn() }
            Button(String(localized: "Zoom Out (⌘−)", table: "Editor")) { model.zoomOut() }
            Button(String(localized: "Zoom to Selection", table: "Editor")) { model.zoomToSelection() }
                .disabled(model.selection.isEmpty)
            Divider()
            ForEach([25.0, 50, 100, 200, 400, 800], id: \.self) { percent in
                Button(EditorFormat.percent(percent)) {
                    model.setZoom(percent / 100 / max(model.backingScale, 0.5))
                }
            }
        } label: {
            Text(EditorFormat.percent(model.zoomPercent)).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Zoom. Actual Pixels shows one image pixel per screen pixel.", table: "Editor"))
        .accessibilityLabel(String(localized: "Zoom", table: "Editor"))
        .accessibilityValue(EditorFormat.percent(model.zoomPercent))
    }
}
