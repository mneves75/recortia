import CoreGraphics
import Domain
import Foundation
import FramepinFixtures
import Testing

@testable import Imaging

@Suite("AnnotationRenderer: deterministic drawing shared by editor and export")
struct AnnotationRendererTests {
    private func draw(_ annotations: [Annotation], width: Int = 120, height: Int = 80) throws -> DecodedPixels {
        let context = try #require(ChartFixture.context(width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)  // document space: top-left origin, y down
        AnnotationRenderer.draw(annotations, in: context)
        return try pixels(try #require(context.makeImage()))
    }

    private func inked(_ p: DecodedPixels, in rect: FixtureRect) -> Int {
        var count = 0
        for y in max(0, rect.y)..<min(p.height, rect.maxY) {
            for x in max(0, rect.x)..<min(p.width, rect.maxX) where p.pixel(x: x, y: y).a > 0 { count += 1 }
        }
        return count
    }

    static let kinds: [Annotation] = [
        Annotation(
            kind: .text(.init(origin: Point(x: 10, y: 10), string: "Olá, ação!\nمرحبا 👋🏽 世界", fontSize: 14)),
            style: .default),
        Annotation(kind: .arrow(start: Point(x: 10, y: 70), end: Point(x: 100, y: 20)), style: .default),
        Annotation(kind: .rectangle(Rect(x: 20, y: 20, width: 40, height: 30)), style: .default),
        Annotation(
            kind: .ellipse(Rect(x: 20, y: 20, width: 40, height: 30)),
            style: Annotation.Style(stroke: .red, fill: .yellow)),
        Annotation(kind: .freehand([Point(x: 5, y: 5), Point(x: 30, y: 40), Point(x: 60, y: 10)]), style: .default),
        Annotation(kind: .highlighter([Point(x: 10, y: 40), Point(x: 110, y: 40)]), style: .highlighter),
        Annotation(kind: .step(center: Point(x: 60, y: 40), number: 7), style: .default),
    ]

    @Test("Every annotation kind draws inside its bounds, and drawing twice is byte-identical")
    func kindsDrawDeterministically() throws {
        for annotation in Self.kinds {
            let first = try draw([annotation])
            let second = try draw([annotation])
            #expect(first == second, "\(annotation.kind) is not deterministic")
            let b = annotation.outsetBounds
            let bounds = FixtureRect(
                x: Int(b.minX.rounded(.down)) - 2, y: Int(b.minY.rounded(.down)) - 2,
                width: Int(b.width.rounded(.up)) + 4, height: Int(b.height.rounded(.up)) + 4)
            #expect(inked(first, in: bounds) > 20, "\(annotation.kind) drew nothing")
        }
    }

    @Test("Arrows have a head: the end is thicker than the shaft")
    func arrowHasHead() throws {
        let p = try draw([
            Annotation(kind: .arrow(start: Point(x: 10, y: 40), end: Point(x: 110, y: 40)), style: .default)
        ])
        let shaft = (20..<60).filter { p.pixel(x: 40, y: $0).a > 0 }.count
        let head = (20..<60).filter { p.pixel(x: 102, y: $0).a > 0 }.count
        #expect(shaft >= 3 && head > shaft * 2)
    }

    @Test("Highlighter is translucent and numbered steps render their number")
    func highlighterAndStep() throws {
        let highlight = try draw([
            Annotation(kind: .highlighter([Point(x: 10, y: 40), Point(x: 110, y: 40)]), style: .highlighter)
        ])
        let a = highlight.pixel(x: 60, y: 40).a
        #expect(a > 90 && a < 140)

        let step = try draw([Annotation(kind: .step(center: Point(x: 60, y: 40), number: 7), style: .default)])
        let other = try draw([Annotation(kind: .step(center: Point(x: 60, y: 40), number: 3), style: .default)])
        #expect(step != other, "the number must be visible")
        #expect(step.pixel(x: 60 - 12, y: 40).distance(to: RGBA.red.fixtureColor) <= 2)
    }

    @Test("Text wraps to more lines when maxWidth is set, and right-to-left text renders")
    func textLayout() throws {
        func inkedRows(_ p: DecodedPixels) -> Int {
            (0..<p.height).filter { y in (0..<p.width).contains { p.pixel(x: $0, y: y).a > 0 } }.count
        }
        let text = "one two three four five six"
        let wide = try draw(
            [Annotation(kind: .text(.init(origin: Point(x: 2, y: 2), string: text, fontSize: 12)), style: .default)],
            width: 240)
        let narrow = try draw(
            [
                Annotation(
                    kind: .text(.init(origin: Point(x: 2, y: 2), string: text, fontSize: 12, maxWidth: 60)),
                    style: .default)
            ], width: 240)
        #expect(inkedRows(narrow) > inkedRows(wide) * 2)
        let rtl = try draw([
            Annotation(
                kind: .text(.init(origin: Point(x: 2, y: 2), string: "שלום עולם", fontSize: 16)), style: .default)
        ])
        #expect(inked(rtl, in: FixtureRect(x: 0, y: 0, width: 120, height: 30)) > 30)
    }

    @Test("Non-finite geometry is skipped instead of drawn or crashing")
    func nonFiniteIsSkipped() throws {
        let p = try draw([
            Annotation(kind: .rectangle(Rect(x: .nan, y: 0, width: 10, height: .infinity)), style: .default)
        ])
        #expect(inked(p, in: FixtureRect(x: 0, y: 0, width: 120, height: 80)) == 0)
    }
}

extension RGBA {
    var fixtureColor: ChartFixture.Color { ChartFixture.Color(r, g, b, a) }
}
