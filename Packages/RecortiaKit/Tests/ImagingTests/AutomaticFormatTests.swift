import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Failure modes (FR-07, Automatic format): a JPEG kept for a PNG that is only a little larger, or
// for one under the size floor; a boundary ratio rounding toward JPEG; transparency flattened
// away because JPEG was smaller; the snapshot or its name claiming a format its bytes are not.
@Suite("FR-07: Automatic format keeps PNG unless a JPEG is much smaller")
struct AutomaticFormatTests {
    private static let automatic = ExportOptions(automaticFormat: true)

    @Test("The size rule needs a PNG over 0.5 MB and more than 4x, or over 2 MB and more than 2x")
    func sizeRule() {
        let cases: [(png: Int, jpeg: Int, keepsJPEG: Bool)] = [
            (500_000, 1, false),  // not over 0.5 MB
            (500_001, 125_000, true),  // just over 4x
            (1_000_000, 250_000, false),  // exactly 4x
            (1_000_000, 249_999, true),
            (2_000_000, 999_999, false),  // not over 2 MB, and under 4x
            (3_000_000, 1_500_000, false),  // exactly 2x
            (3_000_000, 1_499_999, true),
            (2_000_001, 1_000_000, true),
            (10_000_000, 10_000_000, false),
        ]
        for item in cases {
            #expect(
                AutomaticFormatRule.keepsJPEG(pngByteCount: item.png, jpegByteCount: item.jpeg) == item.keepsJPEG,
                "\(item.png) / \(item.jpeg)")
        }
    }

    @Test("A flat image stays PNG under its own name")
    func flatStaysPNG() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 1200, height: 900, color: color(40, 90, 160)))
        let snapshot = try await harness.export(DocumentSession(document: Document(asset: asset)), Self.automatic)
        #expect(snapshot.format == .png)
        #expect(snapshot.bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(snapshot.suggestedFilename.hasSuffix(".png"))
    }

    @Test("A photo-like image becomes the same JPEG a fixed 0.92 export makes, named .jpg")
    func noisyBecomesJPEG() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.photographic(width: 1200, height: 900))
        let session = DocumentSession(document: Document(asset: asset))
        let png = try await harness.export(session, ExportOptions(format: .png))
        let jpeg = try await harness.export(session, ExportOptions(format: .jpeg(quality: 0.92)))
        // Control: the fixture is one the rule turns into a JPEG.
        try #require(AutomaticFormatRule.keepsJPEG(pngByteCount: png.bytes.count, jpegByteCount: jpeg.bytes.count))

        let snapshot = try await harness.export(session, Self.automatic)
        #expect(snapshot.format == .jpeg(quality: AutomaticFormatRule.jpegQuality))
        #expect(snapshot.bytes == jpeg.bytes)
        #expect(snapshot.suggestedFilename.hasSuffix(".jpg"))
    }

    @Test("Any transparency keeps PNG, even where the rule would pick JPEG")
    func transparencyStaysPNG() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.photographic(width: 1200, height: 900))
        // One transparent column to the right of the opaque photo.
        let session = DocumentSession(
            document: Document(
                assets: [asset.id: asset], canvasSize: Size(width: 1201, height: 900),
                layers: [ImageLayer(assetID: asset.id)]))
        let png = try await harness.export(session, ExportOptions(format: .png))
        let jpeg = try await harness.export(session, ExportOptions(format: .jpeg(quality: 0.92)))
        try #require(AutomaticFormatRule.keepsJPEG(pngByteCount: png.bytes.count, jpegByteCount: jpeg.bytes.count))

        let snapshot = try await harness.export(session, Self.automatic)
        #expect(snapshot.format == .png)
        #expect(snapshot.bytes == png.bytes)
        #expect(try decoded(snapshot).pixel(x: 1200, y: 450).a == 0)
    }

    @Test("A raster with one translucent pixel is not opaque")
    func rasterOpacity() throws {
        var bytes = [UInt8](repeating: 255, count: 8 * 8 * 4)
        #expect(try RenderRaster(image: try ChartFixture.image(width: 8, height: 8, premultipliedRGBA: bytes)).isOpaque)
        bytes[(5 * 8 + 3) * 4 + 3] = 254
        bytes[(5 * 8 + 3) * 4] = 254
        bytes[(5 * 8 + 3) * 4 + 1] = 254
        bytes[(5 * 8 + 3) * 4 + 2] = 254
        #expect(
            !(try RenderRaster(image: try ChartFixture.image(width: 8, height: 8, premultipliedRGBA: bytes)).isOpaque))
    }
}
