import CoreGraphics
import Domain
import Features
import Imaging
import SwiftUI

/// The inspector: keyboard-editable geometry for the selection, style, the redaction choices
/// with their security status in words, pixel tools, text/QR recognition, document, composition,
/// and presentation controls.
struct EditorInspectorView: View {
    let model: EditorModel
    let actions: any EditorWindowActions
    @State private var coalescer = ChangeCoalescer()

    var body: some View {
        Form {
            if !model.selection.isEmpty {
                SelectionSection(model: model, coalescer: coalescer)
            }
            if model.tool.usesStyle
                || model.selection.contains(where: { if case .annotation = $0 { true } else { false } })
            {
                StyleSection(model: model, coalescer: coalescer)
            }
            RedactionSection(model: model, actions: actions, coalescer: coalescer)
            if [.loupe, .colorPicker, .ruler].contains(model.tool) {
                PixelToolsSection(model: model)
            }
            RecognitionSection(model: model)
            DocumentSection(model: model)
            CompositionSection(model: model, actions: actions)
            PresentationSection(model: model, coalescer: coalescer)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Helpers

/// Groups rapid changes (color panel drags) into one undo step: the group ends after a pause.
final class ChangeCoalescer {
    private var pending: Task<Void, Never>?

    func run(_ model: EditorModel, _ apply: () -> Void) {
        let changeID = model.beginContinuousChange()
        apply()
        pending?.cancel()
        pending = Task { [weak model] in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            model?.endContinuousChange(changeID)
        }
    }
}

private func colorBinding(
    _ get: @escaping @MainActor @Sendable () -> RGBA, _ set: @escaping @MainActor @Sendable (RGBA) -> Void
) -> Binding<CGColor> {
    Binding(get: { get().cgColor }, set: { if let color = RGBA(cgColor: $0) { set(color) } })
}

/// A row of buttons that wraps into a column when the localized titles do not fit.
private struct ButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { content }
            VStack(alignment: .leading) { content }
        }
    }
}

/// A slider whose drag is one undo step.
private struct UndoableSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let model: EditorModel
    var format: (Double) -> String = { EditorFormat.number($0) }
    let onChange: @MainActor @Sendable (Double) -> Void
    @State private var changeID: UUID?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(
                    value: Binding(get: { value }, set: onChange), in: range,
                    onEditingChanged: { editing in
                        if editing {
                            model.endContinuousChange()
                            changeID = model.beginContinuousChange()
                        } else if let changeID {
                            model.endContinuousChange(changeID)
                            self.changeID = nil
                        }
                    }
                ) {
                    Text(title)
                }
                .labelsHidden()
                Text(format(value))
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(format(value))
    }
}

/// X, Y, width, and height fields, committed on Return.
private struct FrameFields: View {
    let frame: Rect<DocumentSpace>
    var preservesAspectRatio = false
    let onCommit: (Rect<DocumentSpace>) -> Void
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var width = 0.0
    @State private var height = 0.0

    var body: some View {
        Group {
            field(String(localized: "X", table: "Editor"), $x)
            field(String(localized: "Y", table: "Editor"), $y)
            field(String(localized: "Width", table: "Editor"), $width)
            field(String(localized: "Height", table: "Editor"), $height)
        }
        .onAppear(perform: load)
        .onChange(of: frame) { load() }
    }

    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .monospacedDigit()
            .onSubmit(commit)
            .help(String(localized: "Document pixels. Press Return to apply.", table: "Editor"))
    }

    private func load() {
        x = frame.minX
        y = frame.minY
        width = frame.width
        height = frame.height
    }

    private func commit() {
        var committedWidth = width
        var committedHeight = height
        if preservesAspectRatio, frame.width > 0, frame.height > 0 {
            if height != frame.height, width == frame.width {
                committedWidth = height * frame.width / frame.height
            } else {
                committedHeight = width * frame.height / frame.width
            }
        }
        onCommit(Rect(x: x, y: y, width: committedWidth, height: committedHeight))
        load()
    }
}

// MARK: - Selection

private struct SelectionSection: View {
    let model: EditorModel
    let coalescer: ChangeCoalescer

    var body: some View {
        Section {
            if model.selection.count == 1, let id = model.selection.first,
                let item = model.listItems.first(where: { $0.id == id })
            {
                FrameFields(frame: item.frame, preservesAspectRatio: item.kind == .image) {
                    model.setFrame($0, for: id)
                }
                details(for: item)
            } else {
                Text(String(localized: "\(model.selection.count) objects selected", table: "Editor"))
                    .foregroundStyle(.secondary)
            }
            ButtonRow {
                Button(String(localized: "Duplicate", table: "Editor")) { model.duplicateSelection() }
                    .help(String(localized: "Duplicate (⌘D)", table: "Editor"))
                Button(String(localized: "Delete", table: "Editor"), role: .destructive) { model.deleteSelection() }
            }
            Menu(String(localized: "Arrange", table: "Editor")) {
                Button(String(localized: "Bring to Front", table: "Editor")) { model.reorderSelection(.front) }
                Button(String(localized: "Bring Forward", table: "Editor")) { model.reorderSelection(.forward) }
                Button(String(localized: "Send Backward", table: "Editor")) { model.reorderSelection(.backward) }
                Button(String(localized: "Send to Back", table: "Editor")) { model.reorderSelection(.back) }
            }
            .fixedSize()
        } header: {
            Text(title)
        }
    }

    private var title: String {
        guard model.selection.count == 1, let id = model.selection.first,
            let item = model.listItems.first(where: { $0.id == id })
        else { return String(localized: "Selection", table: "Editor") }
        return EditorStrings.label(item)
    }

    @ViewBuilder
    private func details(for item: EditorListItem) -> some View {
        let document = model.document
        switch item.id {
        case .layer(let id):
            if let layer = document.layers.first(where: { $0.id == id }) {
                UndoableSlider(
                    title: String(localized: "Opacity", table: "Editor"), value: layer.opacity, range: 0...1,
                    model: model, format: { EditorFormat.percent($0 * 100) }
                ) { model.setLayerOpacity($0, for: id) }
                UndoableSlider(
                    title: String(localized: "Scale", table: "Editor"), value: layer.placement.scale, range: 0.05...4,
                    model: model, format: { EditorFormat.percent($0 * 100) }
                ) { model.setLayerScale($0, for: id) }
            }
        case .mask(let id):
            if let mask = document.masks.first(where: { $0.id == id }) {
                ColorPicker(
                    String(localized: "Redaction Color", table: "Editor"),
                    selection: colorBinding(
                        { mask.fill }, { color in coalescer.run(model) { model.setRedactionFill(color) } }),
                    supportsOpacity: false)
                Text(String(localized: "Always opaque. Covered pixels are replaced in every export.", table: "Editor"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .obfuscation(let id):
            if let effect = document.obfuscations.first(where: { $0.id == id }) {
                let amount: Double =
                    switch effect.style {
                    case .blur(let radius): radius
                    case .pixelate(let block): block
                    }
                UndoableSlider(
                    title: String(localized: "Strength", table: "Editor"), value: amount, range: 1...64, model: model
                ) { model.setObfuscationAmount($0, for: id) }
                Label(
                    String(localized: "Cosmetic, not secure: text can remain recoverable.", table: "Editor"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
            }
        case .callout(let id):
            if let callout = document.callouts.first(where: { $0.id == id }) {
                switch callout.kind {
                case .spotlight(_, let dim):
                    UndoableSlider(
                        title: String(localized: "Dimming", table: "Editor"), value: dim, range: 0...1, model: model,
                        format: { EditorFormat.percent($0 * 100) }
                    ) { model.setSpotlightDim($0, for: id) }
                case .magnifier(let source, _):
                    Text(String(localized: "Magnified area", table: "Editor"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FrameFields(frame: source) { model.setMagnifierSource($0, for: id) }
                }
            }
        case .annotation(let id):
            if item.kind == .text {
                Button(String(localized: "Edit Text", table: "Editor")) { model.beginEditingText(id) }
                    .help(String(localized: "Edit Text (Return)", table: "Editor"))
            }
        }
    }
}

// MARK: - Style

private struct StyleSection: View {
    let model: EditorModel
    let coalescer: ChangeCoalescer

    var body: some View {
        let style = model.style
        Section {
            ColorPicker(
                String(localized: "Color", table: "Editor"),
                selection: colorBinding({ style.stroke }, { c in coalescer.run(model) { model.setStrokeColor(c) } }),
                supportsOpacity: false)
            Toggle(
                String(localized: "Fill", table: "Editor"),
                isOn: Binding(
                    get: { style.fill != nil },
                    set: { model.setFillColor($0 ? RGBA.white.withAlpha(255) : nil) }))
            if let fill = style.fill {
                ColorPicker(
                    String(localized: "Fill Color", table: "Editor"),
                    selection: colorBinding({ fill }, { c in coalescer.run(model) { model.setFillColor(c) } }))
            }
            UndoableSlider(
                title: String(localized: "Line Width", table: "Editor"), value: style.lineWidth,
                range: EditorStyle.lineWidthRange, model: model
            ) { model.setLineWidth($0) }
            UndoableSlider(
                title: String(localized: "Opacity", table: "Editor"), value: style.opacity,
                range: EditorStyle.opacityRange, model: model, format: { EditorFormat.percent($0 * 100) }
            ) { model.setOpacity($0) }
            Stepper(
                value: Binding(get: { style.fontSize }, set: { model.setFontSize($0) }), in: EditorStyle.fontSizeRange,
                step: 2
            ) {
                Text(String(localized: "Text Size: \(EditorFormat.number(style.fontSize)) px", table: "Editor"))
            }
            Button(String(localized: "Renumber Steps", table: "Editor")) { model.renumberSteps() }
                .help(String(localized: "Number steps 1, 2, 3… in their stacking order", table: "Editor"))
        } header: {
            Text(String(localized: "Style", table: "Editor"))
        }
    }
}

// MARK: - Redaction

private struct RedactionSection: View {
    let model: EditorModel
    let actions: any EditorWindowActions
    let coalescer: ChangeCoalescer

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    choose(.redact)
                } label: {
                    Label(EditorStrings.name(EditorTool.redact), systemImage: "checkmark.shield")
                }
                Text(
                    String(
                        localized:
                            "Replaces the covered pixels with a solid, opaque color in every copy, save, drag, and pin.",
                        table: "Editor")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            ColorPicker(
                String(localized: "Redaction Color", table: "Editor"),
                selection: colorBinding(
                    { model.redactionFill }, { c in coalescer.run(model) { model.setRedactionFill(c) } }),
                supportsOpacity: false)
            VStack(alignment: .leading, spacing: 6) {
                ButtonRow {
                    Button {
                        choose(.blur)
                    } label: {
                        Label(
                            String(localized: "Blur", table: "Editor"),
                            systemImage: EditorStrings.symbol(EditorTool.blur))
                    }
                    .help(EditorStrings.help(.blur))
                    Button {
                        choose(.pixelate)
                    } label: {
                        Label(
                            String(localized: "Pixelate", table: "Editor"),
                            systemImage: EditorStrings.symbol(EditorTool.pixelate))
                    }
                    .help(EditorStrings.help(.pixelate))
                }
                Label(
                    String(
                        localized:
                            "Blur and Pixelate are cosmetic, not secure: hidden text can sometimes be recovered. Use Redact for private information.",
                        table: "Editor"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                String(
                    localized:
                        "Redactions change this image only. Copies you opened separately and images you exported earlier are not changed.",
                    table: "Editor")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(String(localized: "Redaction", table: "Editor"))
        }
    }

    private func choose(_ tool: EditorTool) {
        actions.commitPendingText()
        model.selectTool(tool)
    }
}

// MARK: - Pixel tools

private struct PixelToolsSection: View {
    let model: EditorModel

    var body: some View {
        Section {
            let sample = model.tool == .colorPicker ? model.pickedColor : model.inspection
            if let sample {
                LabeledContent(String(localized: "Pixel", table: "Editor")) {
                    Text(String(localized: "\(sample.x), \(sample.y)", table: "Editor")).monospacedDigit()
                }
                LabeledContent(String(localized: "Color (sRGB)", table: "Editor")) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(cgColor: sample.color.cgColor))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                            .frame(width: 18, height: 14)
                            .accessibilityHidden(true)
                        Text(sample.hex).monospaced().textSelection(.enabled)
                    }
                }
                LabeledContent(String(localized: "RGB", table: "Editor")) {
                    Text(sample.rgbText).monospacedDigit().textSelection(.enabled)
                }
                if !sample.color.isOpaque {
                    LabeledContent(String(localized: "Alpha", table: "Editor")) {
                        Text(verbatim: "\(sample.color.a)").monospacedDigit()
                    }
                }
                if model.tool == .colorPicker {
                    ButtonRow {
                        Button(String(localized: "Copy HEX", table: "Editor")) { model.copyPickedColor(asHex: true) }
                        Button(String(localized: "Copy RGB", table: "Editor")) { model.copyPickedColor(asHex: false) }
                    }
                }
            } else if model.tool != .ruler {
                Text(
                    model.tool == .colorPicker
                        ? String(localized: "Click the image to sample a color.", table: "Editor")
                        : String(localized: "Move the pointer over the image.", table: "Editor")
                )
                .foregroundStyle(.secondary)
            }
            if model.tool == .ruler {
                if let ruler = model.ruler {
                    Text(EditorFormat.measurement(ruler))
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Button(String(localized: "Clear Ruler", table: "Editor")) { model.clearRuler() }
                } else {
                    Text(String(localized: "Drag across the image to measure.", table: "Editor"))
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                model.measurementPointScale == nil
                    ? String(
                        localized: "Values are image pixels. This image has no screen scale, so points are not shown.",
                        table: "Editor")
                    : String(
                        localized: "Values are image pixels; points use the capture's screen scale.", table: "Editor")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(String(localized: "Pixel Tools", table: "Editor"))
        }
    }
}

// MARK: - Text and QR recognition

private struct RecognitionSection: View {
    let model: EditorModel
    @State private var mode: OCRTextMode?

    var body: some View {
        let selectedMode = mode ?? model.environment.settings.preferences.ocrTextMode
        Section {
            ButtonRow {
                Button(String(localized: "Recognize Text", table: "Editor")) {
                    Task { await model.recognizeText() }
                }
                .help(String(localized: "Recognize text on this device (inside the crop, if any)", table: "Editor"))
                Button(String(localized: "Scan QR Code", table: "Editor")) {
                    Task { await model.decodeQR() }
                }
            }
            .disabled(model.recognition == .running || model.qr == .running)
            if !model.unavailableRecognitionLanguages.isEmpty {
                Text(EditorStrings.unavailableLanguages(model.unavailableRecognitionLanguages))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.recognition == .running || model.qr == .running {
                ProgressView().controlSize(.small)
            }
            if let text = model.recognizedText(mode: selectedMode) {
                Picker(
                    String(localized: "Format", table: "Editor"),
                    selection: Binding(get: { selectedMode }, set: { mode = $0 })
                ) {
                    ForEach(OCRTextMode.allCases, id: \.self) { Text(EditorStrings.name($0)).tag($0) }
                }
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .accessibilityLabel(String(localized: "Recognized text", table: "Editor"))
                ButtonRow {
                    Button(String(localized: "Copy Text", table: "Editor")) {
                        model.copyRecognizedText(mode: selectedMode)
                    }
                    Button(String(localized: "Clear", table: "Editor")) { model.clearRecognition() }
                }
            }
            let payloads = model.qrPayloads
            if !payloads.isEmpty {
                Text(
                    String(
                        localized: "QR contents are untrusted. Recortia never opens them on its own.", table: "Editor")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(payloads.enumerated()), id: \.offset) { index, payload in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(EditorStrings.payloadKind(payload.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(payload.string ?? String(localized: "\(payload.bytes.count) bytes", table: "Editor"))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        // The full link can be truncated above; the host it opens never is.
                        if case .webURL(let url) = payload.kind, let host = url.host(percentEncoded: false) {
                            Text(String(localized: "Opens \(host)", table: "Editor"))
                                .font(.callout.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            if payload.string != nil {
                                Button(String(localized: "Copy", table: "Editor")) { model.copyQRPayload(at: index) }
                            }
                            if model.canOpenQRPayload(at: index) {
                                Button(String(localized: "Open Link", table: "Editor")) {
                                    model.openQRPayload(payload, at: index)
                                }
                            }
                        }
                    }
                }
                Button(String(localized: "Clear", table: "Editor")) { model.clearQR() }
            }
        } header: {
            Text(String(localized: "Text & QR", table: "Editor"))
        }
    }
}

// MARK: - Document

private struct DocumentSection: View {
    let model: EditorModel

    var body: some View {
        let document = model.document
        Section {
            LabeledContent(String(localized: "Canvas", table: "Editor")) {
                Text(EditorFormat.size(document.canvasSize)).monospacedDigit()
            }
            LabeledContent(String(localized: "Crop", table: "Editor")) {
                HStack {
                    Text(
                        document.crop.map { EditorFormat.size($0.size) }
                            ?? String(localized: "None", table: "Editor")
                    )
                    .monospacedDigit()
                    Button(String(localized: "Reset", table: "Editor")) { model.setCrop(nil) }
                        .disabled(document.crop == nil)
                }
            }
            Stepper(
                value: Binding(get: { document.resizeScale * 100 }, set: { model.setResizeScale($0 / 100) }),
                in: (EditorModel.resizeRange.lowerBound * 100)...(EditorModel.resizeRange.upperBound * 100), step: 10
            ) {
                let output = document.outputPixelSize(exportScale: 1)
                Text(
                    String(
                        localized:
                            "Output: \(EditorFormat.percent(document.resizeScale * 100)), \(output.width) × \(output.height) px",
                        table: "Editor"))
            }
            ButtonRow {
                Button(String(localized: "Fit Canvas to Content", table: "Editor")) { model.fitCanvasToContent() }
                Button(String(localized: "Add Margin", table: "Editor")) {
                    model.expandCanvas(top: 40, left: 40, bottom: 40, right: 40)
                }
                .help(String(localized: "Add 40 pixels of empty canvas on every side", table: "Editor"))
            }
        } header: {
            Text(String(localized: "Document", table: "Editor"))
        }
    }
}

// MARK: - Composition

private struct CompositionSection: View {
    let model: EditorModel
    let actions: any EditorWindowActions

    var body: some View {
        let layers = model.document.layers.count
        Section {
            ButtonRow {
                Button(String(localized: "Add Image…", table: "Editor")) { actions.addImageFromFile() }
                Button(String(localized: "Paste Image", table: "Editor")) { actions.pasteImageLayer() }
                    .help(String(localized: "Add the image on the clipboard as a new layer", table: "Editor"))
            }
            Button(String(localized: "Side by Side", table: "Editor")) { model.arrangeSideBySide() }
                .disabled(layers < 2)
                .help(String(localized: "Place all images in a row at the same height", table: "Editor"))
            Toggle(
                String(localized: "Compare Transparency", table: "Editor"),
                isOn: Binding(
                    get: { model.isComparingTransparency }, set: { _ in model.toggleTransparencyComparison() })
            )
            .disabled(layers < 2)
            .help(String(localized: "Show the top image half-transparent over the others", table: "Editor"))
            HStack(spacing: 2) {
                ForEach(EditorAlignment.allCases, id: \.self) { alignment in
                    Button {
                        model.align(alignment)
                    } label: {
                        Label(EditorStrings.name(alignment), systemImage: EditorStrings.symbol(alignment))
                    }
                    .labelStyle(.iconOnly)
                    .help(EditorStrings.name(alignment))
                }
            }
            .disabled(model.selection.isEmpty)
        } header: {
            Text(String(localized: "Composition", table: "Editor"))
        }
    }
}

// MARK: - Presentation

private struct PresentationSection: View {
    let model: EditorModel
    let coalescer: ChangeCoalescer

    private enum BackgroundKind: Hashable { case plain, solid, gradient }

    var body: some View {
        let presentation = model.document.presentation
        Section {
            Picker(
                String(localized: "Background", table: "Editor"),
                selection: Binding(get: { kind(presentation.background) }, set: { setKind($0, presentation) })
            ) {
                Text(String(localized: "None", table: "Editor")).tag(BackgroundKind.plain)
                Text(String(localized: "Solid", table: "Editor")).tag(BackgroundKind.solid)
                Text(String(localized: "Gradient", table: "Editor")).tag(BackgroundKind.gradient)
            }
            switch presentation.background {
            case .none:
                EmptyView()
            case .solid(let color):
                ColorPicker(
                    String(localized: "Background Color", table: "Editor"),
                    selection: colorBinding(
                        { color }, { c in coalescer.run(model) { model.setBackground(.solid(c)) } }),
                    supportsOpacity: false)
            case .linearGradient(let from, let to, let angle):
                ColorPicker(
                    String(localized: "Start Color", table: "Editor"),
                    selection: colorBinding(
                        { from },
                        { c in
                            coalescer.run(model) {
                                model.setBackground(.linearGradient(from: c, to: to, angleDegrees: angle))
                            }
                        }),
                    supportsOpacity: false)
                ColorPicker(
                    String(localized: "End Color", table: "Editor"),
                    selection: colorBinding(
                        { to },
                        { c in
                            coalescer.run(model) {
                                model.setBackground(.linearGradient(from: from, to: c, angleDegrees: angle))
                            }
                        }),
                    supportsOpacity: false)
            }
            UndoableSlider(
                title: String(localized: "Padding", table: "Editor"), value: presentation.padding, range: 0...256,
                model: model
            ) { model.setPadding($0.rounded()) }
            UndoableSlider(
                title: String(localized: "Corner Radius", table: "Editor"), value: presentation.cornerRadius,
                range: 0...128, model: model
            ) { model.setCornerRadius($0.rounded()) }
            Toggle(
                String(localized: "Shadow", table: "Editor"),
                isOn: Binding(
                    get: { presentation.shadow != nil },
                    set: { model.setShadow($0 ? Presentation.Shadow() : nil) }))
            Toggle(
                String(localized: "Show Output Preview", table: "Editor"),
                isOn: Binding(get: { model.showsOutputPreview }, set: { model.setShowsOutputPreview($0) })
            )
            .help(String(localized: "Show exactly what Copy and Save produce, including framing", table: "Editor"))
        } header: {
            Text(String(localized: "Presentation", table: "Editor"))
        }
    }

    private func kind(_ background: Presentation.Background) -> BackgroundKind {
        switch background {
        case .none: .plain
        case .solid: .solid
        case .linearGradient: .gradient
        }
    }

    private func setKind(_ kind: BackgroundKind, _ presentation: Presentation) {
        switch kind {
        case .plain: model.setBackground(.none)
        case .solid: model.setBackground(.solid(RGBA(r: 242, g: 242, b: 247)))
        case .gradient:
            model.setBackground(
                .linearGradient(from: RGBA(r: 90, g: 120, b: 220), to: RGBA(r: 170, g: 90, b: 200), angleDegrees: 135))
        }
    }
}
