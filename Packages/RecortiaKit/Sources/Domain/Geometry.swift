import Foundation

// Coordinate spaces are phantom types so a point in one space cannot be passed where another is
// expected (SPEC.md §7). Every space uses a top-left origin with y growing downward; conversion
// from AppKit's bottom-left screen coordinates happens once, in MacPlatform.

/// Global desktop points, origin at the top-left of the primary display (Core Graphics convention).
public enum DesktopSpace {}
/// Points local to one display, origin at that display's top-left corner.
public enum DisplaySpace {}
/// Pixels of one immutable image asset.
public enum SourcePixelSpace {}
/// Document canvas units: one unit is one output pixel at export scale 1.
public enum DocumentSpace {}
/// Editor view points, after zoom and pan.
public enum ViewSpace {}

public enum GeometryError: Error, Equatable, Sendable {
    case nonFinite
    case negativeSize
    case singularTransform
    case outOfRange
}

public struct Point<Space>: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static var zero: Point { Point(x: 0, y: 0) }

    public var isFinite: Bool { x.isFinite && y.isFinite }

    public func offset(dx: Double, dy: Double) -> Point { Point(x: x + dx, y: y + dy) }
}

public struct Size<Space>: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect<Space>: Hashable, Sendable, Codable {
    public var origin: Point<Space>
    public var size: Size<Space>

    public init(origin: Point<Space>, size: Size<Space>) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    /// The rectangle spanned by two corner points dragged in any direction.
    public init(spanning a: Point<Space>, _ b: Point<Space>) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }
    public var corners: [Point<Space>] {
        [Point(x: minX, y: minY), Point(x: maxX, y: minY), Point(x: maxX, y: maxY), Point(x: minX, y: maxY)]
    }

    /// Throws for NaN/infinite coordinates and negative spans; zero-sized rects are valid.
    @discardableResult
    public func validated() throws -> Rect {
        guard origin.isFinite, size.width.isFinite, size.height.isFinite else { throw GeometryError.nonFinite }
        guard size.width >= 0, size.height >= 0 else { throw GeometryError.negativeSize }
        return self
    }

    public func contains(_ point: Point<Space>) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func intersects(_ other: Rect<Space>) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func intersection(_ other: Rect<Space>) -> Rect<Space>? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func union(_ other: Rect<Space>) -> Rect<Space> {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return Rect(x: x0, y: y0, width: max(maxX, other.maxX) - x0, height: max(maxY, other.maxY) - y0)
    }

    public func insetBy(dx: Double, dy: Double) -> Rect<Space> {
        Rect(x: minX + dx, y: minY + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }

    public func offsetBy(dx: Double, dy: Double) -> Rect<Space> {
        Rect(origin: origin.offset(dx: dx, dy: dy), size: size)
    }

    /// Bounding box of a non-empty set of points.
    public static func bounding(_ points: [Point<Space>]) -> Rect<Space>? {
        guard let first = points.first else { return nil }
        var x0 = first.x, y0 = first.y, x1 = first.x, y1 = first.y
        for p in points.dropFirst() {
            x0 = min(x0, p.x)
            y0 = min(y0, p.y)
            x1 = max(x1, p.x)
            y1 = max(y1, p.y)
        }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Integer pixel dimensions of a raster.
public struct PixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Width × height, or nil when either side is negative or the product overflows.
    public var checkedArea: Int? {
        guard width >= 0, height >= 0 else { return nil }
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? nil : area
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// An integer rectangle of whole source pixels.
public struct PixelRect: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { width * height }

    public var asRect: Rect<SourcePixelSpace> {
        Rect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    /// The smallest whole-pixel rectangle that covers `rect` (floor the minimum, ceil the maximum),
    /// clipped to `bounds`. Returns nil when nothing remains inside the bounds.
    public static func covering(_ rect: Rect<SourcePixelSpace>, within bounds: PixelSize) throws -> PixelRect? {
        try rect.validated()
        let limit = Double(Int32.max)
        let x0 = rect.minX.rounded(.down), y0 = rect.minY.rounded(.down)
        let x1 = rect.maxX.rounded(.up), y1 = rect.maxY.rounded(.up)
        guard abs(x0) < limit, abs(y0) < limit, abs(x1) < limit, abs(y1) < limit else {
            throw GeometryError.outOfRange
        }
        let cx0 = max(0, Int(x0)), cy0 = max(0, Int(y0))
        let cx1 = min(bounds.width, Int(x1)), cy1 = min(bounds.height, Int(y1))
        guard cx1 > cx0, cy1 > cy0 else { return nil }
        return PixelRect(x: cx0, y: cy0, width: cx1 - cx0, height: cy1 - cy0)
    }
}
