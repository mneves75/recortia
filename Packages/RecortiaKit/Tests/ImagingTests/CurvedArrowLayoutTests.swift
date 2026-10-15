import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("Curved-arrow painted geometry (FR-05)")
struct CurvedArrowLayoutTests {
    @Test("An extreme control retains its far bend and trims on the final branch deterministically")
    func extremeControl() throws {
        let annotation = Annotation(
            kind: .arrow(start: Point(x: 50, y: 100), end: Point(x: 55, y: 100), control: Point(x: 1000, y: 300)),
            style: Annotation.Style(stroke: .red, lineWidth: 4, opacity: 0.5))
        let first = try ArrowLayout.make(for: annotation), second = try ArrowLayout.make(for: annotation)
        #expect(first.inkBounds == second.inkBounds)
        #expect(first.hitTest(Point(x: 526.25, y: 200), tolerance: 0))
        #expect(first.inkBounds.maxX > 526 && first.inkBounds.maxY > 200)
        let context = try #require(ChartFixture.context(width: 600, height: 240))
        context.translateBy(x: 0, y: 240)
        context.scaleBy(x: 1, y: -1)
        try AnnotationRenderer.draw([annotation], in: context)
        let raster = try pixels(try #require(context.makeImage()))
        #expect(raster.pixel(x: 526, y: 200).a >= 126)
        #expect(raster.pixel(x: 63, y: 102).a >= 126, "the filled head still points into its terminal branch")
        try expectConnected(raster, minimumAlpha: 100, description: "extreme control with 5px endpoint chord")
    }

    @Test("Zero-width curves paint exactly their filled head without a hidden hairline")
    func zeroWidthShaft() throws {
        let annotation = Annotation(
            kind: .arrow(start: Point(x: 20, y: 30), end: Point(x: 180, y: 30), control: Point(x: 100, y: 130)),
            style: Annotation.Style(stroke: .red, lineWidth: 0))
        let layout = try ArrowLayout.make(for: annotation)
        #expect(layout.shaftInkPath.isEmpty)
        #expect(!layout.hitTest(Point(x: 100, y: 80), tolerance: 1))
        let context = try #require(ChartFixture.context(width: 200, height: 150))
        context.translateBy(x: 0, y: 150)
        context.scaleBy(x: 1, y: -1)
        try AnnotationRenderer.draw([annotation], in: context)
        let raster = try pixels(try #require(context.makeImage()))
        #expect(raster.pixel(x: 100, y: 80).a == 0)
        #expect(raster.pixel(x: 174, y: 38).a > 0)
    }

    @Test("Translucent stroke colors retain one coverage through the head junction")
    func strokeAlpha() throws {
        let context = try #require(ChartFixture.context(width: 200, height: 150))
        context.translateBy(x: 0, y: 150)
        context.scaleBy(x: 1, y: -1)
        try AnnotationRenderer.draw(
            [
                Annotation(
                    kind: .arrow(start: Point(x: 20, y: 30), end: Point(x: 180, y: 30), control: Point(x: 100, y: 130)),
                    style: Annotation.Style(stroke: RGBA(r: 255, g: 0, b: 0, a: 128), lineWidth: 4))
            ], in: context)
        let raster = try pixels(try #require(context.makeImage()))
        #expect(raster.pixel(x: 100, y: 80).a >= 126)
        for y in 0..<150 {
            for x in 0..<200 { #expect(raster.pixel(x: x, y: y).a <= 129) }
        }
    }

    @Test(
        "Shaft and filled head form one painted component at fractional and doubled scales",
        arguments: [0.75, 1.0, 2.0])
    func connectedHeadPixels(scale: Double) throws {
        let cases: [(Point<DocumentSpace>, Point<DocumentSpace>, Point<DocumentSpace>)] = [
            (Point(x: 20, y: 50), Point(x: 180, y: 50), Point(x: 100, y: 150)),
            (Point(x: 20, y: 150), Point(x: 180, y: 150), Point(x: 100, y: 50)),
            (Point(x: 30, y: 30), Point(x: 190, y: 160), Point(x: 30, y: 160)),
            (Point(x: 180, y: 50), Point(x: 20, y: 50), Point(x: 100, y: 150)),
            (Point(x: 30, y: 100), Point(x: 100, y: 100), Point(x: 250, y: 100)),
            (Point(x: 20, y: 50), Point(x: 180, y: 50), Point(x: 180, y: 50)),
        ]
        for (start, end, control) in cases {
            let annotation = Annotation(
                kind: .arrow(start: start, end: end, control: control),
                style: Annotation.Style(stroke: .red, lineWidth: 4, opacity: 0.5))
            let width = Int(280 * scale), height = Int(200 * scale)
            let context = try #require(ChartFixture.context(width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            try AnnotationRenderer.draw([annotation], in: context)
            let raster = try pixels(try #require(context.makeImage()))
            try expectConnected(
                raster, minimumAlpha: 100,
                description: "\(start), \(end), \(control) at \(scale)x")
        }
    }

    @Test("A one-pixel collinear curve retains connected subpixel coverage", arguments: [0.75, 1.0, 2.0])
    func subpixelHead(scale: Double) throws {
        let width = Int(100 * scale), height = Int(100 * scale)
        let context = try #require(ChartFixture.context(width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        try AnnotationRenderer.draw(
            [
                Annotation(
                    kind: .arrow(start: Point(x: 50, y: 50), end: Point(x: 51, y: 50), control: Point(x: 50.5, y: 50)),
                    style: Annotation.Style(stroke: .red, lineWidth: 4, opacity: 0.5))
            ], in: context)
        let raster = try pixels(try #require(context.makeImage()))
        // A 0.75px-wide triangle has no fully covered pixel. Its antialiased coverage
        // must still be present and connected; the regular fixtures retain alpha100.
        try expectConnected(raster, minimumAlpha: 1, description: "one-pixel arrow at \(scale)x")
    }

    private func expectConnected(_ raster: DecodedPixels, minimumAlpha: UInt8, description: String) throws {
        let width = raster.width, height = raster.height
        var ink: Set<Int> = []
        for y in 0..<height {
            for x in 0..<width {
                let alpha = raster.pixel(x: x, y: y).a
                #expect(alpha <= 129)
                if alpha >= minimumAlpha { ink.insert(y * width + x) }
            }
        }
        let seed = try #require(ink.first, "\(description)")
        var queue = [seed], visited: Set<Int> = [seed], index = 0
        while index < queue.count {
            let pixel = queue[index]
            index += 1
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = pixel % width + dx, y = pixel / width + dy
                    let next = y * width + x
                    if x >= 0, x < width, y >= 0, y < height, ink.contains(next), visited.insert(next).inserted {
                        queue.append(next)
                    }
                }
            }
        }
        #expect(visited.count == ink.count, "shaft/head disconnected: \(description)")
    }

    @Test("A terminal head has filled wings without a shaft protruding beyond its tip")
    func terminalHeadPixels() throws {
        let context = try #require(ChartFixture.context(width: 200, height: 150))
        context.translateBy(x: 0, y: 150)
        context.scaleBy(x: 1, y: -1)
        try AnnotationRenderer.draw(
            [
                Annotation(
                    kind: .arrow(start: Point(x: 20, y: 30), end: Point(x: 180, y: 30), control: Point(x: 100, y: 130)),
                    style: Annotation.Style(stroke: .red, lineWidth: 4, opacity: 0.5))
            ], in: context)
        let raster = try pixels(try #require(context.makeImage()))
        for (x, y) in [(170, 40), (171, 45), (165, 40), (175, 47)] {
            #expect(raster.pixel(x: x, y: y).a >= 126, "filled head/junction at literal fixture pixel \(x),\(y)")
        }
        for (x, y) in [(181, 28), (180, 27), (179, 25)] {
            #expect(raster.pixel(x: x, y: y).a == 0, "no shaft past the tip")
        }
    }

    @Test("Malformed or unconstructible curved heads refuse explicitly; straight degeneracy remains empty")
    func invalidGeometry() throws {
        let invalid: [Annotation.Kind] = [
            .arrow(start: .zero, end: .zero, control: Point(x: 20, y: 40)),
            .arrow(start: .zero, end: Point(x: 100, y: 0), control: Point(x: .nan, y: 40)),
            .arrow(start: .zero, end: Point(x: 100, y: 0), control: Point(x: .infinity, y: 40)),
            .arrow(
                start: Point(x: -Double.greatestFiniteMagnitude, y: 0),
                end: Point(x: Double.greatestFiniteMagnitude, y: 0), control: .zero),
            .arrow(start: Point(x: 50, y: 50), end: Point(x: 51, y: 50), control: Point(x: 50.5, y: 51)),
        ]
        for kind in invalid {
            let annotation = Annotation(kind: kind, style: .default)
            #expect(throws: RenderError.invalidGeometry) { try ArrowLayout.make(for: annotation) }
            let context = try #require(ChartFixture.context(width: 200, height: 150))
            #expect(throws: RenderError.invalidGeometry) { try AnnotationRenderer.draw([annotation], in: context) }
        }
        let straight = try ArrowLayout.make(for: Annotation(kind: .arrow(start: .zero, end: .zero), style: .default))
        #expect(straight.shaftInkPath.isEmpty && straight.headPath.isEmpty)
        #expect(!straight.hitTest(.zero, tolerance: 10))
    }

    @Test("The bend is painted and selectable while the empty endpoint chord is not")
    func paintedBend() throws {
        let annotation = Annotation(
            kind: .arrow(start: Point(x: 20, y: 30), end: Point(x: 180, y: 30), control: Point(x: 100, y: 130)),
            style: Annotation.Style(stroke: .red, lineWidth: 4, opacity: 0.5))
        let layout = try ArrowLayout.make(for: annotation)
        #expect(layout.hitTest(Point(x: 100, y: 80), tolerance: 0))
        #expect(!layout.hitTest(Point(x: 100, y: 30), tolerance: 3))
        let context = try #require(ChartFixture.context(width: 200, height: 150))
        context.translateBy(x: 0, y: 150)
        context.scaleBy(x: 1, y: -1)
        try AnnotationRenderer.draw([annotation], in: context)
        let raster = try pixels(try #require(context.makeImage()))
        #expect(raster.pixel(x: 100, y: 80).a >= 126)
        #expect(raster.pixel(x: 100, y: 30).a == 0)
        for y in 0..<150 {
            for x in 0..<200 where raster.pixel(x: x, y: y).a > 0 {
                #expect(raster.pixel(x: x, y: y).a <= 129, "overlap must retain one annotation opacity")
                #expect(Double(x + 1) >= layout.inkBounds.minX && Double(x) <= layout.inkBounds.maxX)
                #expect(Double(y + 1) >= layout.inkBounds.minY && Double(y) <= layout.inkBounds.maxY)
            }
        }
    }
}
