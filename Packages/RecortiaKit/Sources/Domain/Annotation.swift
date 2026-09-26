import Foundation

/// An editable annotation drawn above the raster layers (FR-05). Geometry is in document space,
/// never view space, so zoom cannot move a drawn object.
public struct Annotation: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case text(TextContent)
        case arrow(start: Point<DocumentSpace>, end: Point<DocumentSpace>)
        case rectangle(Rect<DocumentSpace>)
        case ellipse(Rect<DocumentSpace>)
        case freehand([Point<DocumentSpace>])
        case highlighter([Point<DocumentSpace>])
        case step(center: Point<DocumentSpace>, number: Int)
    }

    public struct TextContent: Hashable, Sendable, Codable {
        public var origin: Point<DocumentSpace>
        public var string: String
        public var fontSize: Double
        /// Wrap width in document units; nil means no wrapping.
        public var maxWidth: Double?

        public init(origin: Point<DocumentSpace>, string: String, fontSize: Double = 24, maxWidth: Double? = nil) {
            self.origin = origin
            self.string = string
            self.fontSize = fontSize
            self.maxWidth = maxWidth
        }
    }

    public struct Style: Hashable, Sendable, Codable {
        public var stroke: RGBA
        public var fill: RGBA?
        public var lineWidth: Double
        public var opacity: Double

        public init(stroke: RGBA, fill: RGBA? = nil, lineWidth: Double = 4, opacity: Double = 1) {
            self.stroke = stroke
            self.fill = fill
            self.lineWidth = lineWidth
            self.opacity = opacity
        }

        public static let `default` = Style(stroke: .red)
        public static let highlighter = Style(stroke: RGBA.yellow, lineWidth: 18, opacity: 0.45)
    }

    public var id: AnnotationID
    public var kind: Kind
    public var style: Style

    public init(id: AnnotationID = AnnotationID(), kind: Kind, style: Style) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    /// Approximate bytes of unique data this annotation stores (points and text dominate). Used to
    /// budget undo memory (FR-04); not an exact allocation size.
    public var estimatedByteCost: Int {
        let base = 128
        switch kind {
        case .text(let text): return base + text.string.utf8.count * 2
        case .freehand(let points), .highlighter(let points):
            return base + points.count * MemoryLayout<Point<DocumentSpace>>.stride
        case .arrow, .rectangle, .ellipse, .step: return base
        }
    }

    /// Radius of a numbered step marker, derived from line width so it scales with style.
    public var stepRadius: Double { max(14, style.lineWidth * 4) }

    /// Geometric bounds before stroke outset; text bounds are approximated by the renderer.
    public var bounds: Rect<DocumentSpace> {
        switch kind {
        case .text(let text):
            let width = text.maxWidth ?? Double(max(1, text.string.count)) * text.fontSize * 0.6
            let lines = Double(max(1, text.string.split(separator: "\n", omittingEmptySubsequences: false).count))
            return Rect(origin: text.origin, size: Size(width: width, height: lines * text.fontSize * 1.25))
        case .arrow(let start, let end):
            return Rect(spanning: start, end)
        case .rectangle(let rect), .ellipse(let rect):
            return rect
        case .freehand(let points), .highlighter(let points):
            return Rect.bounding(points) ?? Rect(origin: .zero, size: Size(width: 0, height: 0))
        case .step(let center, _):
            let r = stepRadius
            return Rect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        }
    }

    /// Bounds including the stroke, used for hit testing and dirty regions.
    public var outsetBounds: Rect<DocumentSpace> {
        let pad = style.lineWidth / 2 + (isArrow ? style.lineWidth * 3 : 0)
        let b = bounds
        return Rect(x: b.minX - pad, y: b.minY - pad, width: b.width + 2 * pad, height: b.height + 2 * pad)
    }

    private var isArrow: Bool {
        if case .arrow = kind { return true }
        return false
    }

    public func translated(dx: Double, dy: Double) -> Annotation {
        var copy = self
        switch kind {
        case .text(var text):
            text.origin = text.origin.offset(dx: dx, dy: dy)
            copy.kind = .text(text)
        case .arrow(let start, let end):
            copy.kind = .arrow(start: start.offset(dx: dx, dy: dy), end: end.offset(dx: dx, dy: dy))
        case .rectangle(let rect):
            copy.kind = .rectangle(rect.offsetBy(dx: dx, dy: dy))
        case .ellipse(let rect):
            copy.kind = .ellipse(rect.offsetBy(dx: dx, dy: dy))
        case .freehand(let points):
            copy.kind = .freehand(points.map { $0.offset(dx: dx, dy: dy) })
        case .highlighter(let points):
            copy.kind = .highlighter(points.map { $0.offset(dx: dx, dy: dy) })
        case .step(let center, let number):
            copy.kind = .step(center: center.offset(dx: dx, dy: dy), number: number)
        }
        return copy
    }

    /// Maps the annotation's geometry from `old` bounds into `new` bounds (resize handles).
    public func resized(from old: Rect<DocumentSpace>, to new: Rect<DocumentSpace>) -> Annotation {
        guard old.width > 0 || old.height > 0 else {
            return translated(dx: new.minX - old.minX, dy: new.minY - old.minY)
        }
        let sx = old.width > 0 ? new.width / old.width : 1
        let sy = old.height > 0 ? new.height / old.height : 1
        func map(_ p: Point<DocumentSpace>) -> Point<DocumentSpace> {
            Point(x: new.minX + (p.x - old.minX) * sx, y: new.minY + (p.y - old.minY) * sy)
        }
        var copy = self
        switch kind {
        case .text(var text):
            text.origin = map(text.origin)
            text.fontSize = max(6, text.fontSize * sy)
            if let width = text.maxWidth { text.maxWidth = width * sx }
            copy.kind = .text(text)
        case .arrow(let start, let end):
            copy.kind = .arrow(start: map(start), end: map(end))
        case .rectangle:
            copy.kind = .rectangle(new)
        case .ellipse:
            copy.kind = .ellipse(new)
        case .freehand(let points):
            copy.kind = .freehand(points.map(map))
        case .highlighter(let points):
            copy.kind = .highlighter(points.map(map))
        case .step(let center, let number):
            copy.kind = .step(center: map(center), number: number)
        }
        return copy
    }
}

extension Array where Element == Annotation {
    /// Renumbers step markers 1…n in z-order (explicit "Renumber" command, FR-05).
    public func renumberingSteps() -> [Annotation] {
        var next = 1
        return map { annotation in
            guard case .step(let center, _) = annotation.kind else { return annotation }
            var copy = annotation
            copy.kind = .step(center: center, number: next)
            next += 1
            return copy
        }
    }

    public var nextStepNumber: Int {
        let numbers = compactMap { annotation -> Int? in
            if case .step(_, let n) = annotation.kind { return n }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }
}
