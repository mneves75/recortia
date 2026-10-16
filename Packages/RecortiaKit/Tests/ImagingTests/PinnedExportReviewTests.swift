import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Independent review of PIN-02 / RED-02 for `ExportPipeline.snapshot(ofPinned:)`. Failure modes:
// a scale other than the pinned raster's own size slipping through validation; two exports of the
// same pin differing in more than the filename; a wide-gamut or transparent raster carrying
// hidden representations into the shared encoder; bad options accepted for the pinned path.
@Suite("Review: pinned raster export hardening (PIN-02, RED-02)")
struct PinnedExportReviewTests {
    private func raster(width: Int = 24, height: Int = 16) throws -> CGImage {
        try ChartFixture.geometryChart(width: width, height: height)
    }

    private func pinned(
        _ image: CGImage, _ options: ExportOptions = ExportOptions(), date: Date = fixedExportDate
    ) async throws -> ShareSnapshot {
        try await ImagingHarness().pipeline.snapshot(
            ofPinned: image, exportID: DocumentID(), privacyEpoch: 3, options: options, date: date)
    }

    @Test(
        "Any scale other than exactly 1 is refused for a pinned raster",
        arguments: [0.9999999, 1.0000001, Double.nan])
    func onlyUnitScale(scale: Double) async throws {
        let image = try raster()
        await #expect(throws: ExportError.invalidOptions(.invalidScale)) {
            try await pinned(image, ExportOptions(scale: scale))
        }
    }

    @Test("A translucent JPEG background and a bad quality are refused, as for documents")
    func invalidOptionsRefused() async throws {
        let image = try raster()
        await #expect(throws: ExportError.invalidOptions(.translucentJPEGBackground)) {
            try await pinned(
                image, ExportOptions(format: .jpeg(quality: 0.8), jpegBackground: RGBA(r: 1, g: 1, b: 1, a: 10)))
        }
        for quality in [-0.1, 1.1, Double.nan] {
            await #expect(throws: ExportError.invalidOptions(.invalidQuality)) {
                try await pinned(image, ExportOptions(format: .jpeg(quality: quality)))
            }
        }
    }

    /// Straight-alpha input whose fully transparent pixels store vivid RGB.
    private static func canaryInput() -> [UInt8] {
        var input: [UInt8] = []
        for i in 0..<8 { input += i % 2 == 0 ? [250, 10, 200, 0] : [30, 140, 90, 255] }
        return input
    }

    private func assertNoRGBUnderAlphaZero(_ snapshot: ShareSnapshot, expectedTransparent: Int) throws {
        let exported = try #require(ContainerInspector.straightRGBAIfAvailable(snapshot.bytes))
        var transparent = 0
        for y in 0..<exported.height {
            for x in 0..<exported.width where exported.pixel(x: x, y: y).a == 0 {
                transparent += 1
                #expect(exported.pixel(x: x, y: y) == ChartFixture.Color(0, 0, 0, 0), "RGB under alpha 0 leaked")
            }
        }
        #expect(transparent >= expectedTransparent)
    }

    // The pinned entry point redraws whatever raster it is handed, so a raster that did not come
    // from `PrivacyRenderer` still exports only its visible pixels.
    @Test("A raw straight-alpha raster exports no RGB under alpha 0")
    func rawRasterIsNormalized() async throws {
        let image = try ChartFixture.image(width: 4, height: 2, straightRGBA: Self.canaryInput())
        let snapshot = try await pinned(image)
        try assertNoRGBUnderAlphaZero(snapshot, expectedTransparent: 4)
    }

}
