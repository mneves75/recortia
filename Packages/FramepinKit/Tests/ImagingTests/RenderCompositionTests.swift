import CoreGraphics
import Domain
import Foundation
import FramepinFixtures
import Testing

@testable import Imaging

@Suite("COMP-01: composite rendering")
struct RenderCompositionTests {
    static let gray = color(128, 128, 128)
    static let purple = color(150, 20, 200)
    static let magenta = RGBA(r: 255, g: 0, b: 255)
    static let q = ChartFixture.quadrantColors

    /// A: gray 100x80 at the origin. B: purple 80x40 at 0.75x, opacity 0.6, over A.
    /// C: a 40x20 geometry chart at 1.5x, opaque, over B. Canvas 200x120.
    private func composite(_ harness: ImagingHarness) async throws -> Document {
        let a = try await harness.add(try ChartFixture.solid(width: 100, height: 80, color: Self.gray))
        let b = try await harness.add(try ChartFixture.solid(width: 80, height: 40, color: Self.purple))
        let c = try await harness.add(try ChartFixture.geometryChart(width: 40, height: 20))
        return Document(
            assets: [a.id: a, b.id: b, c.id: c], canvasSize: Size(width: 200, height: 120),
            layers: [
                ImageLayer(assetID: a.id),
                ImageLayer(
                    assetID: b.id, placement: LayerPlacement(translation: Point(x: 60, y: 40), scale: 0.75),
                    opacity: 0.6),
                ImageLayer(assetID: c.id, placement: LayerPlacement(translation: Point(x: 110, y: 50), scale: 1.5)),
            ])
    }

    private static let presentation = Presentation(
        background: .linearGradient(
            from: RGBA(r: 10, g: 20, b: 200), to: RGBA(r: 250, g: 250, b: 250), angleDegrees: 0),
        padding: 16, cornerRadius: 12, shadow: Presentation.Shadow(radius: 8, offsetY: 6, opacity: 0.6))

    @Test("Layer order, opacity, aspect ratio, output size, background, corners, and shadow")
    func compositeLayout() async throws {
        let harness = ImagingHarness()
        var document = try await composite(harness)
        let content = try pixels(try await harness.renderer.render(document, scale: 1))
        #expect(content.width == 200 && content.height == 120)
        #expect(content.pixel(x: 20, y: 20) == Self.gray)
        #expect(content.pixel(x: 80, y: 55).distance(to: color(141, 63, 171)) <= 2)  // 0.6 purple over gray: B above A
        #expect(content.pixel(x: 113, y: 55).distance(to: Self.q[0]) <= 2)  // C above B
        #expect(content.pixel(x: 160, y: 75).distance(to: Self.q[3]) <= 2)

        // C keeps its 2:1 aspect ratio: 60x30 document units, measured from opaque coverage.
        let row = (100..<200).filter { content.pixel(x: $0, y: 70).a == 255 }
        let column = (0..<120).filter { content.pixel(x: 150, y: $0).a == 255 }
        #expect(row.count == 60 && row.first == 110)
        #expect(column.count == 30 && column.first == 50)

        document.presentation = Self.presentation
        let image = try await harness.renderer.render(document, scale: 1)
        #expect(image.width == 232 && image.height == 152)
        #expect(PixelSize(width: image.width, height: image.height) == document.outputPixelSize(exportScale: 1))
        let p = try pixels(image)
        #expect(p.pixel(x: 16 + 20, y: 16 + 20) == Self.gray)
        #expect(p.pixel(x: 0, y: 76).distance(to: color(10, 20, 200)) <= 8)
        #expect(p.pixel(x: 231, y: 76).distance(to: color(250, 250, 250)) <= 8)
        #expect(p.pixel(x: 17, y: 17) != Self.gray, "rounded corner must clip the content")
        #expect(p.pixel(x: 28, y: 28) == Self.gray)

        var flat = document
        flat.presentation.shadow = nil
        let noShadow = try pixels(try await harness.renderer.render(flat, scale: 1))
        let below = p.pixel(x: 116, y: 140), reference = noShadow.pixel(x: 116, y: 140)
        #expect(
            Int(below.r) + Int(below.g) + Int(below.b) < Int(reference.r) + Int(reference.g) + Int(reference.b) - 20)
    }

    @Test("Spotlight dims everything outside its rectangle and nothing inside")
    func spotlight() async throws {
        let harness = ImagingHarness()
        let document = try await composite(harness)
        var lit = document
        lit.callouts = [Callout(kind: .spotlight(Rect(x: 0, y: 0, width: 50, height: 40), dimOpacity: 0.5))]
        let plain = try pixels(try await harness.renderer.render(document, scale: 1))
        let dimmed = try pixels(try await harness.renderer.render(lit, scale: 1))
        #expect(dimmed.pixel(x: 20, y: 20) == plain.pixel(x: 20, y: 20))
        let outside = dimmed.pixel(x: 80, y: 55), original = plain.pixel(x: 80, y: 55)
        #expect(abs(Int(outside.r) - Int(original.r) / 2) <= 2)
        #expect(abs(Int(outside.b) - Int(original.b) / 2) <= 2)
    }

    @Test("A magnifier enlarges sanitized layers only: no annotations, no other callouts, no render cycle")
    func magnifierSamplesBaseOnly() async throws {
        let harness = ImagingHarness()
        var document = try await composite(harness)
        document.annotations = [
            Annotation(
                kind: .rectangle(Rect(x: 20, y: 60, width: 20, height: 10)),
                style: Annotation.Style(stroke: Self.magenta, fill: Self.magenta))
        ]
        document.callouts = [
            // Source: C's bottom-right (yellow) quadrant; destination: inside A.
            Callout(
                kind: .magnifier(
                    source: Rect(x: 150, y: 67, width: 10, height: 10),
                    destination: Rect(x: 5, y: 5, width: 40, height: 40))),
            // Source overlaps the first magnifier's destination and the magenta annotation.
            Callout(
                kind: .magnifier(
                    source: Rect(x: 10, y: 30, width: 30, height: 40),
                    destination: Rect(x: 130, y: 5, width: 30, height: 40))),
        ]
        let p = try pixels(try await harness.renderer.render(document, scale: 2))
        #expect(
            p.pixel(x: 50, y: 50).distance(to: Self.q[3]) <= 2, "first magnifier shows C's yellow quadrant, enlarged")
        // The second magnifier shows plain gray A where the first magnifier and the annotation are drawn.
        var sawMagenta = false, sawYellow = false
        for y in stride(from: 12, to: 88, by: 2) {
            for x in stride(from: 262, to: 318, by: 2) {
                let c = p.pixel(x: x, y: y)
                sawMagenta = sawMagenta || c.distance(to: color(255, 0, 255)) < 40
                sawYellow = sawYellow || c.distance(to: Self.q[3]) < 40
            }
        }
        #expect(!sawMagenta && !sawYellow)
        #expect(p.pixel(x: 290, y: 50).distance(to: Self.gray) <= 2)
    }

    @Test("Document crop selects the content region and keeps the aspect ratio")
    func crop() async throws {
        let harness = ImagingHarness()
        var document = try await composite(harness)
        document.crop = Rect(x: 50, y: 30, width: 100, height: 60)
        let image = try await harness.renderer.render(document, scale: 0.5)
        #expect(image.width == 50 && image.height == 30)
        let p = try pixels(image)
        #expect(p.pixel(x: 2, y: 2) == Self.gray)
        #expect(p.pixel(x: 47, y: 21).distance(to: Self.q[3]) <= 2)
    }

    @Test("renderBase covers the whole canvas without annotations, callouts, crop, or presentation")
    func renderBaseExcludesOverlays() async throws {
        let harness = ImagingHarness()
        var document = try await composite(harness)
        document.presentation = Self.presentation
        document.crop = Rect(x: 50, y: 30, width: 100, height: 60)
        document.resizeScale = 0.5
        document.annotations = [
            Annotation(
                kind: .rectangle(Rect(x: 0, y: 0, width: 30, height: 30)),
                style: Annotation.Style(stroke: Self.magenta, fill: Self.magenta))
        ]
        document.callouts = [Callout(kind: .spotlight(Rect(x: 0, y: 0, width: 5, height: 5), dimOpacity: 0.9))]
        let base = try await harness.renderer.renderBase(document, scale: 1)
        #expect(base.width == 200 && base.height == 120)
        let p = try pixels(base)
        #expect(p.pixel(x: 10, y: 10) == Self.gray)
        #expect(p.pixel(x: 190, y: 110) == color(0, 0, 0, 0))
    }
}
