import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
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

    @Test("An output border paints every edge once without changing dimensions", arguments: [1.0, 2.0])
    func outputBorder(scale: Double) async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 40, height: 30, color: Self.gray))
        var document = Document(
            assets: [asset.id: asset], canvasSize: Size(width: 40, height: 30),
            layers: [ImageLayer(assetID: asset.id)])
        document.presentation.border = Presentation.Border(width: 3, color: RGBA(r: 255, g: 0, b: 0, a: 128))

        let result = try pixels(try await harness.renderer.render(document, scale: scale))
        let width = Int(40 * scale)
        let height = Int(30 * scale)
        let border = Int(3 * scale)
        #expect(result.width == width && result.height == height)
        let expected = color(192, 64, 64)
        #expect(result.pixel(x: 0, y: 0).distance(to: expected) <= 2)
        #expect(result.pixel(x: width - 1, y: height - 1).distance(to: expected) <= 2)
        #expect(result.pixel(x: border - 1, y: height / 2).distance(to: expected) <= 2)
        #expect(result.pixel(x: width / 2, y: height - border).distance(to: expected) <= 2)
        #expect(result.pixel(x: border, y: height / 2) == Self.gray)
        #expect(result.pixel(x: width / 2, y: height - border - 1) == Self.gray)
    }

    @Test(
        "A rotated Unicode watermark stays inside its output corner and preserves transparency",
        arguments: [Presentation.Watermark.Position.topRight, .bottomLeft])
    func outputWatermark(position: Presentation.Watermark.Position) async throws {
        let harness = ImagingHarness()
        let width = 160
        let height = 100
        let asset = try await harness.add(
            try ChartFixture.solid(width: width, height: height, color: color(0, 0, 0, 0)))
        var document = Document(asset: asset)
        document.presentation.watermark = Presentation.Watermark(
            text: "Olá", position: position, opacity: 0.4, rotationDegrees: -27)

        let result = try pixels(try await harness.renderer.render(document, scale: 1))
        #expect(result.width == width && result.height == height)
        let ink: [(x: Int, y: Int, alpha: UInt8)] = (0..<height).flatMap { y in
            (0..<width).compactMap { x in
                let alpha = result.pixel(x: x, y: y).a
                return alpha == 0 ? nil : (x: x, y: y, alpha: alpha)
            }
        }
        #expect(ink.count > 20)
        let peakAlpha = try #require(ink.map { $0.alpha }.max())
        #expect((70...103).contains(peakAlpha))
        #expect(ink.allSatisfy { $0.x > 0 && $0.x < width - 1 && $0.y > 0 && $0.y < height - 1 })
        switch position {
        case .topRight: #expect(ink.allSatisfy { $0.x > width / 2 && $0.y < height / 2 })
        case .bottomLeft: #expect(ink.allSatisfy { $0.x < width / 2 && $0.y > height / 2 })
        default: Issue.record("Expected a corner fixture")
        }
    }

    @Test("Malformed output decoration is refused before rendering")
    func invalidOutputDecoration() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 40, height: 30, color: Self.gray))
        let base = Document(asset: asset)
        let invalid = [
            Presentation(watermark: Presentation.Watermark(text: "")),
            Presentation(watermark: Presentation.Watermark(text: "First\nSecond")),
            Presentation(watermark: Presentation.Watermark(text: String(repeating: "é", count: 129))),
            Presentation(watermark: Presentation.Watermark(text: String(repeating: "e\u{301}", count: 128))),
            Presentation(watermark: Presentation.Watermark(text: "Draft", rotationDegrees: .infinity)),
            Presentation(border: Presentation.Border(width: .nan)),
        ]
        for presentation in invalid {
            var document = base
            document.presentation = presentation
            do {
                _ = try await harness.renderer.render(document, scale: 1)
                Issue.record("Invalid output decoration rendered")
            } catch {
                #expect(error == .invalidGeometry)
            }
        }
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

    @Test(
        "An explicit crop that is empty or wholly off the canvas is invalid geometry, never the whole canvas",
        arguments: [
            Rect<DocumentSpace>(x: 200, y: 0, width: 20, height: 20),  // touches the edge only
            Rect<DocumentSpace>(x: 50, y: 30, width: 100, height: 0),  // zero height
        ])
    func rejectsNonintersectingCrop(crop: Rect<DocumentSpace>) async throws {
        let harness = ImagingHarness()
        var document = try await composite(harness)
        document.crop = crop
        await #expect(throws: RenderError.invalidGeometry) {
            try await harness.renderer.render(document, scale: 1)
        }
    }

    @Test("A partially intersecting crop still clips; an absent crop still means the whole canvas")
    func partialCropClipsAndAbsentCropIsWholeCanvas() async throws {
        let harness = ImagingHarness()
        var document = try await composite(harness)
        let whole = try await harness.renderer.render(document, scale: 1)
        #expect(whole.width == 200 && whole.height == 120)
        document.crop = Rect(x: 150, y: 80, width: 100, height: 100)  // only 50x40 lies on the canvas
        let clipped = try await harness.renderer.render(document, scale: 1)
        #expect(clipped.width == 50 && clipped.height == 40)
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
