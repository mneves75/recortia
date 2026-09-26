import AppKit
import Domain
import Features

/// The editor canvas (FR-04/05): draws the sanitized base and annotations in document space through
/// `EditorCanvasRenderer` (the export's annotation code), then view-space chrome: crop shade,
/// selection handles, live tool drafts, OCR boxes, ruler, and loupe. Pointer input is converted to
/// document space through the model's viewport before it reaches the model.
///
/// Text is edited in a native `NSTextView` overlay so input methods, accents, emoji, and
/// right-to-left text work, and single-key tool shortcuts never fire while it has focus.
final class EditorCanvasView: NSView, NSTextViewDelegate {
    let model: EditorModel
    weak var actions: (any EditorWindowActions)?

    private var loop: ObservationLoop?
    private var textView: EditorTextView?
    private var editingSnapshot: EditorTextEditing?
    private var isSpaceDown = false
    private var panAnchor: NSPoint?
    private var trackingArea: NSTrackingArea?
    private var elements: [EditorItemID: EditorAccessibilityElement] = [:]
    private var lastListItems: [EditorListItem] = []

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Canvas", table: "Editor"))
        setAccessibilityHelp(
            String(
                localized:
                    "Use the object list to select objects. Arrow keys move the selection; Shift moves it 10 pixels.",
                table: "Editor"))
        loop = ObservationLoop { [weak self] in self?.modelChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - Model observation

    private func modelChanged() {
        // Reading these registers them with the observation loop.
        _ = model.document
        _ = model.baseImage
        _ = model.selection
        _ = model.draft
        _ = model.viewport
        _ = model.inspection
        _ = model.ruler
        _ = model.recognition
        _ = model.outputPreview
        _ = model.showsOutputPreview
        _ = model.redactionFill
        let tool = model.tool
        syncTextEditing(model.textEditing)
        needsDisplay = true
        _ = tool
        window?.invalidateCursorRects(for: self)
        let items = model.listItems
        if items != lastListItems {
            lastListItems = items
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportViewport()
    }

    private func reportViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        model.setViewportSize(
            Size(width: bounds.width, height: bounds.height), backingScale: Double(window?.backingScaleFactor ?? 2))
        positionTextView()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Drawing

    private var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Neutral, opaque ground: never a translucent window material (FR-13).
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let viewport = model.viewport
        let document = model.document
        var shownRect = document.canvasRect
        if model.showsOutputPreview {
            let padding = document.presentation.padding
            shownRect = document.contentRect.insetBy(dx: -padding, dy: -padding)
        }
        let canvas = viewport.viewRect(shownRect).cg
        drawCheckerboard(in: canvas, context)

        context.saveGState()
        context.translateBy(x: viewport.offset.x, y: viewport.offset.y)
        context.scaleBy(x: viewport.zoom, y: viewport.zoom)
        if model.showsOutputPreview {
            if let output = model.outputPreview {
                context.interpolationQuality = model.zoomPercent >= 100 ? .none : .high
                Self.drawUpright(output, in: shownRect.cg, context)
            }
        } else {
            var drawn = document
            if let editing = model.textEditing?.annotationID {
                drawn.annotations.removeAll { $0.id == editing }
            }
            var draftAnnotation: Annotation?
            if case .annotation(let annotation) = model.draft { draftAnnotation = annotation }
            EditorCanvasRenderer.draw(
                drawn, base: model.baseImage, calloutBase: model.calloutBaseImage, draft: draftAnnotation,
                baseInterpolation: model.zoomPercent >= 100 ? .none : .high, in: context)
        }
        context.restoreGState()

        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: canvas.insetBy(dx: -0.5, dy: -0.5)).stroke()

        if !model.showsOutputPreview {
            drawCropShade(document, viewport, context)
            drawRecognizedBoxes(viewport)
            drawSelection(viewport)
            drawDraft(viewport)
            drawRuler(viewport)
            drawLoupe(viewport)
        }
    }

    private func drawCheckerboard(in rect: CGRect, _ context: CGContext) {
        let visible = rect.intersection(bounds)
        guard !visible.isNull else { return }
        context.saveGState()
        context.clip(to: visible)
        NSColor(white: 0.93, alpha: 1).setFill()
        visible.fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        let size: CGFloat = 8
        var y = (visible.minY / size).rounded(.down) * size
        while y < visible.maxY {
            var x = (visible.minX / size).rounded(.down) * size
            while x < visible.maxX {
                if Int((x / size).rounded() + (y / size).rounded()).isMultiple(of: 2) {
                    CGRect(x: x, y: y, width: size, height: size).fill()
                }
                x += size
            }
            y += size
        }
        context.restoreGState()
    }

    static func drawUpright(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private func drawCropShade(_ document: Document, _ viewport: EditorViewport, _ context: CGContext) {
        guard document.crop != nil else { return }
        let canvas = viewport.viewRect(document.canvasRect).cg
        let content = viewport.viewRect(document.contentRect).cg
        context.saveGState()
        context.addRect(canvas)
        context.addRect(content)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
        strokeDashed(content, color: .white)
    }

    private func drawRecognizedBoxes(_ viewport: EditorViewport) {
        guard case .recognized(let lines, _) = model.recognition else { return }
        for line in lines {
            strokeDashed(viewport.viewRect(line.box).cg, color: .controlAccentColor)
        }
    }

    private func drawSelection(_ viewport: EditorViewport) {
        let width: CGFloat = increaseContrast ? 2 : 1
        for item in model.selection {
            guard let frame = model.frame(of: item) else { continue }
            let rect = viewport.viewRect(frame).cg.insetBy(dx: -2, dy: -2)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = width + 2
            NSColor.white.setStroke()
            path.stroke()
            path.lineWidth = width
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        for handle in model.selectionHandles {
            let center = viewport.viewPoint(handle.point)
            let size: CGFloat = increaseContrast ? 10 : 8
            let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            let path =
                handle.handle == .start || handle.handle == .end ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            NSColor.white.setFill()
            path.fill()
            path.lineWidth = width
            (increaseContrast ? NSColor.black : NSColor.controlAccentColor).setStroke()
            path.stroke()
        }
    }

    private func drawDraft(_ viewport: EditorViewport) {
        switch model.draft {
        case .region(let tool, let rect):
            let view = viewport.viewRect(rect).cg
            if tool == .redact {
                let fill = model.redactionFill
                NSColor(
                    srgbRed: CGFloat(fill.r) / 255, green: CGFloat(fill.g) / 255, blue: CGFloat(fill.b) / 255, alpha: 1
                ).setFill()
                view.fill()
            }
            strokeDashed(view, color: .controlAccentColor)
            drawLabel(EditorStrings.name(tool), at: CGPoint(x: view.minX, y: view.maxY + 4))
        case .marquee(let rect):
            strokeDashed(viewport.viewRect(rect).cg, color: .controlAccentColor)
        case .annotation, nil:
            break
        }
    }

    private func drawRuler(_ viewport: EditorViewport) {
        guard let ruler = model.ruler, model.tool == .ruler else { return }
        let a = viewport.viewPoint(ruler.start), b = viewport.viewPoint(ruler.end)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: a.x, y: a.y))
        path.line(to: CGPoint(x: b.x, y: b.y))
        path.lineWidth = 3
        NSColor.white.setStroke()
        path.stroke()
        path.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        for p in [a, b] {
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            NSColor.controlAccentColor.setFill()
            dot.fill()
        }
        drawLabel(EditorFormat.measurement(ruler), at: CGPoint(x: (a.x + b.x) / 2 + 8, y: (a.y + b.y) / 2 + 8))
    }

    private func drawLoupe(_ viewport: EditorViewport) {
        guard model.tool == .loupe, let loupe = model.loupe(radius: 7),
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        let cell: CGFloat = 8
        let side = CGFloat(15) * cell
        let pixel = viewport.viewPoint(Point(x: Double(loupe.centerX) + 1, y: Double(loupe.centerY) + 1))
        var origin = CGPoint(x: pixel.x + 16, y: pixel.y + 16)
        if origin.x + side > bounds.maxX { origin.x = pixel.x - 16 - side }
        if origin.y + side + 22 > bounds.maxY { origin.y = pixel.y - 16 - side - 22 }
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        NSColor.windowBackgroundColor.setFill()
        frame.insetBy(dx: -2, dy: -2).fill()
        // The crop may be clamped at an image edge: place it relative to the inspected pixel.
        let imageRect = CGRect(
            x: frame.minX + CGFloat(loupe.originX - (loupe.centerX - 7)) * cell,
            y: frame.minY + CGFloat(loupe.originY - (loupe.centerY - 7)) * cell,
            width: CGFloat(loupe.image.width) * cell, height: CGFloat(loupe.image.height) * cell)
        context.saveGState()
        context.clip(to: frame)
        context.interpolationQuality = .none
        Self.drawUpright(loupe.image, in: imageRect, context)
        context.restoreGState()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        for i in 0...15 {
            let offset = CGFloat(i) * cell
            NSBezierPath.strokeLine(
                from: CGPoint(x: frame.minX + offset, y: frame.minY), to: CGPoint(x: frame.minX + offset, y: frame.maxY)
            )
            NSBezierPath.strokeLine(
                from: CGPoint(x: frame.minX, y: frame.minY + offset), to: CGPoint(x: frame.maxX, y: frame.minY + offset)
            )
        }
        let center = CGRect(x: frame.minX + 7 * cell, y: frame.minY + 7 * cell, width: cell, height: cell)
        let marker = NSBezierPath(rect: center)
        marker.lineWidth = 2
        NSColor.white.setStroke()
        marker.stroke()
        marker.lineWidth = 1
        NSColor.black.setStroke()
        marker.stroke()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: frame).stroke()
        if let sample = model.inspection {
            drawLabel(
                String(localized: "\(sample.x), \(sample.y)  \(sample.hex)", table: "Editor"),
                at: CGPoint(x: frame.minX, y: frame.maxY + 4))
        }
    }

    private func strokeDashed(_ rect: CGRect, color: NSColor) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = increaseContrast ? 2 : 1
        NSColor.white.setStroke()
        path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = point
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - size.width - 12)
        origin.y = min(max(origin.y, bounds.minY + 4), bounds.maxY - size.height - 8)
        let background = CGRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4)
        NSColor.windowBackgroundColor.withAlphaComponent(increaseContrast ? 1 : 0.92).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).stroke()
        string.draw(at: origin)
    }

    // MARK: - Pointer

    private func documentPoint(_ event: NSEvent) -> Point<DocumentSpace> {
        let p = convert(event.locationInWindow, from: nil)
        return model.viewport.documentPoint(Point(x: p.x, y: p.y))
    }

    private func modifiers(_ event: NSEvent) -> EditorModifiers {
        var result: EditorModifiers = []
        if event.modifierFlags.contains(.shift) { result.insert(.shift) }
        if event.modifierFlags.contains(.option) { result.insert(.option) }
        if event.modifierFlags.contains(.command) { result.insert(.command) }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        finishTextEditing(commit: true)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if isSpaceDown || model.tool == .hand {
            panAnchor = p
            NSCursor.closedHand.set()
            return
        }
        let point = documentPoint(event)
        if event.clickCount == 2, model.tool == .select, let item = model.item(at: point),
            case .annotation(let id) = item, model.kind(of: item) == .text
        {
            model.beginEditingText(id)
            return
        }
        model.pointerDown(at: point, modifiers: modifiers(event))
    }

    override func mouseDragged(with event: NSEvent) {
        if let anchor = panAnchor {
            let p = convert(event.locationInWindow, from: nil)
            model.pan(dx: p.x - anchor.x, dy: p.y - anchor.y)
            panAnchor = p
            return
        }
        model.pointerDragged(to: documentPoint(event), modifiers: modifiers(event))
    }

    override func mouseUp(with event: NSEvent) {
        if panAnchor != nil {
            panAnchor = nil
            cursor().set()
            return
        }
        model.pointerUp(at: documentPoint(event), modifiers: modifiers(event))
    }

    override func mouseMoved(with event: NSEvent) {
        model.pointerMoved(to: documentPoint(event))
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.command) {
            let factor = exp(Double(event.scrollingDeltaY * scale) * 0.01)
            model.setZoom(model.viewport.zoom * factor, anchor: Point(x: p.x, y: p.y))
        } else {
            model.pan(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale)
        }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        model.setZoom(model.viewport.zoom * (1 + event.magnification), anchor: Point(x: p.x, y: p.y))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = documentPoint(event)
        if let item = model.item(at: point), !model.selection.contains(item) { model.select(item) }
        guard !model.selection.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(
            ClosureMenuItem.make(String(localized: "Duplicate", table: "Editor")) { [weak self] in
                self?.model.duplicateSelection()
            })
        menu.addItem(
            ClosureMenuItem.make(String(localized: "Delete", table: "Editor")) { [weak self] in
                self?.model.deleteSelection()
            })
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem.make(String(localized: "Bring to Front", table: "Editor")) { [weak self] in
                self?.model.reorderSelection(.front)
            })
        menu.addItem(
            ClosureMenuItem.make(String(localized: "Send to Back", table: "Editor")) { [weak self] in
                self?.model.reorderSelection(.back)
            })
        return menu
    }

    // MARK: - Cursor

    private func cursor() -> NSCursor {
        if isSpaceDown || model.tool == .hand { return .openHand }
        switch model.tool {
        case .select: return .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: cursor())
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor().set()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 49:  // Space: hold to pan
            if !isSpaceDown {
                isSpaceDown = true
                cursor().set()
            }
            return
        case 51, 117:  // Delete, Forward Delete
            model.deleteSelection()
            return
        case 123, 124, 125, 126:  // Arrow keys: nudge 1 px, Shift 10 px
            let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            let dx = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            model.nudgeSelection(dx: dx, dy: dy)
            return
        case 53:  // Escape
            if model.draft != nil {
                model.cancelGesture()
            } else if !model.selection.isEmpty {
                model.clearSelection()
            } else {
                model.selectTool(.select)
            }
            return
        case 36, 76:  // Return, Enter: edit the selected text
            if model.selection.count == 1, let item = model.selection.first, case .annotation(let id) = item,
                model.kind(of: item) == .text
            {
                model.beginEditingText(id)
                return
            }
        default:
            break
        }
        if flags.isEmpty, let characters = event.charactersIgnoringModifiers, characters.count == 1,
            let key = characters.first, let tool = EditorTool.forShortcut(key)
        {
            model.selectTool(tool)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceDown = false
            cursor().set()
            return
        }
        super.keyUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
            event.modifierFlags.intersection([.command, .control, .option]) == .command,
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case "z" where shift: model.redo()
        case "z": model.undo()
        case "d": model.duplicateSelection()
        case "a": model.selectAll()
        case "0": model.zoomToFit()
        case "1": model.zoomToActualPixels()
        case "=", "+": model.zoomIn()
        case "-": model.zoomOut()
        case "c": actions?.copyImage()
        case "s": actions?.saveImage()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: - Text editing

    private func syncTextEditing(_ editing: EditorTextEditing?) {
        guard let editing else {
            if let textView {
                self.textView = nil
                editingSnapshot = nil
                textView.removeFromSuperview()
            }
            return
        }
        if textView == nil || editingSnapshot != editing {
            textView?.removeFromSuperview()
            let view = EditorTextView(frame: .zero)
            view.delegate = self
            view.string = editing.initialString
            view.isRichText = false
            view.allowsUndo = true
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.isHorizontallyResizable = true
            view.isVerticallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.focusRingType = .exterior
            view.setAccessibilityLabel(String(localized: "Text annotation", table: "Editor"))
            view.onFinish = { [weak self] in self?.finishTextEditing(commit: true) }
            addSubview(view)
            textView = view
            editingSnapshot = editing
            positionTextView()
            window?.makeFirstResponder(view)
            view.selectAll(nil)
        } else {
            positionTextView()
        }
    }

    private func positionTextView() {
        guard let textView, let editing = editingSnapshot else { return }
        let viewport = model.viewport
        let zoom = viewport.zoom
        let color = editing.color
        textView.font = NSFont.systemFont(ofSize: max(1, editing.fontSize * zoom))
        textView.textColor = NSColor(
            srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
        textView.insertionPointColor = .labelColor
        let origin = viewport.viewPoint(editing.origin)
        textView.minSize = NSSize(width: max(24, editing.fontSize * zoom), height: editing.fontSize * zoom * 1.3)
        textView.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        textView.sizeToFit()
    }

    func textDidChange(_ notification: Notification) {
        textView?.sizeToFit()
    }

    func textDidEndEditing(_ notification: Notification) {
        finishTextEditing(commit: true)
    }

    /// Commits (or cancels) the text being edited. Safe to call when nothing is being edited.
    func finishTextEditing(commit: Bool) {
        guard let textView else { return }
        let string = textView.string
        self.textView = nil
        editingSnapshot = nil
        textView.removeFromSuperview()
        if commit { model.commitTextEditing(string) } else { model.cancelTextEditing() }
        window?.makeFirstResponder(self)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityChildren() -> [Any]? {
        let viewport = model.viewport
        var current: [EditorItemID: EditorAccessibilityElement] = [:]
        var result: [Any] = []
        for item in model.listItems {
            let id = item.id
            let element =
                elements[id]
                ?? EditorAccessibilityElement { [weak self] in
                    self?.model.select(id)
                }
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.image)
            element.setAccessibilityRoleDescription(String(localized: "canvas object", table: "Editor"))
            var label = EditorStrings.label(item)
            if let badge = EditorStrings.securityBadge(item.kind) { label += ", " + badge }
            element.setAccessibilityLabel(label)
            element.setAccessibilityValue(EditorFormat.frame(item.frame))
            element.setAccessibilitySelected(model.selection.contains(item.id))
            element.setAccessibilityFrameInParentSpace(viewport.viewRect(item.frame).cg)
            current[id] = element
            result.append(element)
        }
        elements = current
        if let textView { result.append(textView) }
        return result
    }
}

/// An accessibility element for one canvas object; pressing it selects the object.
/// `NSAccessibilityElement` is not main-actor isolated, so this subclass is `nonisolated`;
/// AppKit delivers accessibility actions on the main thread, which `assumeIsolated` checks.
nonisolated final class EditorAccessibilityElement: NSAccessibilityElement {
    private let onPress: @MainActor @Sendable () -> Void

    init(onPress: @escaping @MainActor @Sendable () -> Void) {
        self.onPress = onPress
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        let press = onPress
        MainActor.assumeIsolated { press() }
        return true
    }
}

/// The text overlay. Handles the standard editing key equivalents itself so they work whether
/// or not a main menu provides them, and ends editing on Escape or ⌘Return.
final class EditorTextView: NSTextView {
    var onFinish: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
            event.modifierFlags.intersection([.command, .control, .option]) == .command,
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        switch key {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "a": selectAll(nil)
        case "z" where shift: undoManager?.redo()
        case "z": undoManager?.undo()
        case "\r": onFinish?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?()
    }
}

/// Builds a menu item that runs a closure. The item keeps its target alive through
/// `representedObject` (the `target` reference itself is weak).
enum ClosureMenuItem {
    private final class Target: NSObject {
        let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func run() { handler() }
    }

    static func make(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let target = Target(handler)
        let item = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}

extension Rect {
    var cg: CGRect { CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height) }
}
