import Foundation

/// A typed 2D affine transform from one coordinate space to another.
///
/// Maps `(x, y)` to `(a·x + c·y + tx, b·x + d·y + ty)`, matching Core Graphics' matrix layout so
/// MacPlatform/Imaging can convert without reordering terms.
public struct AffineMap<From, To>: Hashable, Sendable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static var identity: AffineMap { AffineMap(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }

    public static func scale(_ s: Double) -> AffineMap { scale(x: s, y: s) }

    public static func scale(x: Double, y: Double) -> AffineMap { AffineMap(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0) }

    public static func translation(dx: Double, dy: Double) -> AffineMap {
        AffineMap(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
    }

    /// Rotation by `radians`; positive angles turn +x toward +y (clockwise on a y-down canvas).
    public static func rotation(_ radians: Double) -> AffineMap {
        let cosine = cos(radians), sine = sin(radians)
        return AffineMap(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    public var determinant: Double { a * d - b * c }

    public var isFinite: Bool { [a, b, c, d, tx, ty].allSatisfy(\.isFinite) }

    public func apply(_ p: Point<From>) -> Point<To> {
        Point(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }

    /// Bounding box of the transformed corners; conservative for rotations.
    public func apply(_ rect: Rect<From>) -> Rect<To> {
        let mapped = rect.corners.map(apply)
        return Rect<To>.bounding(mapped) ?? Rect(x: 0, y: 0, width: 0, height: 0)
    }

    /// Composes `next` after `self`: the result applies `self`, then `next`.
    public func then<Next>(_ next: AffineMap<To, Next>) -> AffineMap<From, Next> {
        composed(with: next)
    }

    /// Same-space adjustment after `self` (scale, translate, rotate within the destination space).
    public func then(_ next: AffineMap<To, To>) -> AffineMap<From, To> {
        composed(with: next)
    }

    private func composed<Next>(with next: AffineMap<To, Next>) -> AffineMap<From, Next> {
        AffineMap<From, Next>(
            a: a * next.a + b * next.c,
            b: a * next.b + b * next.d,
            c: c * next.a + d * next.c,
            d: c * next.b + d * next.d,
            tx: tx * next.a + ty * next.c + next.tx,
            ty: tx * next.b + ty * next.d + next.ty)
    }

    public func inverted() throws -> AffineMap<To, From> {
        guard isFinite else { throw GeometryError.nonFinite }
        let det = determinant
        guard det.isFinite, abs(det) > 1e-12 else { throw GeometryError.singularTransform }
        return AffineMap<To, From>(
            a: d / det, b: -b / det, c: -c / det, d: a / det,
            tx: (c * ty - d * tx) / det,
            ty: (b * tx - a * ty) / det)
    }
}
