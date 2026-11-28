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
    /// Holds the person's tab choice, which View › Inspector also sets.
    let panes: EditorPanes
    @State private var coalescer = ChangeCoalescer()
    /// The recognized-text format chosen in this editor; nil follows the preference. Kept here so
    /// switching tabs does not discard it.
    @State private var ocrTextMode: OCRTextMode?

    var body: some View {
        let hasFormat = EditorInspectorTab.hasFormat(model)
        let tab = EditorInspectorTab.shown(chosen: panes.chosenInspectorTab, model: model)
        VStack(spacing: 0) {
            Picker(selection: Binding(get: { tab }, set: { panes.chosenInspectorTab = $0 })) {
                Text("Format", tableName: "Editor").tag(EditorInspectorTab.format)
                Text("Image", tableName: "Editor").tag(EditorInspectorTab.image)
            } label: {
                Text("Inspector", tableName: "Editor")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("inspector.tab")
            .padding(.horizontal, DesignTokens.Space.m)
            .padding(.top, DesignTokens.Space.s)
            // The cosmetic warning stays visible whichever tab is shown (FR-06).
            if model.showsCosmeticWarning {
                CosmeticWarning()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Space.m)
                    .padding(.top, DesignTokens.Space.m)
            }
            Form {
                switch tab {
                case .format:
                    if hasFormat {
                        FormatTab(model: model, coalescer: coalescer)
                    } else {
                        Text("Select an object or choose a tool.", tableName: "Editor")
                            .foregroundStyle(.secondary)
                    }
                case .image:
                    BackgroundSection(model: model, coalescer: coalescer)
                    FramingDecorationSection(model: model, coalescer: coalescer)
                    SizeSection(model: model)
                    TransformSection(model: model)
                    ImagesSection(model: model, actions: actions)
                    RecognitionSection(model: model, mode: $ocrTextMode)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            // No edit can start while automatic masking runs (FR-06 amendment).
            .disabled(model.isMaskingPending)
        }
        .controlSize(.small)
        // An opaque column over the window background (decisions 2026-11-20).
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.selection) { panes.chosenInspectorTab = nil }
        .onChange(of: model.tool) { panes.chosenInspectorTab = nil }
    }
}

/// Inspector state kept for this app session: the Position and Size disclosure starts collapsed
/// and stays as the person left it, in every editor, until the app quits.
@Observable
private final class InspectorSessionState {
    static let shared = InspectorSessionState()
    var showsPositionAndSize = false
}

// MARK: - Format

private struct FormatTab: View {
    let model: EditorModel
    let coalescer: ChangeCoalescer

    var body: some View {
        let selection = model.selection
        let tool = model.tool
        let selectedAnnotations = model.document.annotations.filter { selection.contains(.annotation($0.id)) }
        let single = single
        HeaderSection(model: model, item: single)
        if (tool.usesStyle && tool != .select) || !selectedAnnotations.isEmpty {
            AppearanceSection(model: model, annotations: selectedAnnotations, coalescer: coalescer)
            ArrowCurveSection(model: model, annotations: selectedAnnotations)
            if tool == .freehand || tool == .highlighter {
                StrokeSmoothingSection(model: model)
            }
            if tool == .text || selectedAnnotations.contains(where: { if case .text = $0.kind { true } else { false } })
            {
                TextSection(model: model, annotations: selectedAnnotations, coalescer: coalescer)
            }
        }
        let masks = model.document.masks.filter { selection.contains(.mask($0.id)) }
        if tool == .redact || !masks.isEmpty {
            RedactionSection(model: model, selectedMask: masks.first, coalescer: coalescer)
        }
        if [.loupe, .colorPicker, .ruler].contains(tool) {
            PixelToolsSection(model: model)
        }
        if tool == .crop {
            CropSection(model: model)
        }
        if let single {
            PositionSection(model: model, item: single)
        }
    }

    private var single: EditorListItem? {
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        return model.listItems.first { $0.id == id }
    }
}

/// The name of what the Format tab shows (one object, several, or the active tool), with the
/// selected object's own settings.
private struct HeaderSection: View {
    let model: EditorModel
    let item: EditorListItem?

    var body: some View {
        Section {
            if let item {
                ObjectDetails(model: model, item: item)
            }
        } header: {
            Group {
                if let item {
                    Text(EditorStrings.label(item))
                } else if !model.selection.isEmpty {
                    Text(String(localized: "\(model.selection.count) objects", table: "Editor"))
                } else {
                    Text(EditorStrings.name(model.tool))
                }
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("inspector.header")
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

/// Color with the saved palette, Fill, Line width and Opacity.
private struct AppearanceSection: View {
    let model: EditorModel
    let annotations: [Annotation]
    let coalescer: ChangeCoalescer

    var body: some View {
        let style = model.style
        let use = StyleUse(annotations: annotations, tool: model.tool, textAppearance: style.textAppearance)
        let usesSteps =
            model.tool == .step || annotations.contains { if case .step = $0.kind { true } else { false } }
        Section {
            ColorPicker(
                String(localized: "Color", table: "Editor"),
                selection: colorBinding({ style.stroke }, { c in coalescer.run(model) { model.setStrokeColor(c) } }),
                supportsOpacity: false)
            SavedColorsRow(model: model)
            if use.fill {
                LabeledContent(String(localized: "Fill", table: "Editor")) {
                    HStack(spacing: DesignTokens.Space.s) {
                        Toggle(
                            String(localized: "Fill", table: "Editor"),
                            isOn: Binding(
                                get: { style.fill != nil },
                                set: { model.setFillColor($0 ? RGBA.white.withAlpha(255) : nil) })
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityIdentifier("style.fill")
                        ColorPicker(
                            String(localized: "Fill color", table: "Editor"),
                            selection: colorBinding(
                                { style.fill ?? .white }, { c in coalescer.run(model) { model.setFillColor(c) } })
                        )
                        .labelsHidden()
                        .disabled(style.fill == nil)
                        .accessibilityIdentifier("style.fillColor")
                    }
                }
            }
            if use.lineWidth {
                UndoableSlider(
                    title: String(localized: "Line width", table: "Editor"), identifier: "style.lineWidth",
                    value: style.lineWidth, range: EditorStyle.lineWidthRange, model: model
                ) { model.setLineWidth($0) }
            }
            UndoableSlider(
                title: String(localized: "Opacity", table: "Editor"), identifier: "style.opacity",
                value: style.opacity, range: EditorStyle.opacityRange, model: model,
                format: { EditorFormat.percent($0 * 100) }
            ) { model.setOpacity($0) }
            if usesSteps {
                Button(String(localized: "Renumber Steps", table: "Editor")) { model.renumberSteps() }
                    .help(String(localized: "Number steps 1, 2, 3… in their stacking order", table: "Editor"))
            }
        } header: {
            Text(String(localized: "Appearance", table: "Editor"))
        }
    }
}

/// The saved colors as swatches, then "+" to save the current color. A swatch's context menu
/// removes it.
private struct SavedColorsRow: View {
    let model: EditorModel

    private var isUnavailable: Bool {
        if case .unsupportedSchema = model.environment.settings.loadIssue { return true }
        return model.isClosed
    }

    var body: some View {
        let current = model.style.stroke.withAlpha(255)
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 24, maximum: 24), spacing: DesignTokens.Space.xs)],
                alignment: .leading, spacing: DesignTokens.Space.xs
            ) {
                ForEach(model.savedAnnotationColors, id: \.self) { color in
                    Swatch(
                        color: color, isSelected: color == current, apply: { model.applySavedColor(color) },
                        remove: { model.removeSavedColor(color) }
                    )
                    .disabled(isUnavailable)
                }
                Button {
                    model.saveCurrentStrokeColor()
                } label: {
                    Label {
                        Text(String(localized: "Save Current Color", table: "Editor"))
                    } icon: {
                        Image(systemName: "plus").frame(width: 16, height: 16)
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .frame(width: 24, height: 24)
                .accessibilityIdentifier("palette.save")
                .disabled(!model.canSaveStrokeColor)
                .help(String(localized: "Save Current Color", table: "Editor"))
            }
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

/// A saved color: pressing applies it; the context menu and the matching accessibility action
/// (VoiceOver's actions rotor) remove it.
private struct Swatch: View {
    let color: RGBA
    let isSelected: Bool
    let apply: () -> Void
    let remove: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: apply) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                .fill(Color(cgColor: color.cgColor))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.control).strokeBorder(.separator))
                .frame(width: 16, height: 16)
                .padding(DesignTokens.Space.xs)
                .overlay {
                    // The ring uses the label color, so it shows on any swatch color.
                    if isSelected {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.container).strokeBorder(
                            .primary, lineWidth: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("palette.apply.\(color.hex.dropFirst())")
        .accessibilityLabel(color.hex)
        .accessibilityValue(isSelected ? String(localized: "Selected", table: "Editor") : "")
        .accessibilityAction(named: Text(String(localized: "Remove Saved Color", table: "Editor"))) {
            if isEnabled { remove() }
        }
        .help(color.hex)
        .contextMenu {
            Button(String(localized: "Remove Saved Color", table: "Editor"), action: remove)
        }
    }
}

/// One of several choices: a tile with a border that thickens and takes the accent when chosen.
private struct ChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.container)
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, DesignTokens.Space.s)
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
            guard case .arrow(_, _, let control, _) = annotation.kind else { return nil }
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
                HStack(spacing: DesignTokens.Space.s) {
                    choice(false, state: state)
                    choice(true, state: state)
                }
                if state == nil {
                    Text("Mixed arrow shapes", tableName: "Editor")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("arrow.mixed")
                }
                let head = model.arrowHeadState
                HStack(spacing: DesignTokens.Space.s) {
                    ForEach(Annotation.ArrowHead.allCases, id: \.self) { choice($0, state: head) }
                }
                if head == nil {
                    Text("Mixed arrowheads", tableName: "Editor")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("arrow.head.mixed")
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

    private func choice(_ head: Annotation.ArrowHead, state: Annotation.ArrowHead?) -> some View {
        let (title, symbol): (String, String) =
            switch head {
            case .filled: (String(localized: "Filled Head", table: "Editor"), "arrowtriangle.right.fill")
            case .open: (String(localized: "Open Head", table: "Editor"), "chevron.right")
            case .plain: (String(localized: "No Head", table: "Editor"), "minus")
            case .double: (String(localized: "Double Head", table: "Editor"), "arrow.left.and.right")
            }
        let isSelected = state == head
        return Button {
            model.setArrowHead(head)
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(ChoiceButtonStyle(isSelected: isSelected))
        .help(title)
        .accessibilityIdentifier("arrow.head.\(head.rawValue)")
        .accessibilityLabel(Text(title))
        .accessibilityValue(isSelected ? String(localized: "Selected", table: "Editor") : "")
    }
}

/// Smoothing for strokes the freehand and highlighter tools draw next; drawn strokes keep theirs.
private struct StrokeSmoothingSection: View {
    let model: EditorModel

    var body: some View {
        Section {
            Toggle(
                String(localized: "Smooth", table: "Editor"),
                isOn: Binding(get: { model.style.smoothsStrokes }, set: { model.setStrokeSmoothing($0) })
            )
            .toggleStyle(.switch)
            .help(String(localized: "Applies to new strokes.", table: "Editor"))
            .accessibilityIdentifier("stroke.smooth")
        }
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

/// The font design that `TextAppearance` combines with a decoration.
private enum TextFontChoice: CaseIterable, Hashable {
    case system, rounded, monospaced

    var title: String {
        switch self {
        case .system: String(localized: "System", table: "Editor")
        case .rounded: String(localized: "Rounded", table: "Editor")
        case .monospaced: String(localized: "Monospaced", table: "Editor")
        }
    }
}

/// The decoration that `TextAppearance` combines with a font. Outlined text exists only in the
/// system font, so choosing Outline also chooses System.
private enum TextStyleChoice: CaseIterable, Hashable {
    case plain, outline, box

    var title: String {
        switch self {
        case .plain: String(localized: "Plain", table: "Editor")
        case .outline: String(localized: "Outline", table: "Editor")
        case .box: String(localized: "Box", table: "Editor")
        }
    }
}

extension TextAppearance {
    fileprivate var font: TextFontChoice {
        switch self {
        case .standard, .outlined, .boxed: .system
        case .rounded, .roundedBoxed: .rounded
        case .monospaced, .monospacedBoxed: .monospaced
        }
    }

    fileprivate var styleChoice: TextStyleChoice {
        switch self {
        case .standard, .rounded, .monospaced: .plain
        case .outlined: .outline
        case .boxed, .roundedBoxed, .monospacedBoxed: .box
        }
    }

    fileprivate init(font: TextFontChoice, style: TextStyleChoice) {
        switch (font, style) {
        case (_, .outline): self = .outlined
        case (.system, .plain): self = .standard
        case (.system, .box): self = .boxed
        case (.rounded, .plain): self = .rounded
        case (.rounded, .box): self = .roundedBoxed
        case (.monospaced, .plain): self = .monospaced
        case (.monospaced, .box): self = .monospacedBoxed
        }
    }
}

/// Font, Style and Size for text, and the box background while a Box style is chosen.
private struct TextSection: View {
    let model: EditorModel
    let annotations: [Annotation]
    let coalescer: ChangeCoalescer

    var body: some View {
        let appearance = model.style.textAppearance
        let canSet = model.canSetTextAppearance
        let refusal = String(localized: "Finish editing text before changing its style.", table: "Editor")
        Section {
            Picker(
                String(localized: "Font", table: "Editor"),
                selection: Binding(
                    get: { appearance.font },
                    set: { font in
                        // Outline has no rounded or monospaced form, so another font returns to Plain.
                        let current = model.style.textAppearance.styleChoice
                        let style = current == .outline && font != .system ? .plain : current
                        model.setTextAppearance(TextAppearance(font: font, style: style))
                    })
            ) {
                ForEach(TextFontChoice.allCases, id: \.self) { font in
                    Text(font.title).tag(font)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("text.font")
            .disabled(!canSet)
            .help(canSet ? String(localized: "Font", table: "Editor") : refusal)
            Picker(
                String(localized: "Style", table: "Editor"),
                selection: Binding(
                    get: { appearance.styleChoice },
                    set: { model.setTextAppearance(TextAppearance(font: model.style.textAppearance.font, style: $0)) })
            ) {
                ForEach(TextStyleChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("text.style")
            .disabled(!canSet)
            .help(canSet ? String(localized: "Style", table: "Editor") : refusal)
            TextSizeField(model: model)
            if appearance.isBoxed || annotations.contains(where: Self.isBoxed) {
                BoxBackgroundRows(model: model, annotations: annotations, coalescer: coalescer)
            }
        } header: {
            Text(String(localized: "Text", table: "Editor"))
        }
    }

    static func isBoxed(_ annotation: Annotation) -> Bool {
        guard case .text(let text) = annotation.kind else { return false }
        return text.resolvedAppearance.isBoxed
    }
}

/// Text size as a number field with a stepper; Return or the stepper applies it.
private struct TextSizeField: View {
    let model: EditorModel
    @State private var size = 0.0

    var body: some View {
        let current = model.style.fontSize
        LabeledContent(String(localized: "Size", table: "Editor")) {
            HStack(spacing: DesignTokens.Space.xs) {
                TextField(
                    String(localized: "Size", table: "Editor"), value: $size,
                    format: .number.precision(.fractionLength(0...1))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .onSubmit(commit)
                .accessibilityIdentifier("style.textSizeField")
                Stepper(
                    value: Binding(get: { current }, set: { model.setFontSize($0) }),
                    in: EditorStyle.fontSizeRange, step: 2
                ) {
                    Text(String(localized: "Size", table: "Editor"))
                }
                .labelsHidden()
                .accessibilityValue(String(localized: "\(EditorFormat.number(current)) px", table: "Editor"))
                .accessibilityIdentifier("style.textSize")
            }
        }
        .onAppear { size = current }
        .onChange(of: current) { size = current }
    }

    private func commit() {
        guard size.isFinite else {
            size = model.style.fontSize
            return
        }
        let range = EditorStyle.fontSizeRange
        model.setFontSize(min(max(size, range.lowerBound), range.upperBound))
        size = model.style.fontSize
    }
}

/// The box background of boxed text: its color, a mixed-fill note, and Reset. Reset stays
/// available while a selected boxed text has an explicit fill, whatever the default for new text.
private struct BoxBackgroundRows: View {
    let model: EditorModel
    let annotations: [Annotation]
    let coalescer: ChangeCoalescer

    var body: some View {
        let style = model.style
        let boxedText = annotations.filter(TextSection.isBoxed)
        let backgroundColor = if let first = boxedText.first { first.style.fill } else { style.textBackgroundColor }
        let canResetBackground = style.textBackgroundColor != nil || boxedText.contains { $0.style.fill != nil }
        ColorPicker(
            String(localized: "Background color", table: "Editor"),
            selection: colorBinding(
                { backgroundColor ?? .white },
                { c in coalescer.run(model) { model.setTextBackgroundColor(c) } })
        )
        .accessibilityIdentifier("textBackground.color")
        .disabled(!model.canSetTextAppearance)
        .help(
            String(localized: "Reset restores white. A transparent color keeps the background clear.", table: "Editor"))
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
}

/// X, Y, Width and Height under a header button that shows or hides them. It starts collapsed and
/// keeps its state this session. The header reports Expanded or Collapsed as its accessibility value:
/// SwiftUI's disclosure triangle ignored accessibility Press inside this Form.
private struct PositionSection: View {
    let model: EditorModel
    let item: EditorListItem
    @Bindable private var state = InspectorSessionState.shared

    var body: some View {
        Section {
            InspectorDisclosureButton(
                title: String(localized: "Position and Size", table: "Editor"), expanded: $state.showsPositionAndSize
            )
            .accessibilityIdentifier("inspector.positionAndSize")
            if state.showsPositionAndSize {
                FrameFields(frame: item.frame, identifier: "frame", preservesAspectRatio: item.kind == .image) {
                    model.setFrame($0, for: item.id)
                }
            }
        }
    }
}

private struct InspectorDisclosureButton: View {
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(
            Text(
                expanded
                    ? String(localized: "Expanded", table: "Editor")
                    : String(localized: "Collapsed", table: "Editor"))
        )
    }
}

private struct RedactionSection: View {
    let model: EditorModel
    let selectedMask: SecureMask?
    let coalescer: ChangeCoalescer

    var body: some View {
        Section {
            ColorPicker(
                String(localized: "Redaction color", table: "Editor"),
                selection: colorBinding(
                    { selectedMask?.fill ?? model.redactionFill },
                    { c in coalescer.run(model) { model.setRedactionFill(c) } }),
                supportsOpacity: false
            )
            .accessibilityIdentifier("redaction.color")
            if model.tool == .redact {
                Toggle(
                    String(localized: "Text Only", table: "Editor"),
                    isOn: Binding(get: { model.redactsTextOnly }, set: { model.setRedactsTextOnly($0) })
                )
                .accessibilityIdentifier("redaction.textOnly")
            }
            // A required disclosure (ACCEPTANCE_TESTS RED): what redaction changes, and what it does not.
            EditorNoticeLabel(
                text: String(
                    localized:
                        "Covered pixels are replaced in every export. Other copies and earlier exports are not changed.",
                    table: "Editor"),
                systemImage: "checkmark.shield")
        } header: {
            Text(String(localized: "Redaction", table: "Editor"))
        }
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
        Grid(alignment: .leading, horizontalSpacing: DesignTokens.Space.s, verticalSpacing: DesignTokens.Space.s) {
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

/// The selected object's own settings: an image's opacity and scale, an effect's strength, a
/// spotlight's dimming, a magnifier's source.
private struct ObjectDetails: View {
    let model: EditorModel
    let item: EditorListItem

    var body: some View { details(for: item) }

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
                LayerTransformRow(model: model)
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
                    FrameFields(frame: source, identifier: "magnifier.source") { model.setMagnifierSource($0, for: id) }
                }
            }
        case .annotation:
            EmptyView()
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
                        table: "Editor")
                )
                .disabled(model.samplesDarkestPixel)
                Toggle(String(localized: "Darkest Pixel", table: "Editor"), isOn: $model.samplesDarkestPixel)
                    .accessibilityIdentifier("color.samplesDarkest")
            }
            let sample = model.tool == .colorPicker ? model.pickedColor : model.inspection
            if let sample {
                Group {
                    LabeledContent(String(localized: "Pixel", table: "Editor")) {
                        Text(String(localized: "\(sample.x), \(sample.y)", table: "Editor")).monospacedDigit()
                    }
                    LabeledContent(String(localized: "Color (sRGB)", table: "Editor")) {
                        HStack(spacing: DesignTokens.Space.s) {
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                                .fill(Color(cgColor: sample.color.cgColor))
                                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.control).stroke(.separator))
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
                    Picker(selection: $model.colorFormat) {
                        ForEach(ColorFormat.allCases, id: \.self) { format in
                            Text(verbatim: EditorStrings.name(format)).tag(format)
                        }
                    } label: {
                        Text("Format", tableName: "Editor")
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("color.format")
                    if let text = model.pickedColorText {
                        Text(verbatim: text).monospaced().textSelection(.enabled)
                            .accessibilityLabel(Text(verbatim: text))
                            .accessibilityIdentifier("color.formatted")
                    }
                    ButtonRow {
                        Button(String(localized: "Copy", table: "Editor")) { model.copyPickedColor() }
                            .accessibilityIdentifier("color.copy")
                        Button(String(localized: "Use as Text", table: "Editor")) { model.usePickedColor(as: .text) }
                            .disabled(!sample.color.isOpaque)
                            .accessibilityIdentifier("color.useAsText")
                        Button(String(localized: "Use as Background", table: "Editor")) {
                            model.usePickedColor(as: .background)
                        }
                        .disabled(!sample.color.isOpaque)
                        .accessibilityIdentifier("color.useAsBackground")
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
            Text(String(localized: "Pixel tools", table: "Editor"))
        }
        if model.tool == .colorPicker, model.contrastText != nil || model.contrastBackground != nil {
            ContrastSection(model: model)
        }
    }
}

/// The WCAG 2 contrast of two picked colors, with AA and AAA marks for normal and large text.
private struct ContrastSection: View {
    let model: EditorModel

    var body: some View {
        Section {
            slot(String(localized: "Text", table: "Editor"), model.contrastText, id: "color.contrast.text")
            slot(
                String(localized: "Background", table: "Editor"), model.contrastBackground,
                id: "color.contrast.background")
            if let contrast = model.contrast {
                LabeledContent(String(localized: "Contrast", table: "Editor")) {
                    Text(verbatim: contrast.shownRatio.formatted(.number.precision(.fractionLength(2))) + ":1")
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .accessibilityIdentifier("color.contrast.ratio")
                }
                Grid(
                    alignment: .leading, horizontalSpacing: DesignTokens.Space.m, verticalSpacing: DesignTokens.Space.s
                ) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Text("Normal", tableName: "Editor").foregroundStyle(.secondary)
                        Text("Large", tableName: "Editor").foregroundStyle(.secondary)
                    }
                    ForEach(ContrastRatio.Level.allCases, id: \.self) { level in
                        GridRow {
                            Text(verbatim: level == .aa ? "AA" : "AAA")
                            verdict(contrast, level, largeText: false)
                            verdict(contrast, level, largeText: true)
                        }
                    }
                }
            }
        } header: {
            Text(String(localized: "Contrast", table: "Editor"))
        }
    }

    private func slot(_ title: String, _ color: RGBA?, id: String) -> some View {
        LabeledContent(title) {
            if let color {
                HStack(spacing: DesignTokens.Space.s) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .fill(Color(cgColor: color.cgColor))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.control).stroke(.separator))
                        .frame(width: 18, height: 14)
                        .accessibilityHidden(true)
                    Text(verbatim: color.hex).monospaced().accessibilityIdentifier(id)
                }
            } else {
                Text(verbatim: "—").foregroundStyle(.secondary).accessibilityIdentifier(id)
            }
        }
    }

    /// A pass or fail mark that does not rely on color: the word and a distinct symbol.
    private func verdict(_ contrast: ContrastRatio, _ level: ContrastRatio.Level, largeText: Bool) -> some View {
        let passes = contrast.passes(level, largeText: largeText)
        return Label(
            passes ? String(localized: "Pass", table: "Editor") : String(localized: "Fail", table: "Editor"),
            systemImage: passes ? "checkmark.circle" : "xmark.circle"
        )
        .accessibilityIdentifier("color.contrast.\(level == .aa ? "aa" : "aaa").\(largeText ? "large" : "normal")")
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
            Text(String(localized: "Canvas Size", table: "Editor"))
        }
    }
}

private struct FramingDecorationSection: View {
    let model: EditorModel
    let coalescer: ChangeCoalescer
    @State private var expanded = false
    @State private var draft = ""
    @State private var refusedText = false

    var body: some View {
        let presentation = model.document.presentation
        Section {
            InspectorDisclosureButton(
                title: String(localized: "Output Decoration", table: "Editor"), expanded: $expanded
            )
            .accessibilityIdentifier("image.decoration")
            if expanded {
                decorationControls(presentation)
            }
        }
        .onChange(of: presentation.watermark?.text, initial: true) { _, current in
            draft = current ?? ""
            refusedText = false
        }
    }

    @ViewBuilder
    private func decorationControls(_ presentation: Presentation) -> some View {
        Toggle(
            String(localized: "Border", table: "Editor"),
            isOn: Binding(
                get: { presentation.border != nil },
                set: { model.setFramingBorder($0 ? Presentation.Border() : nil) })
        )
        .accessibilityIdentifier("image.decoration.border")
        if let border = presentation.border {
            UndoableSlider(
                title: String(localized: "Border width", table: "Editor"),
                value: border.width, range: Presentation.Border.widthRange, model: model
            ) { width in
                updateBorder { $0.width = width.rounded() }
            }
            ColorPicker(
                String(localized: "Border color", table: "Editor"),
                selection: colorBinding(
                    { border.color },
                    { color in coalescer.run(model) { updateBorder { $0.color = color } } }))
        }
        TextField(String(localized: "Watermark text", table: "Editor"), text: $draft)
            .accessibilityIdentifier("image.decoration.watermark")
            .onSubmit(applyWatermark)
            .onChange(of: draft) { refusedText = false }
        ButtonRow {
            Button(String(localized: "Apply Watermark", table: "Editor"), action: applyWatermark)
                .accessibilityIdentifier("image.decoration.applyWatermark")
            if presentation.watermark != nil {
                Button(String(localized: "Remove Watermark", table: "Editor")) {
                    model.setFramingWatermark(nil)
                }
            }
        }
        if refusedText {
            Text(String(localized: "Enter one line of watermark text up to 256 bytes.", table: "Editor"))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("image.decoration.textError")
        }
        if let watermark = presentation.watermark {
            watermarkControls(watermark)
        }
    }

    @ViewBuilder
    private func watermarkControls(_ watermark: Presentation.Watermark) -> some View {
        Picker(
            String(localized: "Watermark position", table: "Editor"),
            selection: Binding(
                get: { watermark.position }, set: { position in updateWatermark { $0.position = position } })
        ) {
            Text(String(localized: "Top Left", table: "Editor")).tag(Presentation.Watermark.Position.topLeft)
            Text(String(localized: "Top Right", table: "Editor")).tag(Presentation.Watermark.Position.topRight)
            Text(String(localized: "Center", table: "Editor")).tag(Presentation.Watermark.Position.center)
            Text(String(localized: "Bottom Left", table: "Editor")).tag(Presentation.Watermark.Position.bottomLeft)
            Text(String(localized: "Bottom Right", table: "Editor")).tag(Presentation.Watermark.Position.bottomRight)
        }
        UndoableSlider(
            title: String(localized: "Watermark opacity (%)", table: "Editor"),
            value: watermark.opacity * 100, range: 5...100, model: model
        ) { value in
            updateWatermark { $0.opacity = value / 100 }
        }
        UndoableSlider(
            title: String(localized: "Watermark rotation (°)", table: "Editor"),
            value: watermark.rotationDegrees, range: Presentation.Watermark.rotationRange, model: model
        ) { value in
            updateWatermark { $0.rotationDegrees = value.rounded() }
        }
    }

    private func applyWatermark() {
        var watermark = model.document.presentation.watermark ?? Presentation.Watermark(text: draft)
        watermark.text = draft
        refusedText = !model.setFramingWatermark(watermark)
    }

    private func updateBorder(_ edit: (inout Presentation.Border) -> Void) {
        guard var border = model.document.presentation.border else { return }
        edit(&border)
        model.setFramingBorder(border)
    }

    private func updateWatermark(_ edit: (inout Presentation.Watermark) -> Void) {
        guard var watermark = model.document.presentation.watermark else { return }
        edit(&watermark)
        model.setFramingWatermark(watermark)
    }
}

private struct BackgroundSection: View {
    let model: EditorModel
    let coalescer: ChangeCoalescer

    private enum BackgroundKind: Hashable { case plain, solid, gradient, radial }

    var body: some View {
        let presentation = model.document.presentation
        Section {
            Picker(
                String(localized: "Background", table: "Editor"),
                selection: Binding(get: { kind(presentation.background) }, set: { setKind($0, presentation) })
            ) {
                Text(String(localized: "None", table: "Editor")).tag(BackgroundKind.plain)
                Text(String(localized: "Color", table: "Editor")).tag(BackgroundKind.solid)
                Text(String(localized: "Gradient", table: "Editor")).tag(BackgroundKind.gradient)
                Text(String(localized: "Radial Gradient", table: "Editor")).tag(BackgroundKind.radial)
            }
            .accessibilityIdentifier("image.background")
            BackgroundSwatches(model: model, current: presentation.background)
            switch presentation.background {
            case .none:
                EmptyView()
            case .solid(let color):
                ColorPicker(
                    String(localized: "Background color", table: "Editor"),
                    selection: colorBinding(
                        { color }, { c in coalescer.run(model) { model.setBackground(.solid(c)) } }),
                    supportsOpacity: false)
            case .linearGradient(let from, let to, let angle):
                ColorPicker(
                    String(localized: "Start color", table: "Editor"),
                    selection: colorBinding(
                        { from },
                        { c in
                            coalescer.run(model) {
                                model.setBackground(.linearGradient(from: c, to: to, angleDegrees: angle))
                            }
                        }),
                    supportsOpacity: false)
                ColorPicker(
                    String(localized: "End color", table: "Editor"),
                    selection: colorBinding(
                        { to },
                        { c in
                            coalescer.run(model) {
                                model.setBackground(.linearGradient(from: from, to: c, angleDegrees: angle))
                            }
                        }),
                    supportsOpacity: false)
            case .radialGradient(let center, let edge):
                ColorPicker(
                    String(localized: "Center color", table: "Editor"),
                    selection: colorBinding(
                        { center },
                        { c in coalescer.run(model) { model.setBackground(.radialGradient(center: c, edge: edge)) } }
                    ),
                    supportsOpacity: false)
                ColorPicker(
                    String(localized: "Edge color", table: "Editor"),
                    selection: colorBinding(
                        { edge },
                        { c in coalescer.run(model) { model.setBackground(.radialGradient(center: center, edge: c)) } }
                    ),
                    supportsOpacity: false)
            }
            Picker(
                String(localized: "Aspect Ratio", table: "Editor"),
                selection: Binding(get: { presentation.aspect }, set: { model.setAspect($0) })
            ) {
                ForEach(FramingAspect.allCases, id: \.self) { aspect in
                    if let ratio = aspect.ratio {
                        Text(verbatim: "\(ratio.width):\(ratio.height)").tag(aspect)
                    } else {
                        Text(String(localized: "Free", table: "Editor")).tag(aspect)
                    }
                }
            }
            .accessibilityIdentifier("image.aspect")
            if presentation.aspect != .free {
                Toggle(
                    String(localized: "Balance", table: "Editor"),
                    isOn: Binding(get: { presentation.balancesContent }, set: { model.setBalancesContent($0) })
                )
                .accessibilityIdentifier("image.balance")
            }
            UndoableSlider(
                title: String(localized: "Padding", table: "Editor"), value: presentation.padding, range: 0...256,
                model: model
            ) { model.setPadding($0.rounded()) }
            UndoableSlider(
                title: String(localized: "Corner radius", table: "Editor"), value: presentation.cornerRadius,
                range: 0...128, model: model
            ) { model.setCornerRadius($0.rounded()) }
            Toggle(
                String(localized: "Shadow", table: "Editor"),
                isOn: Binding(
                    get: { presentation.shadow != nil },
                    set: { model.setShadow($0 ? Presentation.Shadow() : nil) }))
            Toggle(
                String(localized: "Show output preview", table: "Editor"),
                isOn: Binding(get: { model.showsOutputPreview }, set: { model.setShowsOutputPreview($0) })
            )
            .help(String(localized: "Show exactly what Copy and Save produce, including framing", table: "Editor"))
            ButtonRow {
                Button(String(localized: "Save as Default Framing", table: "Editor")) { model.saveDefaultFraming() }
                    .disabled(model.defaultFraming == presentation)
                    .accessibilityIdentifier("image.saveDefaultFraming")
                Button(String(localized: "Reset Default Framing", table: "Editor")) { model.resetDefaultFraming() }
                    .disabled(model.defaultFraming == nil)
                    .accessibilityIdentifier("image.resetDefaultFraming")
            }
            FramingRecipesControls(model: model)
        } header: {
            Text(String(localized: "Framing", table: "Editor"))
        }
    }

    private func kind(_ background: Presentation.Background) -> BackgroundKind {
        switch background {
        case .none: .plain
        case .solid: .solid
        case .linearGradient: .gradient
        case .radialGradient: .radial
        }
    }

    private func setKind(_ kind: BackgroundKind, _ presentation: Presentation) {
        switch kind {
        case .plain: model.setBackground(.none)
        // Neutral graphite defaults: they frame any screenshot without tinting it.
        case .solid: model.setBackground(.solid(RGBA(r: 72, g: 72, b: 74)))
        case .gradient:
            model.setBackground(
                .linearGradient(from: RGBA(r: 99, g: 99, b: 102), to: RGBA(r: 44, g: 44, b: 46), angleDegrees: 135))
        case .radial:
            model.setBackground(.radialGradient(center: RGBA(r: 99, g: 99, b: 102), edge: RGBA(r: 44, g: 44, b: 46)))
        }
    }
}

private struct FramingRecipesControls: View {
    let model: EditorModel

    @State private var selectedID: UUID?
    @State private var namingID: UUID?
    @State private var name = ""
    @State private var isNaming = false
    @State private var namingFailure: FramingRecipes.Failure?
    @State private var operationFailure: FramingRecipes.Failure?
    @FocusState private var nameFocused: Bool

    private var selected: FramingRecipe? { model.framingRecipes.first { $0.id == selectedID } }

    var body: some View {
        let recipe = selected
        if !model.framingRecipes.isEmpty {
            Picker(
                String(localized: "Framing Recipe", table: "Editor"),
                selection: Binding(get: { selected?.id }, set: { selectedID = $0 })
            ) {
                Text("Choose a Recipe", tableName: "Editor").tag(nil as UUID?)
                ForEach(model.framingRecipes) { recipe in
                    Text(verbatim: recipe.name).tag(Optional(recipe.id))
                }
            }
            .accessibilityIdentifier("image.framingRecipe")

            ButtonRow {
                Button(String(localized: "Apply Recipe", table: "Editor")) {
                    guard let recipe else { return }
                    perform { () throws(FramingRecipes.Failure) in try model.applyFramingRecipe(recipe.id) }
                }
                .accessibilityIdentifier("image.applyFramingRecipe")
                Button(String(localized: "Rename Recipe…", table: "Editor")) {
                    guard let recipe else { return }
                    startNaming(recipe)
                }
                .accessibilityIdentifier("image.renameFramingRecipe")
                Button(String(localized: "Delete Recipe", table: "Editor")) {
                    guard let recipe else { return }
                    perform { () throws(FramingRecipes.Failure) in
                        try model.removeFramingRecipe(recipe.id)
                        selectedID = nil
                    }
                }
                .accessibilityIdentifier("image.deleteFramingRecipe")
            }
            .disabled(recipe == nil)
        }
        Button(String(localized: "Save Framing Recipe…", table: "Editor")) { startNaming(nil) }
            .accessibilityIdentifier("image.saveFramingRecipe")
            .sheet(isPresented: $isNaming) { nameForm }
        if let operationFailure {
            Text(message(operationFailure))
                .foregroundStyle(.red)
        }
    }

    private var nameForm: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            TextField(String(localized: "Recipe Name", table: "Editor"), text: $name)
                .focused($nameFocused)
                .accessibilityIdentifier("framing.recipeName")
                .onChange(of: name) { _, _ in namingFailure = nil }
            if let namingFailure {
                Text(message(namingFailure))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("framing.recipeNameError")
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", table: "Editor"), role: .cancel) { isNaming = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", table: "Editor")) { saveName() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("framing.saveRecipeName")
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear { nameFocused = true }
    }

    private func startNaming(_ recipe: FramingRecipe?) {
        namingID = recipe?.id
        name = recipe?.name ?? ""
        namingFailure = nil
        operationFailure = nil
        isNaming = true
    }

    private func saveName() {
        do throws(FramingRecipes.Failure) {
            if let namingID {
                try model.renameFramingRecipe(namingID, to: name)
            } else {
                selectedID = try model.saveFramingRecipe(named: name)
            }
            isNaming = false
        } catch {
            namingFailure = error
        }
    }

    private func perform(_ action: () throws(FramingRecipes.Failure) -> Void) {
        do {
            try action()
            operationFailure = nil
        } catch {
            operationFailure = error
        }
    }

    private func message(_ failure: FramingRecipes.Failure) -> String {
        switch failure {
        case .invalidName: String(localized: "Enter a name with at most 64 bytes and no line breaks.", table: "Editor")
        case .duplicateName: String(localized: "A recipe already uses that name.", table: "Editor")
        case .limitReached: String(localized: "Delete a recipe before saving another.", table: "Editor")
        case .invalidFraming: String(localized: "This framing cannot be saved as a recipe.", table: "Editor")
        case .unavailable: String(localized: "This recipe is no longer available.", table: "Editor")
        }
    }
}

/// The built-in backgrounds as one row of swatches; pressing one applies it.
private struct BackgroundSwatches: View {
    let model: EditorModel
    let current: Presentation.Background

    private static let names = [
        String(localized: "White", table: "Editor"), String(localized: "Silver", table: "Editor"),
        String(localized: "Graphite", table: "Editor"), String(localized: "Black", table: "Editor"),
        String(localized: "Blue", table: "Editor"), String(localized: "Green", table: "Editor"),
        String(localized: "Graphite Gradient", table: "Editor"), String(localized: "Sky Gradient", table: "Editor"),
        String(localized: "Sunset Gradient", table: "Editor"),
        String(localized: "Silver Radial Gradient", table: "Editor"),
    ]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 20, maximum: 20), spacing: DesignTokens.Space.xs)],
            alignment: .leading, spacing: DesignTokens.Space.xs
        ) {
            ForEach(Array(Presentation.backgroundSwatches.enumerated()), id: \.offset) { index, background in
                let name = Self.names[index]
                let selected = background == current
                Button {
                    model.setBackground(background)
                } label: {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .fill(Self.fill(background))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.control).strokeBorder(.separator))
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.control).strokeBorder(
                                    .primary, lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("image.swatch.\(index)")
                .accessibilityLabel(name)
                .accessibilityValue(selected ? String(localized: "Selected", table: "Editor") : "")
                .help(name)
            }
        }
    }

    private static func color(_ rgba: RGBA) -> Color { Color(cgColor: rgba.cgColor) }

    private static func fill(_ background: Presentation.Background) -> AnyShapeStyle {
        switch background {
        case .none:
            return AnyShapeStyle(Color.clear)
        case .solid(let rgba):
            return AnyShapeStyle(color(rgba))
        case .linearGradient(let from, let to, let angle):
            // The renderer's direction: angle in degrees, y down, through the middle.
            let dx = cos(angle * .pi / 180) / 2, dy = sin(angle * .pi / 180) / 2
            return AnyShapeStyle(
                LinearGradient(
                    colors: [color(from), color(to)], startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                    endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)))
        case .radialGradient(let center, let edge):
            return AnyShapeStyle(
                RadialGradient(colors: [color(center), color(edge)], center: .center, startRadius: 0, endRadius: 11))
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
                String(localized: "Compare transparency", table: "Editor"),
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

/// Rotate and flip the whole image (A-10); the Image menu has the same commands.
private struct TransformSection: View {
    let model: EditorModel

    var body: some View {
        Section {
            HStack {
                ForEach(ImageTransform.allCases, id: \.self) { transform in
                    Button {
                        model.transformImage(transform)
                    } label: {
                        Label(transform.imageTitle, systemImage: transform.systemImage).labelStyle(.iconOnly)
                    }
                    .help(transform.imageTitle)
                    .accessibilityIdentifier("image.\(transform.identifier)")
                }
            }
            .disabled(!model.canTransformImage)
        } header: {
            Text(String(localized: "Rotate and Flip", table: "Editor"))
        }
    }
}

/// The selected image layer's rotate, flip and duplicate commands (A-10).
private struct LayerTransformRow: View {
    let model: EditorModel

    var body: some View {
        HStack {
            ForEach(ImageTransform.allCases, id: \.self) { transform in
                Button {
                    model.transformSelectedLayers(transform)
                } label: {
                    Label(transform.layerTitle, systemImage: transform.systemImage).labelStyle(.iconOnly)
                }
                .help(transform.layerTitle)
                .accessibilityIdentifier("layer.\(transform.identifier)")
                .disabled(!model.canTransformLayers)
            }
            Button(String(localized: "Duplicate", table: "Editor")) { model.duplicateSelection() }
                .accessibilityIdentifier("layer.duplicate")
                .disabled(!model.canArrangeSelection)
        }
    }
}

/// The crop tool's aspect preset (A-10).
private struct CropSection: View {
    let model: EditorModel

    var body: some View {
        Section {
            Picker(
                String(localized: "Aspect Ratio", table: "Editor"),
                selection: Binding(get: { model.cropAspect }, set: { model.setCropAspect($0) })
            ) {
                ForEach(CropAspect.allCases, id: \.self) { aspect in
                    Text(verbatim: aspect.title).tag(aspect)
                }
            }
            .accessibilityIdentifier("crop.aspect")
        }
    }
}

// MARK: - Text and QR recognition

private struct RecognitionSection: View {
    let model: EditorModel
    @Binding var mode: OCRTextMode?

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
                EditorNoticeLabel(
                    text: String(
                        localized: "QR contents are untrusted. Recortia never opens them on its own.", table: "Editor"),
                    systemImage: "exclamationmark.triangle")
                ForEach(Array(payloads.enumerated()), id: \.offset) { index, payload in
                    VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                        Text(EditorStrings.payloadKind(payload.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(payload.string ?? String(localized: "\(payload.bytes.count) bytes", table: "Editor"))
                            .lineLimit(3)
                            .textSelection(.enabled)
                        // The full link can be truncated above; the host it opens never is. The
                        // classifier admits only ASCII hosts, shown exactly as encoded.
                        if case .webURL(let url) = payload.kind, let host = url.host(percentEncoded: true) {
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
