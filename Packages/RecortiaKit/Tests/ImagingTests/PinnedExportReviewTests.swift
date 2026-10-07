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
        arguments: [0.0, -1.0, 0.5, 1.0000001, 0.9999999, 2.0, 8.0, 9.0, Double.nan, Double.infinity])
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

    @Test("Exporting the same pin twice gives identical bytes; only the filename follows the date")
    func deterministicEncoding() async throws {
        let image = try raster()
        let later = fixedExportDate.addingTimeInterval(3_600)
        for format in [ExportFormat.png, .jpeg(quality: 0.7)] {
            let first = try await pinned(image, ExportOptions(format: format))
            let second = try await pinned(image, ExportOptions(format: format), date: later)
            #expect(first.bytes == second.bytes, "no timestamp or random value in the encoding")
            #expect(first.suggestedFilename != second.suggestedFilename)
            #expect(first.pixelSize == PixelSize(width: image.width, height: image.height))
        }
    }

    @Test("A wide-gamut raster exports with allowlisted containers and no hidden representations")
    func wideGamutRaster() async throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(
            CGContext(
                data: nil, width: 20, height: 12, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.1, 0.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        let image = try #require(context.makeImage())

        let png = try await pinned(image)
        let chunks = try ContainerInspector.pngChunkTypes(png.bytes)
        #expect(Set(chunks).isSubset(of: ExportContainerTests.allowedPNGChunks), "unexpected chunks: \(chunks)")
        #expect(ContainerInspector.propertyKeys(png.bytes).isDisjoint(with: ExportContainerTests.forbiddenPropertyKeys))
        let jpeg = try await pinned(image, ExportOptions(format: .jpeg(quality: 0.9)))
        let markers = try ContainerInspector.jpegSegments(jpeg.bytes).segments.map(\.marker)
        #expect(Set(markers).isSubset(of: ExportContainerTests.allowedJPEGMarkers), "unexpected markers: \(markers)")
        #expect(png.pixelSize == PixelSize(width: 20, height: 12))
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

    @Test("The pin's real source, the renderer's 1x output, exports no RGB under alpha 0")
    func rendererOutputCarriesNoRGBUnderAlphaZero() async throws {
        let png = try ContainerCrafting.pngData(
            try ChartFixture.image(width: 4, height: 2, straightRGBA: Self.canaryInput()))
        let harness = ImagingHarness()
        let asset = await harness.store.insert(try ImageDecoder.decode(png), origin: .imported)
        var document = Document(asset: asset)
        document.canvasSize = Size(width: 6, height: 3)
        let raster = try await harness.renderer.render(document, scale: 1)
        let snapshot = try await harness.pipeline.snapshot(
            ofPinned: raster, exportID: DocumentID(), privacyEpoch: 0, options: ExportOptions(), date: fixedExportDate)
        try assertNoRGBUnderAlphaZero(snapshot, expectedTransparent: 8)
    }

    // The pinned entry point redraws whatever raster it is handed, so a raster that did not come
    // from `PrivacyRenderer` still exports only its visible pixels.
    @Test("A raw straight-alpha raster exports no RGB under alpha 0")
    func rawRasterIsNormalized() async throws {
        let image = try ChartFixture.image(width: 4, height: 2, straightRGBA: Self.canaryInput())
        let snapshot = try await pinned(image)
        try assertNoRGBUnderAlphaZero(snapshot, expectedTransparent: 4)
    }

    @Test("A transparent pinned raster flattens onto the JPEG background, not black")
    func jpegFlattensOnBackground() async throws {
        var input: [UInt8] = []
        for _ in 0..<16 { input += [0, 0, 0, 0] }
        let image = try ChartFixture.image(width: 4, height: 4, straightRGBA: input)
        let snapshot = try await pinned(image, ExportOptions(format: .jpeg(quality: 1), jpegBackground: .white))
        let pixels = try ContainerInspector.decodePixels(snapshot.bytes)
        let p = pixels.pixel(x: 1, y: 1)
        #expect(p.r > 240 && p.g > 240 && p.b > 240, "got \(p)")
    }
}
