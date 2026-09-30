import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

// Failure modes (FR-11, PIX-01): sampling interpolated or zoom-dependent colors; sampling raw
// assets instead of the sanitized base; sampling a base that predates a redaction; ruler values
// in view points; an imported image gaining an invented Retina scale; a loupe that resamples;
// copying a color without an explicit action.
@Suite("Editor pixel tools (PIX-01)")
@MainActor
struct EditorPixelToolsTests {
    @Test("Finite document coordinates outside the integer range do not crash pixel tools")
    func oversizedCoordinates() async throws {
        let h = try await chartHarness()
        let layer = try #require(h.model.document.layers.first)
        h.model.setFrame(Rect(x: 1e20, y: 0, width: 32, height: 16), for: .layer(layer.id))
        h.model.fitCanvasToContent()
        h.model.setViewportSize(Size(width: 500, height: 400), backingScale: 1)
        h.model.inspect(at: Point(x: 5e19, y: 8))
        #expect(h.model.inspection == nil)
    }

    @Test("An oversized loupe radius is bounded by the image")
    func oversizedLoupeRadius() async throws {
        let h = try await chartHarness()
        h.model.inspect(at: Point(x: 8, y: 8))
        let loupe = try #require(h.model.loupe(radius: Int.max))
        #expect(loupe.image.width == h.model.baseImage?.width)
        #expect(loupe.image.height == h.model.baseImage?.height)
    }

    private func chartHarness(origin: AssetOrigin = .imported) async throws -> EditorHarness {
        let chart = try ChartFixture.colorChart(cell: 8)
        let h = EditorHarness(session: EditorFixtures.session(width: chart.width, height: chart.height, origin: origin))
        h.renderer.baseImage = chart
        await h.settle()
        #expect(h.model.isBaseCurrent)
        return h
    }

    @Test("Picked colors match the chart's encoded sRGB values at every zoom", arguments: [0.25, 1, 2, 8])
    func colorsMatchChart(zoom: Double) async throws {
        let h = try await chartHarness()
        h.model.setViewport(EditorViewport(zoom: zoom, offset: Point(x: 5, y: 9)))
        h.model.selectTool(.colorPicker)
        for row in 0..<ChartFixture.chartRows {
            for column in 0..<ChartFixture.chartColumns {
                h.click(Double(column * 8) + 4.5, Double(row * 8) + 4.5)
                let expected = ChartFixture.chartColors[row * ChartFixture.chartColumns + column]
                let picked = try #require(h.model.pickedColor)
                #expect(picked.hex == expected.hex)
                #expect(picked.rgbText == "\(expected.r) \(expected.g) \(expected.b)")
                #expect(picked.x == column * 8 + 4 && picked.y == row * 8 + 4)
            }
        }
        #expect(h.textClipboard.writes.isEmpty)
        #expect(h.model.copyPickedColor(asHex: true))
        #expect(h.textClipboard.writes == [ChartFixture.chartColors[7].hex])
    }

    @Test("The loupe is an exact crop of the sanitized base, never interpolated")
    func loupeIsNearestNeighbor() async throws {
        let h = try await chartHarness()
        let chart = try ChartFixture.colorChart(cell: 8)
        h.model.selectTool(.loupe)
        h.model.pointerMoved(to: Point(x: 8.2, y: 7.9))
        let loupe = try #require(h.model.loupe(radius: 2))
        #expect(loupe.originX == 6 && loupe.originY == 5)
        #expect(loupe.image.width == 5 && loupe.image.height == 5)
        for dy in 0..<5 {
            for dx in 0..<5 {
                #expect(
                    PixelSampler.color(atX: dx, y: dy, in: loupe.image)
                        == PixelSampler.color(atX: 6 + dx, y: 5 + dy, in: chart))
            }
        }
        // Clamped at the image corner.
        h.model.pointerMoved(to: Point(x: 0.5, y: 0.5))
        let corner = try #require(h.model.loupe(radius: 3))
        #expect(corner.originX == 0 && corner.originY == 0 && corner.image.width == 4)
    }

    @Test("Ruler distances are document pixels, snapped to pixel edges, at any zoom", arguments: [0.25, 8])
    func rulerInPixels(zoom: Double) async throws {
        let h = try await chartHarness()
        h.model.setViewport(EditorViewport(zoom: zoom))
        h.model.selectTool(.ruler)
        h.drag((0.2, 0.4), (29.8, 40.1))
        let ruler = try #require(h.model.ruler)
        #expect(ruler.dxPixels == 30 && ruler.dyPixels == 40 && ruler.distancePixels == 50)
        #expect(ruler.pointPixelScale == nil)
        #expect(ruler.distancePoints == nil)
    }

    @Test("Points are reported only for a capture with a known scale")
    func pointsOnlyForCaptures() async throws {
        let geometry = EditorFixtures.captureGeometry(width: 32, height: 16, scale: 2)
        let h = try await chartHarness(origin: .captured(geometry))
        h.model.selectTool(.ruler)
        h.drag((0, 0), (30, 40))
        let ruler = try #require(h.model.ruler)
        #expect(ruler.distancePixels == 50)
        #expect(ruler.distancePoints == 25)
        #expect(ruler.dxPoints == 15 && ruler.dyPoints == 20)

        // Scaling the only layer makes point conversion ambiguous: no points.
        h.model.select(.layer(try #require(h.model.document.layers.first?.id)))
        h.model.setLayerScale(2, for: try #require(h.model.document.layers.first?.id))
        #expect(h.model.measurementPointScale == nil)
    }

    @Test("Pasted and imported images never get a point scale")
    func pastedHasNoScale() async throws {
        let h = try await chartHarness(origin: .pasted)
        #expect(h.model.measurementPointScale == nil)
    }

    @Test("Sampling waits for a base of the current redaction state")
    func noSamplingOfStaleBase() async throws {
        let h = try await chartHarness()
        let pending = Pending<Result<CGImage, TestError>>()
        h.renderer.pending = pending
        h.model.selectTool(.redact)
        h.drag((0, 0), (8, 8))
        h.model.selectTool(.colorPicker)
        h.click(4, 4)
        #expect(h.model.pickedColor == nil)
        #expect(h.model.notice == .previewNotReady)
        await waitFor("re-render") { pending.waiterCount == 1 }
        pending.resolve(.success(try ChartFixture.solid(width: 32, height: 16, color: ChartFixture.Color(0, 0, 0))))
        await h.settle()
        h.click(4, 4)
        #expect(h.model.pickedColor?.hex == "#000000")
    }

    @Test("Clicks outside the canvas sample nothing")
    func outsideCanvas() async throws {
        let h = try await chartHarness()
        h.model.selectTool(.colorPicker)
        h.click(-1, 4)
        h.click(32, 4)
        #expect(h.model.pickedColor == nil)
    }
}
