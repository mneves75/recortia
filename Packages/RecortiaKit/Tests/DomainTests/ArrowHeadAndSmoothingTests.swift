import Domain
import Foundation
import Testing

@Suite("Arrowhead styles and smoothed strokes (FR-05)")
struct ArrowHeadAndSmoothingTests {
    /// Annotations as 0.14.0 encoded them, before head styles and smoothing existed.
    private static let legacyAnnotations = #"""
        [{"id":{"raw":"6F9C1D52-8E1B-4B0E-9A39-2C4D1E7B5A10"},"kind":{"arrow":{"end":{"x":100,"y":0},"start":{"x":0,"y":0}}},"style":{"lineWidth":4,"opacity":1,"stroke":{"a":255,"b":0,"g":0,"r":255}}},\#
        {"id":{"raw":"0B3F6A2E-1C55-4D7A-8E62-9F0A3B4C5D61"},"kind":{"arrow":{"control":{"x":50,"y":80},"end":{"x":100,"y":0},"start":{"x":0,"y":0}}},"style":{"lineWidth":4,"opacity":1,"stroke":{"a":255,"b":0,"g":0,"r":255}}},\#
        {"id":{"raw":"A1E2C3D4-5B6A-4C8D-9E0F-112233445566"},"kind":{"freehand":{"_0":[{"x":1,"y":2},{"x":3,"y":4},{"x":5,"y":3}]}},"style":{"lineWidth":4,"opacity":1,"stroke":{"a":255,"b":0,"g":0,"r":255}}},\#
        {"id":{"raw":"B1E2C3D4-5B6A-4C8D-9E0F-112233445567"},"kind":{"highlighter":{"_0":[{"x":1,"y":2},{"x":9,"y":2}]}},"style":{"lineWidth":18,"opacity":0.45,"stroke":{"a":255,"b":0,"g":255,"r":255}}}]
        """#

    @Test("Old documents decode with the filled head and raw strokes, and re-encode to the same bytes")
    func legacyDecoding() throws {
        let decoded = try JSONDecoder().decode([Annotation].self, from: Data(Self.legacyAnnotations.utf8))
        #expect(
            decoded.map(\.kind) == [
                .arrow(start: Point(x: 0, y: 0), end: Point(x: 100, y: 0), control: nil, head: nil),
                .arrow(start: Point(x: 0, y: 0), end: Point(x: 100, y: 0), control: Point(x: 50, y: 80), head: nil),
                .freehand([Point(x: 1, y: 2), Point(x: 3, y: 4), Point(x: 5, y: 3)], smoothed: nil),
                .highlighter([Point(x: 1, y: 2), Point(x: 9, y: 2)], smoothed: nil),
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded =
            "["
            + (try decoded.map { String(decoding: try encoder.encode($0), as: UTF8.self) })
            .joined(separator: ",") + "]"
        #expect(reencoded == Self.legacyAnnotations)
    }

    @Test("Head styles and smoothing round-trip through Codable")
    func newValuesRoundTrip() throws {
        let kinds: [Annotation.Kind] =
            Annotation.ArrowHead.allCases.map {
                .arrow(start: .zero, end: Point(x: 80, y: 10), control: Point(x: 40, y: 60), head: $0)
            } + [
                .freehand([Point(x: 0, y: 0), Point(x: 4, y: 9)], smoothed: true),
                .highlighter([Point(x: 0, y: 0), Point(x: 4, y: 9)], smoothed: true),
            ]
        for kind in kinds {
            let annotation = Annotation(kind: kind, style: .default)
            #expect(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(annotation)) == annotation)
            // Moving and resizing keep the head and the smoothing flag.
            let moved = annotation.translated(dx: 3, dy: 4)
            let resized = annotation.resized(from: annotation.bounds, to: Rect(x: 0, y: 0, width: 160, height: 90))
            for changed in [moved, resized] {
                switch (changed.kind, kind) {
                case (.arrow(_, _, _, let a), .arrow(_, _, _, let b)): #expect(a == b)
                case (.freehand(_, let a), .freehand(_, let b)), (.highlighter(_, let a), .highlighter(_, let b)):
                    #expect(a == b)
                default: Issue.record("kind changed: \(changed.kind)")
                }
            }
        }
    }

    /// A hand-drawn wobble: a sine stroke with deterministic jitter, sampled densely.
    private static func wobble(count: Int = 400) -> [Point<DocumentSpace>] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let jitter = sin(Double(i) * 12.9898) * 0.6
            return Point(x: 20 + t * 360, y: 120 + sin(t * .pi * 3) * 60 + jitter)
        }
    }

    @Test("Simplification is deterministic, keeps both endpoints, drops points, and stays within tolerance")
    func simplification() {
        let input = Self.wobble()
        let tolerance = StrokeSmoothing.tolerance
        let first = StrokeSmoothing.simplify(input, tolerance: tolerance)
        #expect(first == StrokeSmoothing.simplify(input, tolerance: tolerance))
        #expect(first.first == input.first && first.last == input.last)
        #expect(first.count < input.count / 4, "\(first.count) of \(input.count)")
        // Every kept point is an input point, and every dropped point lies near the result.
        #expect(first.allSatisfy { input.contains($0) })
        for point in input {
            #expect(Self.distance(point, toPolyline: first) <= tolerance + 1e-9)
        }
        // Too few points to drop, a zero tolerance and a closed loop.
        #expect(StrokeSmoothing.simplify(Array(input.prefix(2)), tolerance: tolerance) == Array(input.prefix(2)))
        #expect(StrokeSmoothing.simplify(input, tolerance: 0) == input)
        let loop = [Point<DocumentSpace>(x: 0, y: 0), Point(x: 50, y: 0), Point(x: 50, y: 50), Point(x: 0, y: 0)]
        #expect(StrokeSmoothing.simplify(loop, tolerance: tolerance) == loop)
    }

    @Test("The centripetal spline is deterministic, interpolates every point and stays near the input")
    func spline() {
        let input = Self.wobble()
        let kept = StrokeSmoothing.simplify(input, tolerance: StrokeSmoothing.tolerance)
        let segments = StrokeSmoothing.curve(through: kept)
        #expect(segments == StrokeSmoothing.curve(through: kept))
        #expect(segments.count == kept.count - 1)
        for (index, segment) in segments.enumerated() {
            #expect(segment.start == kept[index] && segment.end == kept[index + 1])
        }
        var worst = 0.0
        for segment in segments {
            for step in 0...32 {
                worst = max(worst, Self.distance(segment.point(at: Double(step) / 32), toPolyline: input))
            }
        }
        #expect(worst <= 2 * StrokeSmoothing.tolerance, "deviation \(worst)")
        // Two points give one straight segment; duplicate neighbours give finite controls.
        let line = StrokeSmoothing.curve(through: [Point(x: 0, y: 0), Point(x: 30, y: 0)])
        #expect(line.count == 1 && line[0].control1.y == 0 && line[0].control2.y == 0)
        let repeated = StrokeSmoothing.curve(through: [Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 9, y: 9)])
        #expect(repeated.allSatisfy { [$0.control1, $0.control2].allSatisfy(\.isFinite) })
        #expect(StrokeSmoothing.curve(through: [Point(x: 1, y: 1)]).isEmpty)
    }

    private static func distance(_ p: Point<DocumentSpace>, toPolyline points: [Point<DocumentSpace>]) -> Double {
        var best = Double.infinity
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }
}
