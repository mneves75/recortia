import CoreGraphics
import Domain
import Features
import Imaging
import SwiftUI

/// The inspector: what the person is working on, and nothing else. Format holds the selection,
/// the active tool's style and the redaction wording; Image holds size, background, images and
/// text/QR recognition. The shown tab follows selection and tool until the person picks one.
struct EditorInspectorView: View {
    let model: EditorModel
    let actions: any EditorWindowActions
    @State private var coalescer = ChangeCoalescer()
    /// The person's own choice, cleared whenever the selection or the tool changes.
    @State private var chosenTab: InspectorTab?

    private enum InspectorTab: Hashable { case format, image }

    /// Tools whose options live in the Format tab.
    private static let formatTools: Set<EditorTool> = [
        .text, .arrow, .line, .rectangle, .ellipse, .freehand, .highlighter, .step, .redact, .blur, .pixelate,
        .loupe, .ruler, .colorPicker,
    ]

    var body: some View {
        let hasFormat = !model.selection.isEmpty || Self.formatTools.contains(model.tool)
        let tab = chosenTab ?? (hasFormat ? .format : .image)
        VStack(spacing: 0) {
            Picker(selection: Binding(get: { tab }, set: { chosenTab = $0 })) {
                Text("Format", tableName: "Editor").tag(InspectorTab.format)
                Text("Image", tableName: "Editor").tag(InspectorTab.image)
            } label: {
                Text("Inspector", tableName: "Editor")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("inspector.tab")
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            // The cosmetic warning stays visible whichever tab is shown (FR-06).
            if showsCosmeticWarning {
                CosmeticWarning()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            Form {
                switch tab {
                case .format:
                    if hasFormat {
                        FormatTab(model: model, actions: actions, coalescer: coalescer)
                    } else {
                        Text("Select an object or choose a tool.", tableName: "Editor")
                            .foregroundStyle(.secondary)
                    }
                case .image:
                    SizeSection(model: model)
                    BackgroundSection(model: model, coalescer: coalescer)
                    ImagesSection(model: model, actions: actions)
                    RecognitionSection(model: model)
                }
            }
            .formStyle(.grouped)
        }
        .controlSize(.small)
        .onChange(of: model.selection) { chosenTab = nil }
        .onChange(of: model.tool) { chosenTab = nil }
    }

    private var showsCosmeticWarning: Bool {
        model.tool.isCosmeticObfuscation
            || model.selection.contains(where: { if case .obfuscation = $0 { true } else { false } })
    }
}

// MARK: - Format

private struct FormatTab: View {
    let model: EditorModel
    let actions: any EditorWindowActions
    let coalescer: ChangeCoalescer

    var body: some View {
        let selection = model.selection
        let tool = model.tool
        let selectedAnnotations = model.document.annotations.filter { selection.contains(.annotation($0.id)) }
        if !selection.isEmpty {
            ObjectSection(model: model, coalescer: coalescer)
        }
        if (tool.usesStyle && tool != .select) || !selectedAnnotations.isEmpty {
            StyleSection(model: model, annotations: selectedAnnotations, coalescer: coalescer)
            ArrowCurveSection(model: model, annotations: selectedAnnotations)
            if tool == .text || selectedAnnotations.contains(where: { if case .text = $0.kind { true } else { false } })
            {
                TextAppearanceSection(model: model)
            }
        }
        let masks = model.document.masks.filter { selection.contains(.mask($0.id)) }
        if tool == .redact || !masks.isEmpty {
            RedactionSection(model: model, selectedMask: masks.first, coalescer: coalescer)
        }
        if [.loupe, .colorPicker, .ruler].contains(tool) {
            PixelToolsSection(model: model)
        }
    }
}

/// Which style values the renderer reads for the kinds in play (`AnnotationRenderer.draw`,
/// `TextLayout.operation`): fill paints shapes, step discs and plain-text backgrounds; line width
/// strokes every shape, sizes step discs and outlines outlined text; text size is text only.
private struct StyleUse {
    var fill = false
    var lineWidth = false
    var textSize = false

    init(annotations: [Annotation], tool: EditorTool, textAppearance: TextAppearance) {
        if annotations.isEmpty {
            add(tool: tool, textAppearance: textAppearance)
        } else {
            for annotation in annotations {
                switch annotation.kind {
                case .text(let text): add(tool: .text, textAppearance: text.resolvedAppearance)
                case .arrow: add(tool: .arrow, textAppearance: textAppearance)
                case .line: add(tool: .line, textAppearance: textAppearance)
                case .rectangle: add(tool: .rectangle, textAppearance: textAppearance)
                case .ellipse: add(tool: .ellipse, textAppearance: textAppearance)
                case .freehand: add(tool: .freehand, textAppearance: textAppearance)
                case .highlighter: add(tool: .highlighter, textAppearance: textAppearance)
                case .step: add(tool: .step, textAppearance: textAppearance)
                }
            }
        }
    }

    private mutating func add(tool: EditorTool, textAppearance: TextAppearance) {
        switch tool {
        case .text:
            textSize = true
            // Boxed text paints its background through the textBackground controls instead.
            if !textAppearance.isBoxed { fill = true }
            if textAppearance == .outlined { lineWidth = true }
        case .rectangle, .ellipse, .step:
            fill = true
            lineWidth = true
        case .arrow, .line, .freehand, .highlighter:
            lineWidth = true
        default:
            break
        }
    }
}

private struct StyleSection: View {
    let model: EditorModel
    let annotations: [Annotation]
    let coalescer: ChangeCoalescer

    var body: some View {
        let style = model.style
        let use = StyleUse(annotations: annotations, tool: model.tool, textAppearance: style.textAppearance)
        let boxedText = annotations.filter { annotation in
            guard case .text(let text) = annotation.kind else { return false }
            return text.resolvedAppearance.isBoxed
        }
        let backgroundColor = if let first = boxedText.first { first.style.fill } else { style.textBackgroundColor }
        let canResetBackground = style.textBackgroundColor != nil || boxedText.contains { $0.style.fill != nil }
        let usesSteps =
            model.tool == .step || annotations.contains { if case .step = $0.kind { true } else { false } }
        Section {
            ColorPicker(
                String(localized: "Color", table: "Editor"),
                selection: colorBinding({ style.stroke }, { c in coalescer.run(model) { model.setStrokeColor(c) } }),
                supportsOpacity: false)
            SavedColorsGrid(model: model)
            if !boxedText.isEmpty || (model.tool == .text && annotations.isEmpty && style.textAppearance.isBoxed) {
                ColorPicker(
                    String(localized: "Background Color", table: "Editor"),
                    selection: colorBinding(
                        { backgroundColor ?? .white },
                        { c in coalescer.run(model) { model.setTextBackgroundColor(c) } })
                )
                .accessibilityIdentifier("textBackground.color")
                .disabled(!model.canSetTextAppearance)
                .help(
                    String(
                        localized: "Reset restores white. A transparent color keeps the background clear.",
                        table: "Editor"))
                if boxedText.contains(where: { $0.style.fill != backgroundColor }) {
                    Text(String(localized: "Mixed backgrounds", table: "Editor"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("textBackground.mixed")
                }
                Button(String(localized: "Reset Background", table: "Editor")) {
                    model.setTextBackgroundColor(nil)
                }
                .accessibilityIdentifier("textBackground.reset")
                .disabled(!model.canSetTextAppearance || !canResetBackground)
            }
            if use.fill {
                Toggle(
                    String(localized: "Fill", table: "Editor"),
                    isOn: Binding(
                        get: { style.fill != nil },
                        set: { model.setFillColor($0 ? RGBA.white.withAlpha(255) : nil) })
                )
                .accessibilityIdentifier("style.fill")
                if let fill = style.fill {
                    ColorPicker(
                        String(localized: "Fill Color", table: "Editor"),
                        selection: colorBinding({ fill }, { c in coalescer.run(model) { model.setFillColor(c) } }))
                }
            }
            if use.lineWidth {
                UndoableSlider(
                    title: String(localized: "Line Width", table: "Editor"), identifier: "style.lineWidth",
                    value: style.lineWidth, range: EditorStyle.lineWidthRange, model: model
                ) { model.setLineWidth($0) }
            }
            UndoableSlider(
                title: String(localized: "Opacity", table: "Editor"), identifier: "style.opacity",
                value: style.opacity, range: EditorStyle.opacityRange, model: model,
                format: { EditorFormat.percent($0 * 100) }
            ) { model.setOpacity($0) }
            if use.textSize {
                let size = String(localized: "\(EditorFormat.number(style.fontSize)) px", table: "Editor")
                LabeledContent(String(localized: "Text Size", table: "Editor")) {
                    HStack(spacing: 4) {
                        Text(size).monospacedDigit().accessibilityHidden(true)
                        Stepper(
                            value: Binding(get: { style.fontSize }, set: { model.setFontSize($0) }),
                            in: EditorStyle.fontSizeRange, step: 2
                        ) {
                            Text(String(localized: "Text Size", table: "Editor"))
                        }
                        .labelsHidden()
                        .accessibilityValue(size)
                        .accessibilityIdentifier("style.textSize")
                    }
                }
            }
            if usesSteps {
                Button(String(localized: "Renumber Steps", table: "Editor")) { model.renumberSteps() }
                    .help(String(localized: "Number steps 1, 2, 3… in their stacking order", table: "Editor"))
            }
        } header: {
            Text(String(localized: "Style", table: "Editor"))
        }
    }
}

/// Saved colors as swatches, then Save and Remove for the current color.
private struct SavedColorsGrid: View {
    let model: EditorModel

    private var isUnavailable: Bool {
        if case .unsupportedSchema = model.environment.settings.loadIssue { return true }
        return model.isClosed
    }

    var body: some View {
        let current = model.style.stroke.withAlpha(255)
        let saved = model.savedAnnotationColors
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 24, maximum: 24), spacing: 4)], alignment: .leading, spacing: 4
            ) {
                ForEach(saved, id: \.self) { color in
                    Swatch(color: color, isSelected: color == current) { model.applySavedColor(color) }
                        .disabled(isUnavailable)
                        .contextMenu {
                            Button(String(localized: "Remove Saved Color", table: "Editor")) {
                                model.removeSavedColor(color)
                            }
                        }
                }
                Button {
                    model.saveCurrentStrokeColor()
                } label: {
                    Label {
                        Text(String(localized: "Save Current Color", table: "Editor"))
                    } icon: {
                        Image(systemName: "plus").frame(width: 12, height: 16)
                    }
                }
                .buttonStyle(ChoiceButtonStyle(isSelected: false))
                .accessibilityIdentifier("palette.save")
                .disabled(!model.canSaveStrokeColor)
                .help(
                    String(
                        localized: "Save up to 12 distinct annotation colors. Duplicate colors are already saved.",
                        table: "Editor"))
                Button {
                    model.removeSavedColor(model.style.stroke)
                } label: {
                    Label {
                        Text(String(localized: "Remove Current Color", table: "Editor"))
                    } icon: {
                        Image(systemName: "minus").frame(width: 12, height: 16)
                    }
                }
                .buttonStyle(ChoiceButtonStyle(isSelected: false))
                .accessibilityIdentifier("palette.remove")
                .disabled(isUnavailable || !saved.contains(current))
                .help(
                    String(
                        localized:
                            "Remove the current annotation color from saved colors. Existing annotations keep their color.",
                        table: "Editor"))
            }
            .labelStyle(.iconOnly)
            if isUnavailable {
                Text(
                    String(
                        localized: "Saved colors are unavailable while newer preferences are protected.",
                        table: "Editor")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Swatch: View {
    let color: RGBA
    let isSelected: Bool
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(cgColor: color.cgColor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                .frame(width: 16, height: 16)
                .padding(4)
                .overlay {
                    // The ring uses the label color, so it shows on any swatch color.
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.primary, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("palette.apply.\(color.hex.dropFirst())")
        .accessibilityLabel(color.hex)
        .accessibilityValue(isSelected ? String(localized: "Selected", table: "Editor") : "")
        .help(color.hex)
    }
}

/// One of several choices: a tile with a border that thickens and takes the accent when chosen.
private struct ChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 6)
            .background(
                shape.fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                shape.strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.45)
    }
}

private struct ArrowCurveSection: View {
    let model: EditorModel
    let annotations: [Annotation]

    private var selectedStates: [Bool] {
        annotations.compactMap { annotation in
            guard case .arrow(_, _, let control) = annotation.kind else { return nil }
            return control != nil
        }
    }

    var body: some View {
        let states = selectedStates
        if model.tool == .arrow || !states.isEmpty {
            let state: Bool? =
                if states.isEmpty { model.style.curvedArrows } else if states.allSatisfy({ $0 == states[0] }) {
                    states[0]
                } else { nil }
            Section {
                HStack(spacing: 6) {
                    choice(false, state: state)
                    choice(true, state: state)
                }
                if state == nil {
                    Text("Mixed arrow shapes", tableName: "Editor")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("arrow.mixed")
                }
                Group {
                    if model.style.curvedArrows {
                        Text("New arrows: Curved", tableName: "Editor")
                    } else {
                        Text("New arrows: Straight", tableName: "Editor")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("arrow.futureDefault")
                if let bend = model.selectedArrowBend {
                    ArrowBendFields(point: bend) { model.setArrowBend($0) }
                        .id(model.selection)
                }
            } header: {
                Text("Arrow", tableName: "Editor")
            }
            .disabled(!model.canSetArrowCurve)
            .help(
                model.canSetArrowCurve
                    ? String(localized: "Applies to selected arrows and new arrows in this editor.", table: "Editor")
                    : String(localized: "Finish editing text before changing the arrow.", table: "Editor"))
        }
    }

    private func choice(_ curved: Bool, state: Bool?) -> some View {
        let title =
            curved
            ? LocalizedStringResource("Curved", table: "Editor")
            : LocalizedStringResource("Straight", table: "Editor")
        let isSelected = state == curved
        return Button {
            model.setArrowCurved(curved)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: curved ? "arrow.turn.up.right" : "arrow.up.right")
            }
        }
        .buttonStyle(ChoiceButtonStyle(isSelected: isSelected))
        .accessibilityIdentifier(curved ? "arrow.curved" : "arrow.straight")
        .accessibilityLabel(Text(title))
        .accessibilityValue(isSelected ? String(localized: "Selected", table: "Editor") : "")
    }
}

private struct ArrowBendFields: View {
    let point: Point<DocumentSpace>
    let onCommit: (Point<DocumentSpace>) -> Bool
    @State private var x = 0.0
    @State private var y = 0.0

    var body: some View {
        Group {
            TextField(value: $x, format: .number.precision(.fractionLength(0...2))) {
                Text("Bend X", tableName: "Editor")
            }
            .accessibilityIdentifier("arrow.bendX")
            TextField(value: $y, format: .number.precision(.fractionLength(0...2))) {
                Text("Bend Y", tableName: "Editor")
            }
            .accessibilityIdentifier("arrow.bendY")
        }
        .monospacedDigit()
        .help(String(localized: "Document pixels. Press Return to apply.", table: "Editor"))
        .onSubmit(commit)
        .onAppear(perform: load)
        .onChange(of: point) { load() }
    }

    private func load() {
        x = point.x
        y = point.y
    }

    private func commit() {
        if !onCommit(Point(x: x, y: y)) { load() }
    }
}

private struct TextAppearanceSection: View {
    let model: EditorModel

    var body: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(TextAppearance.allCases, id: \.self) { appearance in
                    let isSelected = model.style.textAppearance == appearance
                    Button {
                        model.setTextAppearance(appearance)
                    } label: {
                        AppearancePreview(appearance: appearance)
                    }
                    .buttonStyle(ChoiceButtonStyle(isSelected: isSelected))
                    .accessibilityIdentifier("textAppearance.\(appearance.rawValue)")
                    .accessibilityLabel(EditorStrings.name(appearance))
                    .accessibilityValue(isSelected ? String(localized: "Selected", table: "Editor") : "")
                    .disabled(!model.canSetTextAppearance)
                    .help(
                        model.canSetTextAppearance
                            ? EditorStrings.name(appearance)
                            : String(localized: "Finish editing text before changing its style.", table: "Editor"))
                }
            }
        } header: {
            Text(String(localized: "Text Style", table: "Editor"))
        }
    }
}

/// "Aa" drawn the way the appearance renders: its system font design, an outline, or a box.
private struct AppearancePreview: View {
    let appearance: TextAppearance

    var body: some View {
        let design: Font.Design =
            switch appearance {
            case .rounded, .roundedBoxed: .rounded
            case .monospaced, .monospacedBoxed: .monospaced
            case .standard, .outlined, .boxed: .default
            }
        let sample = Text(verbatim: "Aa").font(.system(size: 14, weight: .medium, design: design))
        if appearance == .outlined {
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) * .pi / 4
                    sample.foregroundStyle(.primary).offset(x: cos(angle), y: sin(angle))
                }
                // Outline in the label color around a fill in the tile color: legible in light and dark.
                sample.foregroundStyle(Color(nsColor: .controlBackgroundColor))
            }
            .accessibilityHidden(true)
        } else if appearance.isBoxed {
            // The box takes the label color so it stands out from the tile in light and dark.
            sample
                .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                .padding(.horizontal, 4)
                .background(.primary, in: RoundedRectangle(cornerRadius: appearance == .roundedBoxed ? 4 : 0))
                .accessibilityHidden(true)
        } else {
            sample.accessibilityHidden(true)
        }
    }
}

private struct RedactionSection: View {
    let model: EditorModel
    let selectedMask: SecureMask?
    let coalescer: ChangeCoalescer

    var body: some View {
        Section {
            ColorPicker(
                String(localized: "Redaction Color", table: "Editor"),
                selection: colorBinding(
                    { selectedMask?.fill ?? model.redactionFill },
                    { c in coalescer.run(model) { model.setRedactionFill(c) } }),
                supportsOpacity: false
            )
            .accessibilityIdentifier("redaction.color")
            Text(
                String(
                    localized:
                        "Covered pixels are replaced in every export. Other copies and earlier exports are not changed.",
                    table: "Editor")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(String(localized: "Redaction", table: "Editor"))
        }
    }
}

/// The cosmetic-effect warning, pinned above the tabs.
private struct CosmeticWarning: View {
    var body: some View {
        Label(
            String(
                localized: "Cosmetic, not secure: text can remain recoverable. Use Redact for private information.",
                table: "Editor"),
            systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("redaction.cosmeticWarning")
    }
}

// MARK: - Shared controls

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
    var identifier: String?
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
                .accessibilityIdentifier(identifier ?? "")
                Text(format(value))
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(format(value))
    }
}

/// X, Y, width and height in a 2×2 grid of labelled fields, committed on Return.
private struct FrameFields: View {
    let frame: Rect<DocumentSpace>
    let identifier: String
    var preservesAspectRatio = false
    let onCommit: (Rect<DocumentSpace>) -> Void
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var width = 0.0
    @State private var height = 0.0

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                field(String(localized: "X", table: "Editor"), "x", $x)
                field(String(localized: "Y", table: "Editor"), "y", $y)
            }
            GridRow {
                field(String(localized: "Width", table: "Editor"), "width", $width)
                field(String(localized: "Height", table: "Editor"), "height", $height)
            }
        }
        .onAppear(perform: load)
        .onChange(of: frame) { load() }
    }

    @ViewBuilder
    private func field(_ title: String, _ name: String, _ value: Binding<Double>) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .accessibilityHidden(true)
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .onSubmit(commit)
            .help(String(localized: "Document pixels. Press Return to apply.", table: "Editor"))
            .accessibilityIdentifier("\(identifier).\(name)")
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

// MARK: - Object

private struct ObjectSection: View {
    let model: EditorModel
    let coalescer: ChangeCoalescer

    var body: some View {
        let item = single
        Section {
            if let item {
                FrameFields(frame: item.frame, identifier: "frame", preservesAspectRatio: item.kind == .image) {
                    model.setFrame($0, for: item.id)
                }
                details(for: item)
            }
            ButtonRow {
                Button(String(localized: "Duplicate", table: "Editor")) { model.duplicateSelection() }
                    .help(String(localized: "Duplicate (⌘D)", table: "Editor"))
                Button(String(localized: "Delete", table: "Editor"), role: .destructive) { model.deleteSelection() }
                Menu(String(localized: "Arrange", table: "Editor")) {
                    Button(String(localized: "Bring to Front", table: "Editor")) { model.reorderSelection(.front) }
                    Button(String(localized: "Bring Forward", table: "Editor")) { model.reorderSelection(.forward) }
                    Button(String(localized: "Send Backward", table: "Editor")) { model.reorderSelection(.backward) }
                    Button(String(localized: "Send to Back", table: "Editor")) { model.reorderSelection(.back) }
                }
                .fixedSize()
            }
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
        } header: {
            if let item {
                Text(EditorStrings.label(item))
            } else {
                Text(String(localized: "\(model.selection.count) objects", table: "Editor"))
            }
        }
    }

    private var single: EditorListItem? {
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        return model.listItems.first { $0.id == id }
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
        case .mask:
            // The redaction color is in the Redaction section, which shows for a selected redaction.
            EmptyView()
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
                    FrameFields(frame: source, identifier: "magnifier.source") { model.setMagnifierSource($0, for: id) }
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

// MARK: - Pixel tools

private struct PixelToolsSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        let units =
            model.measurementPointScale == nil
            ? String(
                localized: "Values are image pixels. This image has no screen scale, so points are not shown.",
                table: "Editor")
            : String(localized: "Values are image pixels; points use the capture's screen scale.", table: "Editor")
        Section {
            if model.tool == .colorPicker {
                Picker(selection: $model.colorSampleSize) {
                    Text("1×1 — Single pixel", tableName: "Editor").tag(PixelSampleSize.singlePixel)
                    Text("3×3 — Average", tableName: "Editor").tag(PixelSampleSize.threeByThree)
                    Text("5×5 — Average", tableName: "Editor").tag(PixelSampleSize.fiveByFive)
                } label: {
                    Text("Sample area", tableName: "Editor")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("color-sample-size")
                .help(
                    String(
                        localized: "Area picks average sRGB colors and alpha. Samples stop at image edges.",
                        table: "Editor"))
            }
            let sample = model.tool == .colorPicker ? model.pickedColor : model.inspection
            if let sample {
                Group {
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
                }
                .help(units)
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
                        .help(units)
                    Button(String(localized: "Clear Ruler", table: "Editor")) { model.clearRuler() }
                } else {
                    Text(String(localized: "Drag across the image to measure.", table: "Editor"))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "Pixel Tools", table: "Editor"))
        }
    }
}

// MARK: - Image

private struct SizeSection: View {
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
            Text(String(localized: "Size", table: "Editor"))
        }
    }
}

private struct BackgroundSection: View {
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
            .accessibilityIdentifier("image.background")
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
            Text(String(localized: "Framing", table: "Editor"))
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

private struct ImagesSection: View {
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
        } header: {
            Text(String(localized: "Images", table: "Editor"))
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
                .accessibilityIdentifier("recognition.format")
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
                    .accessibilityIdentifier("recognition.copyText")
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
