import Domain
import Foundation
import Testing

@Suite("Editable curved-arrow values (FR-05)")
struct CurvedArrowTests {
    @Test("Bounds include each non-midpoint extremum and visible bend coordinates have one inverse")
    func extremaAndVisibleBend() {
        let curve = Annotation(
            kind: .arrow(start: .zero, end: Point(x: 100, y: 100), control: Point(x: 200, y: -100)), style: .default)
        #expect(curve.bounds.minX == 0)
        #expect(abs(curve.bounds.maxX - 400.0 / 3) < 0.000_001)
        #expect(abs(curve.bounds.minY + 100.0 / 3) < 0.000_001)
        #expect(curve.bounds.maxY == 100)
        let start = Point<DocumentSpace>(x: 20, y: 40), end = Point<DocumentSpace>(x: 180, y: 40)
        let control = ArrowCurve.defaultControl(start: start, end: end)
        #expect(control == Point(x: 100, y: 80))
        #expect(ArrowCurve.bend(start: start, end: end, control: control) == Point(x: 100, y: 60))
        #expect(ArrowCurve.control(start: start, end: end, bend: Point(x: 100, y: 60)) == control)
        #expect(ArrowCurve.control(start: start, end: end, bend: Point(x: 100, y: 20)) == Point(x: 100, y: 0))
    }

    @Test("Legacy arrows retain exact sorted JSON; curves round-trip and transform their control")
    func codingAndTransforms() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let straight = Annotation.Kind.arrow(start: Point(x: 0, y: 0), end: Point(x: 100, y: 0))
        let legacy = #"{"arrow":{"end":{"x":100,"y":0},"start":{"x":0,"y":0}}}"#
        #expect(String(decoding: try encoder.encode(straight), as: UTF8.self) == legacy)
        #expect(try JSONDecoder().decode(Annotation.Kind.self, from: Data(legacy.utf8)) == straight)
        let curve = Annotation(
            kind: .arrow(start: .zero, end: Point(x: 100, y: 0), control: Point(x: 50, y: 100)),
            style: .default)
        #expect(try JSONDecoder().decode(Annotation.self, from: encoder.encode(curve)) == curve)
        #expect(curve.bounds == Rect(x: 0, y: 0, width: 100, height: 50))
        #expect(
            curve.translated(dx: 4, dy: 8).kind
                == .arrow(
                    start: Point(x: 4, y: 8), end: Point(x: 104, y: 8), control: Point(x: 54, y: 108)))
        #expect(
            curve.resized(from: curve.bounds, to: Rect(x: 10, y: 20, width: 200, height: 25)).kind
                == .arrow(
                    start: Point(x: 10, y: 20), end: Point(x: 210, y: 20), control: Point(x: 110, y: 70)))
    }
}
