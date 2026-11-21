import CoreGraphics
import Domain
import Foundation
import ImageIO
import RecortiaFixtures
import Testing

@testable import Imaging

/// RED-01/RED-02 for HEIC (B-9a): masks fill source pixels before the lossy encode, and the file
/// holds image items only, with none of the imported metadata.
@Suite(
    "HEIC exports are masked, flattened and free of metadata",
    .enabled(if: ExportCapabilities.encodesHEIC, "this Mac's ImageIO does not encode HEIC"))
struct HEICExportTests {
    static let allowedItemTypes: Set<String> = ["hvc1", "grid"]
    static let metadataKeys: Set<String> = ["{Exif}", "{ExifAux}", "{GPS}", "{IPTC}", "{MakerApple}"]
    /// What ImageIO's HEIC reader derives from the item structure itself, not from stored metadata.
    static let structuralTIFFKeys: Set<String> = ["Orientation", "TileWidth", "TileLength"]

    @Test("A secure mask over a planted secret holds its fill in the decoded HEIC, and no metadata survives")
    func maskedAndStripped() async throws {
        let jpeg = try ContainerCrafting.metadataRichJPEG(try ChartFixture.photographic(width: 1200, height: 900))
        // Control: the canaries and metadata dictionaries are present in the input.
        for canary in ContainerCrafting.metadataCanaries {
            #expect(ContainerInspector.contains(canary, in: jpeg), "fixture lacks \(canary)")
        }
        #expect(ContainerInspector.propertyKeys(jpeg).isSuperset(of: ["{GPS}", "{TIFF}", "{Exif}"]))

        let harness = ImagingHarness()
        let asset = await harness.store.insert(try ImageDecoder.decode(jpeg), origin: .imported)
        var session = DocumentSession(document: Document(asset: asset))
        let masked = Rect<DocumentSpace>(x: 400, y: 300, width: 200, height: 200)
        let options = ExportOptions(format: .heic(quality: 0.9))
        let unmasked = try decoded(try await harness.export(session, options))
        try session.addSecureMask(covering: masked)

        let snapshot = try await harness.export(session, options)
        #expect(snapshot.format == .heic(quality: 0.9))
        #expect(snapshot.suggestedFilename.hasSuffix(".heic"))
        let structure = try ContainerInspector.heicStructure(snapshot.bytes)
        #expect(Set(structure.itemTypes).isSubset(of: Self.allowedItemTypes), "items: \(structure.itemTypes)")
        #expect(!structure.itemTypes.isEmpty)
        for canary in ContainerCrafting.metadataCanaries {
            #expect(!ContainerInspector.contains(canary, in: snapshot.bytes), "\(canary) survived export")
        }
        #expect(!ContainerInspector.contains("Exif", in: snapshot.bytes))
        #expect(ContainerInspector.propertyKeys(snapshot.bytes).isDisjoint(with: Self.metadataKeys))
        let tiff = ContainerInspector.propertyKeys(snapshot.bytes, in: "{TIFF}")
        #expect(tiff.isSubset(of: Self.structuralTIFFKeys), "TIFF keys: \(tiff)")

        let pixels = try decoded(snapshot)
        #expect(pixels.width == 1200 && pixels.height == 900)
        for y in stride(from: 310, to: 490, by: 15) {
            for x in stride(from: 410, to: 590, by: 15) {
                // Control: the source is far from black there.
                #expect(unmasked.pixel(x: x, y: y).distance(to: color(0, 0, 0)) > 60)
                #expect(pixels.pixel(x: x, y: y).distance(to: color(0, 0, 0)) <= 12, "(\(x), \(y))")
            }
        }
    }

    @Test("Transparency is flattened against the opaque export background")
    func transparencyIsFlattened() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.geometryChart(width: 40, height: 30))
        var document = Document(asset: asset)
        document.canvasSize = Size(width: 60, height: 40)  // transparent margin around the image
        let snapshot = try await harness.export(
            DocumentSession(document: document),
            ExportOptions(format: .heic(quality: 0.9), jpegBackground: RGBA(r: 0, g: 200, b: 0, a: 255)))
        let pixels = try decoded(snapshot)
        #expect(pixels.pixel(x: 58, y: 38).distance(to: color(0, 200, 0)) <= 16, "\(pixels.pixel(x: 58, y: 38))")
        #expect(pixels.pixel(x: 58, y: 38).a == 255)
        #expect(try !ContainerInspector.heicStructure(snapshot.bytes).itemTypes.isEmpty)
    }

    @Test("Control: a HEIC carrying an Exif item fails the allowlist, ImageIO's plain output passes")
    func metadataItemIsRefused() throws {
        let image = try ChartFixture.geometryChart(width: 32, height: 24)
        let tagged = try ContainerCrafting.encode(
            [image], type: "public.heic", properties: ContainerCrafting.metadataProperties())
        let items = try ContainerInspector.heicStructure(tagged).itemTypes
        try #require(!Set(items).isSubset(of: Self.allowedItemTypes), "fixture has no metadata item: \(items)")
        #expect(throws: ExportError.encodingFailed) { try ExportContainerFilter.heic(tagged) }

        let plain = try ContainerCrafting.encode([image], type: "public.heic")
        #expect(try ExportContainerFilter.heic(plain) == plain)
        #expect(throws: ExportError.encodingFailed) { try ExportContainerFilter.heic(plain.prefix(plain.count - 3)) }
        #expect(throws: ExportError.encodingFailed) { try ExportContainerFilter.heic(Data("not a heic".utf8)) }
    }
}
