import Foundation

/// Freehand smoothing, applied once when a stroke ends (FR-05). Simplification drops points that
/// lie within `tolerance` of the line through their neighbours (Ramer–Douglas–Peucker); the kept
/// points are then drawn as a centripetal Catmull–Rom spline. Both steps are pure and
/// deterministic, so the canvas and every export draw the same curve from the stored points.
public enum StrokeSmoothing {
    /// Document points a dropped point may lie from the simplified stroke.
    public static let tolerance = 1.5

    /// One cubic Bézier piece of the spline.
    public struct Segment: Hashable, Sendable {
        public let start: Point<DocumentSpace>
        public let control1: Point<DocumentSpace>
        public let control2: Point<DocumentSpace>
        public let end: Point<DocumentSpace>

        public func point(at t: Double) -> Point<DocumentSpace> {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return Point(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y)
        }
    }

    /// The subset of `points` that keeps every dropped point within `tolerance` of the result.
    /// The first and last points are always kept.
    public static func simplify(_ points: [Point<DocumentSpace>], tolerance: Double) -> [Point<DocumentSpace>] {
        guard points.count > 2, tolerance > 0, tolerance.isFinite else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        // An explicit stack: a long stroke cannot exhaust the call stack.
        var ranges = [(0, points.count - 1)]
        while let (first, last) = ranges.popLast() {
            guard last - first > 1 else { continue }
            var farthest = first, distance = 0.0
            for index in (first + 1)..<last {
                let d = Self.distance(points[index], toSegment: points[first], points[last])
                if d > distance {
                    distance = d
                    farthest = index
                }
            }
            guard distance > tolerance else { continue }
            keep[farthest] = true
            ranges.append((first, farthest))
            ranges.append((farthest, last))
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// The centripetal (alpha 0.5) Catmull–Rom spline through `points`, one segment per pair.
    /// The ends repeat their point as the missing neighbour, so the curve starts and ends there.
    public static func curve(through points: [Point<DocumentSpace>]) -> [Segment] {
        guard points.count >= 2 else { return [] }
        return (0..<(points.count - 1)).map { index in
            let p1 = points[index], p2 = points[index + 1]
            let p0 = index > 0 ? points[index - 1] : p1
            let p3 = index + 2 < points.count ? points[index + 2] : p2
            return Segment(
                start: p1, control1: control(p0, p1, p2), control2: control(p3, p2, p1), end: p2)
        }
    }

    /// The Bézier control next to `p1` on the segment from `p1` to `p2`, given the neighbour
    /// `p0` on the other side of `p1` (Yuksel, Schaefer and Keyser's centripetal conversion).
    private static func control(
        _ p0: Point<DocumentSpace>, _ p1: Point<DocumentSpace>, _ p2: Point<DocumentSpace>
    ) -> Point<DocumentSpace> {
        let d1 = hypot(p1.x - p0.x, p1.y - p0.y), d2 = hypot(p2.x - p1.x, p2.y - p1.y)
        let a1 = d1.squareRoot(), a2 = d2.squareRoot()
        let denominator = 3 * a1 * (a1 + a2)
        guard denominator > 0, denominator.isFinite else { return p1 }
        let weight = 2 * d1 + 3 * a1 * a2 + d2
        let result = Point<DocumentSpace>(
            x: (d1 * p2.x - d2 * p0.x + weight * p1.x) / denominator,
            y: (d1 * p2.y - d2 * p0.y + weight * p1.y) / denominator)
        return result.isFinite ? result : p1
    }

    private static func distance(
        _ p: Point<DocumentSpace>, toSegment a: Point<DocumentSpace>, _ b: Point<DocumentSpace>
    ) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
