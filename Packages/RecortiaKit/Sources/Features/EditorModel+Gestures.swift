import Domain
import Foundation

// Pointer gestures, text editing, and viewport commands. Every pointer location is already in
// document space. One gesture (down … up) is at most one undo step: creation tools commit once on
// release, and move/resize run inside a session group (EDIT-01).
extension EditorModel {
    /// Drags shorter than this many view points count as clicks.
    static let clickSlop = 3.0

    public func pointerDown(at p: Point<DocumentSpace>, modifiers: EditorModifiers = []) {
        guard !isClosed, textEditing == nil, p.isFinite else { return }
        endContinuousChange()
        cancelGesture()
        switch tool {
        case .hand:
            break
        case .select:
            beginSelectGesture(at: p, modifiers: modifiers)
        case .text:
            if let item = item(at: p), case .annotation(let id) = item,
                let annotation = document.annotations.first(where: { $0.id == id }), case .text = annotation.kind
            {
                beginEditingText(id)
            } else {
                beginNewText(at: p)
            }
        case .step:
            let step = Annotation(
                kind: .step(center: p, number: document.annotations.nextStepNumber), style: style.annotationStyle)
            // Placing a step and dragging it into position is one gesture and one undo step.
            session.beginGroup("Step")
            if edit("Step", { $0.annotations.append(step) }) {
                selection = [.annotation(step.id)]
                gesture = .move(items: [.annotation(step.id)], start: p, original: session.document)
            } else {
                session.endGroup()
                releaseUnreachableAssets()
                noteUndoEvictionIfNeeded()
            }
        case .loupe:
            inspect(at: p)
            gesture = .sample
        case .colorPicker:
            pickColor(at: p)
            gesture = .sample
        case .ruler:
            let anchor = Self.snapped(p)
            ruler = measurement(from: anchor, to: anchor)
            gesture = .ruler(start: anchor)
        case .crop, .arrow, .rectangle, .ellipse, .freehand, .highlighter, .redact, .blur, .pixelate, .spotlight,
            .magnifier:
            gesture = .create(tool: tool, start: p, points: [p])
            updateDraft(tool: tool, start: p, points: [p], current: p, modifiers: modifiers)
        }
    }

    public func pointerDragged(to p: Point<DocumentSpace>, modifiers: EditorModifiers = []) {
        guard !isClosed, p.isFinite else { return }
        switch gesture {
        case .idle:
            break
        case .create(let tool, let start, var points):
            if tool == .freehand || tool == .highlighter {
                if let last = points.last, hypot(last.x - p.x, last.y - p.y) >= viewport.documentLength(0.5) {
                    points.append(p)
                }
                gesture = .create(tool: tool, start: start, points: points)
            }
            updateDraft(tool: tool, start: start, points: points, current: p, modifiers: modifiers)
        case .move(let items, let start, let original):
            var dx = p.x - start.x, dy = p.y - start.y
            if modifiers.contains(.shift) {
                if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
            }
            var moved = original
            do {
                try Self.translate(&moved, items: items, dx: dx, dy: dy)
            } catch {
                return
            }
            replaceDocumentInGesture("Move", with: moved)
        case .resize(let item, let handle, let frame, let original):
            var resized = original
            do {
                try resize(&resized, item: item, handle: handle, frame: frame, to: p, modifiers: modifiers)
            } catch {
                return
            }
            replaceDocumentInGesture("Resize", with: resized)
        case .marquee(let start, let initial):
            let rect = Rect<DocumentSpace>(spanning: start, p)
            draft = .marquee(rect)
            let hits = listItems.filter { $0.frame.intersects(rect) }.map(\.id)
            selection = initial.union(hits)
        case .ruler(let start):
            ruler = measurement(from: start, to: Self.snapped(p))
        case .sample:
            if tool == .loupe { inspect(at: p) } else if tool == .colorPicker { pickColor(at: p) }
        }
    }

    public func pointerUp(at p: Point<DocumentSpace>, modifiers: EditorModifiers = []) {
        guard !isClosed else { return }
        if p.isFinite { pointerDragged(to: p, modifiers: modifiers) }
        let finished = gesture
        gesture = .idle
        draft = nil
        switch finished {
        case .create(let tool, let start, let points):
            commitCreation(tool: tool, start: start, points: points, end: p.isFinite ? p : start, modifiers: modifiers)
        case .move, .resize:
            session.endGroup()
            releaseUnreachableAssets()
            noteUndoEvictionIfNeeded()
        case .idle, .marquee, .ruler, .sample:
            break
        }
    }

    /// Hover (no button): drives the loupe.
    public func pointerMoved(to p: Point<DocumentSpace>) {
        guard !isClosed, p.isFinite, tool == .loupe, case .idle = gesture else { return }
        inspect(at: p)
    }

    /// Abandons the current gesture: creation drafts vanish, and a move or resize is undone.
    public func cancelGesture() {
        let current = gesture
        gesture = .idle
        draft = nil
        switch current {
        case .move, .resize:
            let before = session.document, epoch = session.privacyEpoch
            session.cancelGroup()
            noteUndoEvictionIfNeeded()
            didChange(from: before, epoch: epoch)
        default:
            break
        }
    }

    // MARK: Select tool

    private func beginSelectGesture(at p: Point<DocumentSpace>, modifiers: EditorModifiers) {
        if let handle = handle(at: p), let item = selection.first, let frame = frame(of: item) {
            session.beginGroup("Resize")
            gesture = .resize(item: item, handle: handle, frame: frame, original: document)
            return
        }
        if let hit = item(at: p) {
            if modifiers.contains(.shift) {
                select(hit, extending: true)
                guard selection.contains(hit) else { return }
            } else if !selection.contains(hit) {
                selection = [hit]
            }
            session.beginGroup("Move")
            gesture = .move(items: orderedSelection, start: p, original: document)
            return
        }
        let initial = modifiers.contains(.shift) ? selection : []
        selection = initial
        gesture = .marquee(start: p, initial: initial)
    }

    private func replaceDocumentInGesture(_ label: String, with updated: Document) {
        let before = session.document, epoch = session.privacyEpoch
        do {
            try session.perform(label) { $0 = updated }
        } catch {
            return
        }
        didChange(from: before, epoch: epoch)
    }

    private func resize(
        _ document: inout Document, item: EditorItemID, handle: EditorHandle, frame: Rect<DocumentSpace>,
        to p: Point<DocumentSpace>, modifiers: EditorModifiers
    ) throws {
        if case .annotation(let id) = item, handle == .start || handle == .end,
            let index = document.annotations.firstIndex(where: { $0.id == id }),
            case .arrow(let start, let end) = document.annotations[index].kind
        {
            document.annotations[index].kind =
                handle == .start ? .arrow(start: p, end: end) : .arrow(start: start, end: p)
            return
        }
        var keepAspect = modifiers.contains(.shift)
        switch item {
        case .layer: keepAspect = true
        case .annotation(let id):
            if let annotation = document.annotations.first(where: { $0.id == id }), case .text = annotation.kind {
                keepAspect = true
            }
        default: break
        }
        let rect = EditorGeometry.resize(
            frame, handle: handle, to: p, keepAspect: keepAspect, minimum: viewport.documentLength(4))
        try Self.setFrame(&document, item: item, to: rect)
    }

    // MARK: Creation

    private func updateDraft(
        tool: EditorTool, start: Point<DocumentSpace>, points: [Point<DocumentSpace>], current: Point<DocumentSpace>,
        modifiers: EditorModifiers
    ) {
        switch tool {
        case .arrow:
            draft = .annotation(
                Annotation(
                    kind: .arrow(start: start, end: Self.constrainedEnd(start, current, modifiers)),
                    style: style.annotationStyle))
        case .rectangle:
            draft = .annotation(
                Annotation(
                    kind: .rectangle(
                        EditorGeometry.constrainedRect(from: start, to: current, square: modifiers.contains(.shift))),
                    style: style.annotationStyle))
        case .ellipse:
            draft = .annotation(
                Annotation(
                    kind: .ellipse(
                        EditorGeometry.constrainedRect(from: start, to: current, square: modifiers.contains(.shift))),
                    style: style.annotationStyle))
        case .freehand:
            draft = .annotation(Annotation(kind: .freehand(points), style: style.annotationStyle))
        case .highlighter:
            draft = .annotation(Annotation(kind: .highlighter(points), style: style.highlighterStyle))
        case .crop, .redact, .blur, .pixelate, .spotlight, .magnifier:
            draft = .region(
                tool, EditorGeometry.constrainedRect(from: start, to: current, square: modifiers.contains(.shift)))
        default:
            draft = nil
        }
    }

    static func constrainedEnd(_ start: Point<DocumentSpace>, _ end: Point<DocumentSpace>, _ modifiers: EditorModifiers)
        -> Point<DocumentSpace>
    {
        guard modifiers.contains(.shift) else { return end }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return Point(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private func commitCreation(
        tool: EditorTool, start: Point<DocumentSpace>, points: [Point<DocumentSpace>], end: Point<DocumentSpace>,
        modifiers: EditorModifiers
    ) {
        let slop = viewport.documentLength(Self.clickSlop)
        let square = modifiers.contains(.shift)
        let rect = EditorGeometry.constrainedRect(from: start, to: end, square: square)
        let isClick = rect.width < slop && rect.height < slop
        var created: EditorItemID?
        switch tool {
        case .arrow:
            let tip = Self.constrainedEnd(start, end, modifiers)
            guard hypot(tip.x - start.x, tip.y - start.y) >= slop else { return }
            let arrow = Annotation(kind: .arrow(start: start, end: tip), style: style.annotationStyle)
            if edit("Arrow", { $0.annotations.append(arrow) }) { created = .annotation(arrow.id) }
        case .rectangle, .ellipse:
            guard !isClick else { return }
            let shape = Annotation(
                kind: tool == .rectangle ? .rectangle(rect) : .ellipse(rect), style: style.annotationStyle)
            if edit(tool == .rectangle ? "Rectangle" : "Ellipse", { $0.annotations.append(shape) }) {
                created = .annotation(shape.id)
            }
        case .freehand, .highlighter:
            guard points.count >= 2 else { return }
            let stroke =
                tool == .freehand
                ? Annotation(kind: .freehand(points), style: style.annotationStyle)
                : Annotation(kind: .highlighter(points), style: style.highlighterStyle)
            if edit(tool == .freehand ? "Draw" : "Highlight", { $0.annotations.append(stroke) }) {
                created = .annotation(stroke.id)
            }
        case .crop:
            guard !isClick else { return }
            setCrop(rect)
        case .redact:
            guard !isClick, let area = rect.intersection(document.canvasRect) else { return }
            created = addRedaction(covering: area)
        case .blur, .pixelate:
            guard !isClick, let area = rect.intersection(document.canvasRect) else { return }
            let effect = CosmeticObfuscation(
                rect: area,
                style: tool == .blur
                    ? .blur(radius: Self.defaultBlurRadius) : .pixelate(blockSize: Self.defaultPixelBlock))
            if edit(tool == .blur ? "Blur" : "Pixelate", { $0.obfuscations.append(effect) }) {
                created = .obfuscation(effect.id)
            }
        case .spotlight:
            guard !isClick, let area = rect.intersection(document.canvasRect) else { return }
            let callout = Callout(kind: .spotlight(area, dimOpacity: Self.defaultSpotlightDim))
            if edit("Spotlight", { $0.callouts.append(callout) }) { created = .callout(callout.id) }
        case .magnifier:
            guard !isClick, let area = rect.intersection(document.canvasRect) else { return }
            let callout = Callout(kind: .magnifier(source: area, destination: magnifierDestination(for: area)))
            if edit("Magnifier", { $0.callouts.append(callout) }) { created = .callout(callout.id) }
        default:
            return
        }
        if let created { selection = [created] }
    }

    public static let defaultBlurRadius = 12.0
    public static let defaultPixelBlock = 12.0
    public static let defaultSpotlightDim = 0.55
    public static let magnification = 2.0

    /// Adds a secure, opaque redaction bound to the covered source pixels (FR-06).
    @discardableResult
    func addRedaction(covering rect: Rect<DocumentSpace>) -> EditorItemID? {
        let snapped = EditorGeometry.outwardIntegral(rect)
        guard !isClosed, let area = snapped.intersection(document.canvasRect) else { return nil }
        let before = document, epoch = session.privacyEpoch
        do {
            let id = try session.addSecureMask(covering: area, fill: redactionFill)
            didChange(from: before, epoch: epoch)
            return .mask(id)
        } catch {
            post(.redactionRefused)
            return nil
        }
    }

    /// A magnified copy of `source` next to it, kept inside the canvas where possible.
    func magnifierDestination(for source: Rect<DocumentSpace>) -> Rect<DocumentSpace> {
        let canvas = document.canvasRect
        let width = min(source.width * Self.magnification, canvas.width)
        let height = min(source.height * Self.magnification, canvas.height)
        var x = source.maxX + 16
        if x + width > canvas.maxX { x = source.minX - 16 - width }
        x = min(max(x, canvas.minX), max(canvas.minX, canvas.maxX - width))
        let y = min(max(source.midY - height / 2, canvas.minY), max(canvas.minY, canvas.maxY - height))
        return Rect(x: x, y: y, width: width, height: height)
    }

    // MARK: Text

    private func beginNewText(at p: Point<DocumentSpace>) {
        textEditing = EditorTextEditing(
            annotationID: nil, origin: p, initialString: "", fontSize: style.fontSize, color: style.stroke,
            maxWidth: nil)
    }

    /// Starts editing an existing text annotation (double-click, Return on a selected text).
    public func beginEditingText(_ id: AnnotationID) {
        guard !isClosed, let annotation = document.annotations.first(where: { $0.id == id }),
            case .text(let text) = annotation.kind
        else { return }
        cancelGesture()
        selection = [.annotation(id)]
        textEditing = EditorTextEditing(
            annotationID: id, origin: text.origin, initialString: text.string, fontSize: text.fontSize,
            color: annotation.style.stroke, maxWidth: text.maxWidth)
    }

    /// Ends text editing with the text view's final string: one undo step. An empty new text adds
    /// nothing; emptying an existing text deletes it.
    public func commitTextEditing(_ string: String) {
        guard let editing = textEditing else { return }
        textEditing = nil
        let isBlank = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let id = editing.annotationID {
            if isBlank {
                edit("Delete Text") { $0.annotations.removeAll { $0.id == id } }
                return
            }
            edit("Edit Text") { document in
                guard let index = document.annotations.firstIndex(where: { $0.id == id }),
                    case .text(var text) = document.annotations[index].kind
                else { return }
                text.string = string
                document.annotations[index].kind = .text(text)
            }
            return
        }
        guard !isBlank else { return }
        let text = Annotation(
            kind: .text(Annotation.TextContent(origin: editing.origin, string: string, fontSize: editing.fontSize)),
            style: style.annotationStyle)
        if edit("Text", { $0.annotations.append(text) }) { selection = [.annotation(text.id)] }
    }

    public func cancelTextEditing() { textEditing = nil }

    // MARK: Viewport

    /// Called by the canvas on layout; the first call fits the document.
    public func setViewportSize(_ size: Size<ViewSpace>, backingScale: Double) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        viewportSize = size
        if backingScale.isFinite, backingScale > 0 { self.backingScale = backingScale }
        if !hasFittedViewport {
            hasFittedViewport = true
            zoomToFit()
        }
    }

    public func setViewport(_ viewport: EditorViewport) { self.viewport = viewport }

    /// Zoom where 100 % shows one document pixel per device pixel.
    public var zoomPercent: Double { viewport.zoom * backingScale * 100 }

    public func zoomToFit() {
        guard viewportSize.width > 0 else { return }
        viewport = .fitting(document.canvasRect, in: viewportSize, maxZoom: 1 / backingScale)
    }

    public func zoomToActualPixels() {
        guard viewportSize.width > 0 else { return }
        viewport = .centered(on: document.contentRect, in: viewportSize, zoom: 1 / backingScale)
    }

    public func zoomIn(anchor: Point<ViewSpace>? = nil) { setZoom(viewport.nextZoomIn(), anchor: anchor) }

    public func zoomOut(anchor: Point<ViewSpace>? = nil) { setZoom(viewport.nextZoomOut(), anchor: anchor) }

    public func setZoom(_ zoom: Double, anchor: Point<ViewSpace>? = nil) {
        let center = anchor ?? Point(x: viewportSize.width / 2, y: viewportSize.height / 2)
        viewport.setZoom(zoom, anchor: center)
    }

    public func zoomToSelection() {
        let frames = selection.compactMap(frame(of:))
        guard viewportSize.width > 0, let first = frames.first else { return }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        viewport = .fitting(union, in: viewportSize, margin: 48)
    }

    public func pan(dx: Double, dy: Double) { viewport.pan(dx: dx, dy: dy) }

    static func snapped(_ p: Point<DocumentSpace>) -> Point<DocumentSpace> {
        Point(x: p.x.rounded(), y: p.y.rounded())
    }
}
