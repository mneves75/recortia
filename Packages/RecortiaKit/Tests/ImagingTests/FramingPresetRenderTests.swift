import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Failure modes (FR-13, A-8): the exported pixels miss the preset's size or ratio; the content is
// not where `outputFrame` says; balance centres the box instead of the window, moves content with
// no opaque pixel, pushes the content box out of the output or moves anything else; the radial
// gradient is off centre or missing; a preset changes the bytes of a Free export.
@Suite("Framing presets, balance and radial gradient (FR-13)")
struct FramingPresetRenderTests {
    static let body = ChartFixture.Color(40, 90, 200)
    static let background = RGBA(r: 250, g: 240, b: 10)

    /// 60 × 40: an opaque body in the top-left 40 × 30, a transparent margin to its right and a
    /// half-black "shadow" under it, like a window captured with its shadow.
    static func windowLike() throws -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<40 {
            for x in 0..<60 {
                if x < 40, y < 30 {
                    bytes += [body.r, body.g, body.b, 255]
                } else if y >= 30, x < 44 {
                    bytes += [0, 0, 0, 128]
                } else {
                    bytes += [0, 0, 0, 0]
                }
            }
        }
        return try ChartFixture.image(width: 60, height: 40, straightRGBA: bytes)
    }

    /// The bounds of the pixels that are exactly the body colour.
    static func bodyBounds(_ p: DecodedPixels) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<p.height {
            for x in 0..<p.width where p.straight(x: x, y: y) == body {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    private func render(_ image: CGImage, _ presentation: Presentation) async throws -> DecodedPixels {
        let harness = ImagingHarness()
        let asset = try await harness.add(image)
        var document = Document(asset: asset)
        document.presentation = presentation
        let rendered = try await harness.renderer.render(document, scale: 1)
        #expect(
            PixelSize(width: rendered.width, height: rendered.height) == document.outputPixelSize(exportScale: 1))
        return try pixels(rendered)
    }

    @Test("Without balance the content box is centred; with it the opaque body is")
    func balance() async throws {
        let image = try Self.windowLike()
        let framing = Presentation(background: .solid(Self.background), padding: 10, aspect: .square)
        // 60 × 40 + 2 × 10 → 80 × 60 → 1:1 at 80. The box sits at (10, 20).
        var off = framing
        off.balancesContent = false
        let boxed = try await render(image, off)
        #expect(boxed.width == 80 && boxed.height == 80)
        let box = try #require(Self.bodyBounds(boxed))
        #expect(box.minX == 10 && box.minY == 20 && box.maxX == 49 && box.maxY == 49)

        // Balanced: the 40 × 30 body moves to (20, 25), equal margins on both axes.
        let balanced = try await render(image, framing)
        let body = try #require(Self.bodyBounds(balanced))
        #expect(body.minX == 20 && body.minY == 25 && body.maxX == 59 && body.maxY == 54)
        #expect(body.minX == 79 - body.maxX && body.minY == 79 - body.maxY)
        // The translucent shadow moved with the body: still directly under it, over the background.
        let shadow = balanced.straight(x: 30, y: 57)
        #expect(shadow.distance(to: ChartFixture.Color(125, 120, 5)) <= 2, "\(shadow)")
        #expect(balanced.straight(x: 0, y: 0) == ChartFixture.Color(250, 240, 10))
    }

    @Test("Balance is limited so the content box never leaves the output")
    func balanceLimit() async throws {
        // A 4 × 4 body in the top-left corner of an 80 × 40 box, framed 16:9 without padding: the
        // output is 80 × 45 and the box sits at (0, 2). Centring the body would need (38, 18); the
        // box has no horizontal room and 3 pixels below it.
        var bytes = [UInt8](repeating: 0, count: 80 * 40 * 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let i = (y * 80 + x) * 4
                bytes.replaceSubrange(i..<i + 4, with: [Self.body.r, Self.body.g, Self.body.b, 255])
            }
        }
        let image = try ChartFixture.image(width: 80, height: 40, straightRGBA: bytes)
        let p = try await render(image, Presentation(background: .solid(Self.background), aspect: .landscape16x9))
        #expect(p.width == 80 && p.height == 45)
        let body = try #require(Self.bodyBounds(p))
        #expect(body.minX == 0 && body.minY == 5, "\(body)")
    }

    @Test("Content without a fully opaque pixel is not moved by balance")
    func noOpaquePixel() async throws {
        let bytes = [UInt8]((0..<(20 * 10)).flatMap { i in i % 20 < 5 ? [200, 0, 0, 200] : [0, 0, 0, 0] })
        let image = try ChartFixture.image(width: 20, height: 10, straightRGBA: bytes)
        var off = Presentation(aspect: .square)
        off.balancesContent = false
        let balanced = try await render(image, Presentation(aspect: .square))
        let boxed = try await render(image, off)
        #expect(balanced == boxed)
    }

    @Test("A radial gradient has its centre colour in the middle and its edge colour at the corners")
    func radialGradient() async throws {
        // Fully transparent content: the background shows through everywhere.
        let image = try ChartFixture.image(
            width: 10, height: 10, straightRGBA: [UInt8](repeating: 0, count: 10 * 10 * 4))
        let center = RGBA(r: 255, g: 0, b: 0), edge = RGBA(r: 0, g: 0, b: 255)
        let p = try await render(
            image, Presentation(background: .radialGradient(center: center, edge: edge), padding: 40))
        #expect(p.width == 90 && p.height == 90)
        #expect(p.straight(x: 45, y: 45).distance(to: ChartFixture.Color(255, 0, 0)) <= 6)
        for (x, y) in [(0, 0), (89, 0), (0, 89), (89, 89)] {
            #expect(p.straight(x: x, y: y).distance(to: ChartFixture.Color(0, 0, 255)) <= 6, "corner \(x),\(y)")
        }
        // Symmetric about the middle, and opaque everywhere.
        #expect(p.straight(x: 45, y: 5).distance(to: p.straight(x: 5, y: 45)) <= 1)
        #expect(p.straight(x: 45, y: 5).distance(to: p.straight(x: 84, y: 45)) <= 1)
        let mid = p.straight(x: 45, y: 15)
        #expect(mid.r > 0 && mid.r < 255 && mid.b > 0 && mid.b < 255 && mid.a == 255, "\(mid)")
    }

    @Test(
        "Exported PNGs keep the preset's exact size and centre the content",
        arguments: [
            (FramingAspect.square, 120, 120, 15, 30), (.portrait9x16, 126, 224, 18, 82),
        ])
    func export(aspect: FramingAspect, width: Int, height: Int, x: Int, y: Int) async throws {
        let harness = ImagingHarness()
        let chart = try ChartFixture.geometryChart(width: 90, height: 60)
        let asset = try await harness.add(chart)
        var document = Document(asset: asset)
        document.presentation = Presentation(background: .solid(Self.background), padding: 15, aspect: aspect)
        let snapshot = try await harness.export(DocumentSession(document: document))
        let p = try decoded(snapshot)
        #expect(p.width == width && p.height == height)
        #expect(snapshot.pixelSize == PixelSize(width: width, height: height))
        let quadrants = ChartFixture.quadrantColors
        // Each content corner lands at the frame's origin; the pixel beside it is background.
        #expect(p.pixel(x: x + 2, y: y + 2).distance(to: quadrants[0]) <= 2)
        #expect(p.pixel(x: x + 87, y: y + 2).distance(to: quadrants[1]) <= 2)
        #expect(p.pixel(x: x + 2, y: y + 57).distance(to: quadrants[2]) <= 2)
        #expect(p.pixel(x: x + 87, y: y + 57).distance(to: quadrants[3]) <= 2)
        let yellow = ChartFixture.Color(250, 240, 10)
        for (px, py) in [(x - 1, y + 30), (x + 90, y + 30), (x + 45, y - 1), (x + 45, y + 60), (0, 0)] {
            #expect(p.pixel(x: px, y: py) == yellow, "background at \(px),\(py)")
        }
        // Equal margins: the content is centred (an opaque chart balances like its box).
        #expect(abs((width - x - 90) - x) <= 1 && abs((height - y - 60) - y) <= 1)
    }

    @Test("Free framing renders the same bytes whether or not balance is on")
    func freeUnchanged() async throws {
        let image = try Self.windowLike()
        var off = Presentation(background: .solid(Self.background), padding: 10)
        off.balancesContent = false
        let on = try await render(image, Presentation(background: .solid(Self.background), padding: 10))
        #expect(on == (try await render(image, off)))
        let box = try #require(Self.bodyBounds(on))
        #expect(box.minX == 10 && box.minY == 10)
    }
}
