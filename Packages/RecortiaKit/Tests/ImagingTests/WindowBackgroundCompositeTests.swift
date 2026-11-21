import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Failure modes (FR-02, Settings › Capture › Window background): the colour is mixed into the
// stored source pixels, so a secure mask over a transparent corner is tinted or a recapture
// inherits it; the export keeps transparent or half-transparent pixels; the colour is composited
// twice, which darkens the shadow; a region or display capture or an imported image gets it.
@Suite("Window capture background")
struct WindowBackgroundCompositeTests {
    static let width = 40, height = 30
    static let body = ChartFixture.Color(40, 90, 200)
    static let background = RGBA(r: 250, g: 240, b: 10)
    static let maskFill = RGBA(r: 12, g: 34, b: 56)

    /// A window as a capture with its shadow delivers it: transparent 6-pixel corners, a black
    /// shadow at half opacity in the bottom 6 rows, an opaque body.
    static func windowPixels() -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let corner = (x < 6 || x >= width - 6) && (y < 6 || y >= height - 6)
                if corner {
                    bytes += [0, 0, 0, 0]
                } else if y >= height - 6 {
                    bytes += [0, 0, 0, 128]
                } else {
                    bytes += [body.r, body.g, body.b, 255]
                }
            }
        }
        return bytes
    }

    static func geometry(_ source: CaptureSource) -> CaptureGeometry {
        CaptureGeometry(
            source: source, desktopBounds: Rect(x: 0, y: 0, width: Double(width), height: Double(height)),
            pointPixelScale: 1, pixelSize: PixelSize(width: width, height: height),
            capturedAt: Date(timeIntervalSince1970: 0))
    }

    private func export(
        _ origin: AssetOrigin, _ background: WindowCaptureBackground, mask: Rect<DocumentSpace>? = nil,
        harness: ImagingHarness = ImagingHarness()
    ) async throws -> (DecodedPixels, ShareSnapshot) {
        let image = try ChartFixture.image(width: Self.width, height: Self.height, straightRGBA: Self.windowPixels())
        let asset = try await harness.add(image, origin: origin)
        var session = DocumentSession(document: Document(capture: asset, windowBackground: background))
        if let mask { try session.addSecureMask(covering: mask, fill: Self.maskFill) }
        let snapshot = try await harness.export(session)
        return (try decoded(snapshot), snapshot)
    }

    @Test("A solid background fills the corners, sits under the shadow once and leaves no alpha")
    func solidBackground() async throws {
        let (pixels, _) = try await export(
            .captured(Self.geometry(.window(id: 7, displayID: 1))), .solid(Self.background))
        #expect(pixels.width == Self.width && pixels.height == Self.height, "no padding is added")
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                #expect(pixels.pixel(x: x, y: y).a == 255, "pixel \(x),\(y) keeps transparency")
            }
        }
        let expectedCorner = ChartFixture.Color(250, 240, 10)
        #expect(pixels.straight(x: 0, y: 0) == expectedCorner)
        #expect(pixels.straight(x: Self.width - 1, y: Self.height - 1) == expectedCorner)
        #expect(pixels.straight(x: 20, y: 10).distance(to: Self.body) <= 1, "the opaque body is unchanged")
        // Half-black shadow over the colour once: each channel halves (one pass), not quarters.
        let shadow = pixels.straight(x: 20, y: Self.height - 2)
        #expect(shadow.distance(to: ChartFixture.Color(125, 120, 5)) <= 2, "\(shadow)")
    }

    @Test("A secure mask over a transparent corner shows its own opaque fill, not the background")
    func maskStaysOpaqueOverCorner() async throws {
        let mask = Rect<DocumentSpace>(x: 0, y: 0, width: 10, height: 10)
        let (pixels, _) = try await export(
            .captured(Self.geometry(.window(id: 7, displayID: 1))), .solid(Self.background), mask: mask)
        let fill = ChartFixture.Color(Self.maskFill.r, Self.maskFill.g, Self.maskFill.b)
        for (x, y) in [(0, 0), (3, 3), (9, 9), (5, 8)] {
            #expect(pixels.straight(x: x, y: y) == fill, "masked pixel \(x),\(y)")
        }
        #expect(pixels.straight(x: Self.width - 1, y: 0) == ChartFixture.Color(250, 240, 10))
    }

    @Test("Exporting twice gives identical bytes: the colour is part of the rendering, not the source")
    func compositeIsNotCumulative() async throws {
        let harness = ImagingHarness()
        let origin = AssetOrigin.captured(Self.geometry(.window(id: 7, displayID: 1)))
        let first = try await export(origin, .solid(Self.background), harness: harness).1
        let second = try await export(origin, .solid(Self.background), harness: harness).1
        #expect(first.bytes == second.bytes)
        let plain = try await export(origin, .transparent, harness: harness).0
        #expect(plain.pixel(x: 0, y: 0).a == 0, "the stored window still has transparent corners")
    }

    @Test(
        "Only window captures get the background; Transparent keeps today's corners",
        arguments: [
            AssetOrigin.captured(WindowBackgroundCompositeTests.geometry(.region(displayID: 1))),
            .captured(WindowBackgroundCompositeTests.geometry(.display(id: 1))), .imported, .pasted,
        ])
    func otherSourcesStayTransparent(origin: AssetOrigin) async throws {
        let (pixels, _) = try await export(origin, .solid(Self.background))
        #expect(pixels.pixel(x: 0, y: 0).a == 0)
        let (window, _) = try await export(
            .captured(Self.geometry(.window(id: 7, displayID: 1))), .transparent)
        #expect(window.pixel(x: 0, y: 0).a == 0)
        #expect(window.pixel(x: 20, y: Self.height - 2).a == 128)
    }
}
