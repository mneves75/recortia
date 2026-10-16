import Domain
import Foundation
import Testing

@Suite("Straight-line annotation geometry (FR-05, GEO-02)")
struct StraightLineAnnotationTests {
    @Test("A line keeps endpoint geometry and stroke bounds through coding and transforms")
    func geometryAndCoding() throws {
        let line = Annotation(
            kind: .line(start: Point(x: 30, y: 50), end: Point(x: 10, y: 20)),
            style: Annotation.Style(stroke: .red, lineWidth: 4))
        #expect(line.bounds == Rect(x: 10, y: 20, width: 20, height: 30))
        #expect(line.outsetBounds == Rect(x: 8, y: 18, width: 24, height: 34))
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(line))
        #expect(decoded == line)
        #expect(line.translated(dx: 7, dy: -4).kind == .line(start: Point(x: 37, y: 46), end: Point(x: 17, y: 16)))
        #expect(
            line.resized(from: line.bounds, to: Rect(x: 5, y: 8, width: 40, height: 15)).kind
                == .line(start: Point(x: 45, y: 23), end: Point(x: 5, y: 8)))
    }

    @Test("Resizing an axis-aligned line into the other axis retains its reversed endpoints")
    func resizeAcrossAxes() {
        let horizontal = Annotation(kind: .line(start: Point(x: 90, y: 20), end: Point(x: 10, y: 20)), style: .default)
        #expect(
            horizontal.resized(from: horizontal.bounds, to: Rect(x: 50, y: 30, width: 0, height: 160)).kind
                == .line(start: Point(x: 50, y: 190), end: Point(x: 50, y: 30)))
        let vertical = Annotation(kind: .line(start: Point(x: 20, y: 90), end: Point(x: 20, y: 10)), style: .default)
        #expect(
            vertical.resized(from: vertical.bounds, to: Rect(x: 30, y: 50, width: 160, height: 0)).kind
                == .line(start: Point(x: 190, y: 50), end: Point(x: 30, y: 50)))
    }
}
