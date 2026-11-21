import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("Arrowhead styles and smoothed strokes: painted geometry (FR-05)")
struct ArrowHeadLayoutTests {
    private static func arrow(
        _ head: Annotation.ArrowHead, from start: Point<DocumentSpace> = .zero,
        to end: Point<DocumentSpace> = Point(x: 100, y: 0), control: Point<DocumentSpace>? = nil
    ) -> Annotation {
        Annotation(
            kind: .arrow(start: start, end: end, control: control, head: head),
            style: Annotation.Style(stroke: .red, lineWidth: 4))
    }

    private static func expectBounds(_ bounds: Rect<DocumentSpace>, _ expected: Rect<DocumentSpace>) {
        for (actual, wanted) in [
            (bounds.minX, expected.minX), (bounds.minY, expected.minY), (bounds.maxX, expected.maxX),
            (bounds.maxY, expected.maxY),
        ] {
            #expect(abs(actual - wanted) < 0.01, "\(bounds) is not \(expected)")
        }
    }

    @Test("Each head paints its own ink: filled and double triangles, an open V with round ends, a bare line")
    func straightInkBounds() throws {
        // Width 4: heads are 18 long and 12 wide each side; strokes reach 2 past their ends.
        Self.expectBounds(
            try ArrowLayout.make(for: Self.arrow(.filled)).inkBounds, Rect(x: 0, y: -12, width: 100, height: 24))
        Self.expectBounds(
            try ArrowLayout.make(for: Self.arrow(.double)).inkBounds, Rect(x: 0, y: -12, width: 100, height: 24))
        Self.expectBounds(
            try ArrowLayout.make(for: Self.arrow(.open)).inkBounds, Rect(x: -2, y: -14, width: 104, height: 28))
        Self.expectBounds(
            try ArrowLayout.make(for: Self.arrow(.plain)).inkBounds, Rect(x: -2, y: -2, width: 104, height: 4))
        // The legacy nil head is the filled head, pixel for pixel.
        let legacy = Annotation(
            kind: .arrow(start: .zero, end: Point(x: 100, y: 0)), style: Annotation.Style(stroke: .red, lineWidth: 4))
        #expect(try ArrowLayout.make(for: legacy).inkPath == ArrowLayout.make(for: Self.arrow(.filled)).inkPath)
    }

    @Test("Hit testing follows the painted head: inside a filled head, never where a bare line has none")
    func headHitTesting() throws {
        let insideEndHead = Point<DocumentSpace>(x: 88, y: 6), insideStartHead = Point<DocumentSpace>(x: 12, y: 6)
        let filled = try ArrowLayout.make(for: Self.arrow(.filled))
        let double = try ArrowLayout.make(for: Self.arrow(.double))
        let open = try ArrowLayout.make(for: Self.arrow(.open))
        let plain = try ArrowLayout.make(for: Self.arrow(.plain))
        #expect(filled.hitTest(insideEndHead, tolerance: 0) && !filled.hitTest(insideStartHead, tolerance: 0))
        #expect(double.hitTest(insideEndHead, tolerance: 0) && double.hitTest(insideStartHead, tolerance: 0))
        #expect(!plain.hitTest(insideEndHead, tolerance: 1) && !plain.hitTest(insideStartHead, tolerance: 1))
        #expect(plain.hitTest(Point(x: 50, y: 2.5), tolerance: 1) && plain.headPath.isEmpty)
        // The open V is ink on its arms, not across the empty inside of the V.
        #expect(open.hitTest(Point(x: 91, y: 6), tolerance: 0) && !open.hitTest(Point(x: 85, y: 6), tolerance: 0))
    }

    @Test("A curved double arrow has a head at each end and a shaft trimmed into both")
    func curvedDouble() throws {
        let start = Point<DocumentSpace>(x: 20, y: 50), end = Point<DocumentSpace>(x: 180, y: 50)
        let control = Point<DocumentSpace>(x: 100, y: 150)
        let single = try ArrowLayout.make(for: Self.arrow(.filled, from: start, to: end, control: control))
        let double = try ArrowLayout.make(for: Self.arrow(.double, from: start, to: end, control: control))
        #expect(double.shaftPath.currentPoint == single.shaftPath.currentPoint)
        // A point beside the shaft inside the end head, and its mirror image at the start.
        let nearEnd = Point<DocumentSpace>(x: 178.28, y: 60.15), nearStart = Point<DocumentSpace>(x: 21.72, y: 60.15)
        #expect(single.hitTest(nearEnd, tolerance: 0) && !single.hitTest(nearStart, tolerance: 0))
        #expect(double.hitTest(nearEnd, tolerance: 0) && double.hitTest(nearStart, tolerance: 0))
        // Both heads are mirror images: the painted bounds are symmetric about x = 100.
        #expect(abs((double.inkBounds.minX + double.inkBounds.maxX) / 2 - 100) < 0.01)
        let context = try #require(ChartFixture.context(width: 200, height: 160))
        context.translateBy(x: 0, y: 160)
        context.scaleBy(x: 1, y: -1)
        try AnnotationRenderer.draw(
            [
                Annotation(
                    kind: .arrow(start: start, end: end, control: control, head: .double),
                    style: Annotation.Style(stroke: RGBA(r: 255, g: 0, b: 0, a: 128), lineWidth: 4))
            ], in: context)
        let raster = try pixels(try #require(context.makeImage()))
        #expect(raster.pixel(x: 22, y: 60).a >= 120 && raster.pixel(x: 178, y: 60).a >= 120)
        for y in 0..<160 {
            for x in 0..<200 where raster.pixel(x: x, y: y).a > 0 {
                #expect(raster.pixel(x: x, y: y).a <= 129, "head and shaft overlap keep one opacity")
                #expect(Double(x + 1) >= double.inkBounds.minX && Double(x) <= double.inkBounds.maxX)
                #expect(Double(y + 1) >= double.inkBounds.minY && Double(y) <= double.inkBounds.maxY)
            }
        }
    }

    @Test("Short double arrows shrink both heads so they never overlap")
    func shortDouble() throws {
        let straight = try ArrowLayout.make(for: Self.arrow(.double, to: Point(x: 20, y: 0)))
        Self.expectBounds(straight.inkBounds, Rect(x: 0, y: -12, width: 20, height: 24))
        let curve = try ArrowLayout.make(
            for: Self.arrow(.double, from: Point(x: 50, y: 50), to: Point(x: 70, y: 50), control: Point(x: 60, y: 54)))
        #expect(curve.inkBounds.minX >= 49.9 && curve.inkBounds.maxX <= 70.1)
        #expect(!curve.shaftInkPath.isEmpty)
    }

    @Test("Head styles keep the admission rules of the curve they paint")
    func degenerateHeads() throws {
        for head in Annotation.ArrowHead.allCases {
            let coincident = Self.arrow(
                head, from: Point(x: 5, y: 5), to: Point(x: 5, y: 5), control: Point(x: 9, y: 9))
            #expect(throws: RenderError.invalidGeometry) { try ArrowLayout.make(for: coincident) }
            let empty = try ArrowLayout.make(for: Self.arrow(head, to: .zero))
            #expect(empty.inkPath.isEmpty && !empty.hitTest(.zero, tolerance: 10))
        }
    }

    @Test("A smoothed stroke is drawn as curves through its points; a raw stroke stays a polyline")
    func smoothedStroke() throws {
        let points = [Point<DocumentSpace>(x: 20, y: 100), Point(x: 100, y: 20), Point(x: 180, y: 100)]
        let style = Annotation.Style(stroke: .red, lineWidth: 4)
        func draw(_ smoothed: Bool?) throws -> DecodedPixels {
            let context = try #require(ChartFixture.context(width: 200, height: 120))
            context.translateBy(x: 0, y: 120)
            context.scaleBy(x: 1, y: -1)
            try AnnotationRenderer.draw(
                [Annotation(kind: .freehand(points, smoothed: smoothed), style: style)], in: context)
            return try pixels(try #require(context.makeImage()))
        }
        let smooth = try draw(true), raw = try draw(nil)
        // The curve rounds the corner above the chord; the polyline runs through (50, 70).
        #expect(smooth.pixel(x: 50, y: 60).a > 200 && raw.pixel(x: 50, y: 60).a == 0)
        #expect(raw.pixel(x: 50, y: 70).a > 200)
        #expect(smooth.pixel(x: 100, y: 20).a > 200, "the curve passes through every stored point")
        #expect(StrokePath.make(points, smoothed: true) == StrokePath.make(points, smoothed: true))
    }
}
