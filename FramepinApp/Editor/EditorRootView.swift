import AppKit
import Domain
import Features
import SwiftUI

/// The editor window's content: tool bar, object list, canvas, inspector, and status bar.
struct EditorRootView: View {
    let model: EditorModel
    let canvas: EditorCanvasView
    let actions: any EditorWindowActions

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbarView(model: model, actions: actions)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
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
            EditorStatusBar(model: model)
                .background(Color(nsColor: .windowBackgroundColor))
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

struct EditorToolbarView: View {
    let model: EditorModel
    let actions: any EditorWindowActions

    static let groups: [[EditorTool]] = [
        [.select, .hand, .crop],
        [.text, .arrow, .rectangle, .ellipse, .freehand, .highlighter, .step],
        [.redact],
        [.blur, .pixelate],
        [.spotlight, .magnifier],
        [.loupe, .ruler, .colorPicker],
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider().frame(height: 20) }
                HStack(spacing: 2) {
                    ForEach(group, id: \.self) { tool in
                        ToolButton(tool: tool, model: model, actions: actions)
                    }
                }
            }
            Spacer(minLength: 12)
            Button {
                model.undo()
            } label: {
                Label(String(localized: "Undo", table: "Editor"), systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Undo (⌘Z)", table: "Editor"))
            .disabled(!model.canUndo)
            Button {
                model.redo()
            } label: {
                Label(String(localized: "Redo", table: "Editor"), systemImage: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Redo (⇧⌘Z)", table: "Editor"))
            .disabled(!model.canRedo)
            Divider().frame(height: 20)
            // Titles when they fit; icons with tooltips and accessible names otherwise.
            ViewThatFits(in: .horizontal) {
                ExportButtons(model: model, actions: actions)
                ExportButtons(model: model, actions: actions).labelStyle(.iconOnly)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
                    actions.commitPendingText()
                    model.selectTool(tool)
                })
        ) {
            Label(EditorStrings.name(tool), systemImage: EditorStrings.symbol(tool))
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(EditorStrings.help(tool))
        .accessibilityLabel(EditorStrings.name(tool))
        .accessibilityValue(
            isSelected
                ? String(localized: "Selected tool", table: "Editor") : "")
    }
}

private struct ExportButtons: View {
    let model: EditorModel
    let actions: any EditorWindowActions

    var body: some View {
        HStack(spacing: 6) {
            Button {
                actions.copyImage()
            } label: {
                Label(String(localized: "Copy", table: "Editor"), systemImage: "doc.on.doc")
            }
            .help(String(localized: "Copy the image as PNG (⌘C)", table: "Editor"))
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
            .menuStyle(.button)
            .fixedSize()
            .help(String(localized: "Save the image (⌘S)", table: "Editor"))
            Button {
                actions.pin()
            } label: {
                Label(String(localized: "Pin", table: "Editor"), systemImage: "pin")
            }
            .help(String(localized: "Pin the image in a floating window", table: "Editor"))
            Button {
                actions.dragOut()
            } label: {
                Label(String(localized: "Drag Out", table: "Editor"), systemImage: "hand.draw")
            }
            .help(String(localized: "Prepare the image for dragging into another app", table: "Editor"))
        }
        .disabled(model.isExporting)
    }
}

// MARK: - Status bar

struct EditorStatusBar: View {
    let model: EditorModel
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
                .accessibilityAddTraits(.updatesFrequently)
                .transition(reduceMotion ? .identity : .opacity)
            }
            if model.isExporting {
                ProgressView().controlSize(.small)
                Button(String(localized: "Cancel Export", table: "Editor")) { model.cancelExport() }
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .animation(reduceMotion ? nil : .default, value: model.noticeSerial)
        .task(id: model.noticeSerial) {
            guard model.notice != nil else { return }
            do {
                try await Task.sleep(for: .seconds(8))
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
