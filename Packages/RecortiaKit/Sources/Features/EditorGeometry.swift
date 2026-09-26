import CoreGraphics
import CoreText
import Domain
import Foundation

/// Pure document-space geometry for the editor: frames, hit testing, handles, and resizing.
/// Every tolerance is passed in document units, so callers convert view distances through the
/// viewport and zoom never changes a result for the same document-space input (EDIT-02).
enum EditorGeometry {
    // MARK: Frames

    /// Selection frame of an annotation. Text uses the same Core Text layout as the renderer.
    static func frame(of annotation: Annotation) -> Rect<DocumentSpace> {
        if case .text(let text) = annotation.kind {
            let size = textSize(text)
            return Rect(origin: text.origin, size: size)
        }
        return annotation.bounds
    }

    /// Mirrors `AnnotationRenderer`'s text frame: system font, framesetter-suggested size.
    static func textSize(_ text: Annotation.TextContent) -> Size<DocumentSpace> {
        let fallback = Size<DocumentSpace>(width: text.fontSize * 0.6, height: text.fontSize * 1.25)
        guard !text.string.isEmpty, text.fontSize.isFinite, text.fontSize > 0 else { return fallback }
        let font =
            CTFontCreateUIFontForLanguage(.system, text.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, text.fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        guard let attributed = CFAttributedStringCreate(nil, text.string as CFString, attributes as CFDictionary)
        else { return fallback }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let unbounded = CGFloat.greatestFiniteMagnitude
        let constraint = CGSize(width: text.maxWidth.map { CGFloat($0) } ?? unbounded, height: unbounded)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let width = text.maxWidth ?? Double(suggested.width.rounded(.up) + 1)
        let height = Double(suggested.height.rounded(.up) + 1)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return fallback }
        return Size(width: width, height: height)
    }

    static func frame(of item: EditorItemID, in document: Document) -> Rect<DocumentSpace>? {
        switch item {
        case .annotation(let id):
            return document.annotations.first { $0.id == id }.map(frame(of:))
        case .layer(let id):
            guard let layer = document.layers.first(where: { $0.id == id }),
                let asset = document.assets[layer.assetID]
            else { return nil }
            return layer.documentBounds(assetSize: asset.pixelSize)
        case .mask(let id):
            return document.masks.first { $0.id == id }?.outputRect
        case .obfuscation(let id):
            return document.obfuscations.first { $0.id == id }?.rect
        case .callout(let id):
            guard let callout = document.callouts.first(where: { $0.id == id }) else { return nil }
            switch callout.kind {
            case .spotlight(let rect, _): return rect
            case .magnifier(_, let destination): return destination
            }
        }
    }

    // MARK: Hit testing

    static func distance(from p: Point<DocumentSpace>, toSegment a: Point<DocumentSpace>, _ b: Point<DocumentSpace>)
        -> Double
    {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func polylineDistance(from p: Point<DocumentSpace>, _ points: [Point<DocumentSpace>]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = Double.infinity
        for i in 1..<points.count { best = min(best, distance(from: p, toSegment: points[i - 1], points[i])) }
        return best
    }

    static func expanded(_ rect: Rect<DocumentSpace>, by amount: Double) -> Rect<DocumentSpace> {
        Rect(
            x: rect.minX - amount, y: rect.minY - amount, width: rect.width + 2 * amount,
            height: rect.height + 2 * amount)
    }

    static func containsInclusive(_ rect: Rect<DocumentSpace>, _ p: Point<DocumentSpace>) -> Bool {
        p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }

    static func hits(_ annotation: Annotation, at p: Point<DocumentSpace>, tolerance: Double) -> Bool {
        let reach = tolerance + annotation.style.lineWidth / 2
        switch annotation.kind {
        case .text, .step:
            return containsInclusive(expanded(frame(of: annotation), by: tolerance), p)
        case .rectangle(let rect):
            guard containsInclusive(expanded(rect, by: reach), p) else { return false }
            if annotation.style.fill != nil { return true }
            let inner = rect.insetBy(dx: reach, dy: reach)
            return inner.isEmpty || !inner.contains(p)
        case .ellipse(let rect):
            let rx = rect.width / 2, ry = rect.height / 2
            func value(_ ax: Double, _ ay: Double) -> Double {
                guard ax > 0, ay > 0 else { return .infinity }
                let nx = (p.x - rect.midX) / ax, ny = (p.y - rect.midY) / ay
                return nx * nx + ny * ny
            }
            guard value(rx + reach, ry + reach) <= 1 else { return false }
            if annotation.style.fill != nil { return true }
            return rx - reach <= 0 || ry - reach <= 0 || value(rx - reach, ry - reach) >= 1
        case .arrow(let start, let end):
            let head = max(annotation.style.lineWidth * 3, 9)
            return distance(from: p, toSegment: start, end) <= reach
                || hypot(p.x - end.x, p.y - end.y) <= head + tolerance
        case .freehand(let points), .highlighter(let points):
            return polylineDistance(from: p, points) <= reach
        }
    }

    // MARK: Handles

    static func handles(for rect: Rect<DocumentSpace>, cornersOnly: Bool) -> [(EditorHandle, Point<DocumentSpace>)] {
        let corners: [(EditorHandle, Point<DocumentSpace>)] = [
            (.topLeft, Point(x: rect.minX, y: rect.minY)), (.topRight, Point(x: rect.maxX, y: rect.minY)),
            (.bottomRight, Point(x: rect.maxX, y: rect.maxY)), (.bottomLeft, Point(x: rect.minX, y: rect.maxY)),
        ]
        guard !cornersOnly else { return corners }
        return corners + [
            (.top, Point(x: rect.midX, y: rect.minY)), (.right, Point(x: rect.maxX, y: rect.midY)),
            (.bottom, Point(x: rect.midX, y: rect.maxY)), (.left, Point(x: rect.minX, y: rect.midY)),
        ]
    }

    /// Resizes `original` by dragging `handle` to `p`. Corners with `keepAspect` scale uniformly
    /// about the opposite corner. The result is normalized (dragging past an edge flips it) and at
    /// least `minimum` wide and tall.
    static func resize(
        _ original: Rect<DocumentSpace>, handle: EditorHandle, to p: Point<DocumentSpace>, keepAspect: Bool,
        minimum: Double = 1
    ) -> Rect<DocumentSpace> {
        var x0 = original.minX, y0 = original.minY, x1 = original.maxX, y1 = original.maxY
        switch handle {
        case .topLeft: (x0, y0) = (p.x, p.y)
        case .top: y0 = p.y
        case .topRight: (x1, y0) = (p.x, p.y)
        case .right: x1 = p.x
        case .bottomRight: (x1, y1) = (p.x, p.y)
        case .bottom: y1 = p.y
        case .bottomLeft: (x0, y1) = (p.x, p.y)
        case .left: x0 = p.x
        case .start, .end: return original
        }
        if keepAspect, handle.isCorner, original.width > 0, original.height > 0 {
            let fixedX = handle == .topLeft || handle == .bottomLeft ? original.maxX : original.minX
            let fixedY = handle == .topLeft || handle == .topRight ? original.maxY : original.minY
            let factor = max(abs(p.x - fixedX) / original.width, abs(p.y - fixedY) / original.height)
            let width = max(minimum, original.width * factor), height = max(minimum, original.height * factor)
            let signX: Double = p.x >= fixedX ? 1 : -1, signY: Double = p.y >= fixedY ? 1 : -1
            return Rect(
                spanning: Point(x: fixedX, y: fixedY), Point(x: fixedX + signX * width, y: fixedY + signY * height))
        }
        var rect = Rect<DocumentSpace>(spanning: Point(x: x0, y: y0), Point(x: x1, y: y1))
        rect.size.width = max(minimum, rect.width)
        rect.size.height = max(minimum, rect.height)
        return rect
    }

    // MARK: Snapping

    /// Smallest whole-pixel rectangle covering `rect` (redaction edges round outward, FR-06).
    static func outwardIntegral(_ rect: Rect<DocumentSpace>) -> Rect<DocumentSpace> {
        let x0 = rect.minX.rounded(.down), y0 = rect.minY.rounded(.down)
        let x1 = rect.maxX.rounded(.up), y1 = rect.maxY.rounded(.up)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func isFinite(_ rect: Rect<DocumentSpace>) -> Bool {
        rect.origin.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    /// Constrains a dragged rectangle to a square when requested.
    static func constrainedRect(from start: Point<DocumentSpace>, to end: Point<DocumentSpace>, square: Bool)
        -> Rect<DocumentSpace>
    {
        guard square else { return Rect(spanning: start, end) }
        let side = max(abs(end.x - start.x), abs(end.y - start.y))
        let x = end.x >= start.x ? start.x + side : start.x - side
        let y = end.y >= start.y ? start.y + side : start.y - side
        return Rect(spanning: start, Point(x: x, y: y))
    }
}
