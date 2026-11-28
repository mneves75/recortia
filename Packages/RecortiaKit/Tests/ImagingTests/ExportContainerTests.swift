import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("RED-02: exports carry no hidden original representations")
struct ExportContainerTests {
    static let allowedPNGChunks: Set<String> = ["IHDR", "PLTE", "tRNS", "sRGB", "iCCP", "gAMA", "cHRM", "IDAT", "IEND"]
    static let forbiddenPNGChunks: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME", "iDOT", "pHYs"]
    /// SOI, APP0 (JFIF), APP2 (ICC), DQT, SOF0-3/5-7/9-11/13-15, DHT, DRI, SOS.
    static let allowedJPEGMarkers: Set<UInt8> = Set([0xD8, 0xE0, 0xE2, 0xDB, 0xC4, 0xDD, 0xDA]).union(
        Set(0xC0...0xCF).subtracting([0xC4, 0xC8, 0xCC]))
    static let forbiddenPropertyKeys: Set<String> = [
        "{Exif}", "{ExifAux}", "{GPS}", "{TIFF}", "{IPTC}", "{MakerApple}",
    ]

    private func sampleSession(_ harness: ImagingHarness) async throws -> DocumentSession {
        let asset = try await harness.add(try ChartFixture.geometryChart(width: 40, height: 30))
        var document = Document(asset: asset)
        document.annotations = [
            Annotation(
                kind: .text(.init(origin: Point(x: 2, y: 2), string: "OCR-LIKE TEXT", fontSize: 8)), style: .default)
        ]
        var session = DocumentSession(document: document)
        try session.addSecureMask(covering: Rect(x: 5, y: 5, width: 10, height: 10))
        return session
    }

    @Test("PNG export contains only allowlisted chunks and keeps sRGB interpretation")
    func pngChunksAreAllowlisted() async throws {
        let harness = ImagingHarness()
        let snapshot = try await harness.export(try await sampleSession(harness))
        let chunks = try ContainerInspector.pngChunkTypes(snapshot.bytes)
        #expect(Set(chunks).isSubset(of: Self.allowedPNGChunks), "unexpected chunks: \(chunks)")
        #expect(Set(chunks).isDisjoint(with: Self.forbiddenPNGChunks))
        #expect(chunks.first == "IHDR" && chunks.last == "IEND")
        #expect(chunks.contains("sRGB") || chunks.contains("iCCP"), "export lost its sRGB interpretation")
        #expect(ContainerInspector.propertyKeys(snapshot.bytes).isDisjoint(with: Self.forbiddenPropertyKeys))
    }

    @Test("JPEG export has no APP1/APP13/COM segments and ends with EOI")
    func jpegSegmentsAreAllowlisted() async throws {
        let harness = ImagingHarness()
        let snapshot = try await harness.export(
            try await sampleSession(harness), ExportOptions(format: .jpeg(quality: 0.85)))
        let (segments, endsWithEOI) = try ContainerInspector.jpegSegments(snapshot.bytes)
        let markers = Set(segments.map(\.marker))
        #expect(markers.isSubset(of: Self.allowedJPEGMarkers), "unexpected markers: \(segments)")
        #expect(!markers.contains(0xE1) && !markers.contains(0xED) && !markers.contains(0xFE))
        #expect(segments.filter { $0.marker == 0xE0 }.allSatisfy { $0.identifier.hasPrefix("JFIF") })
        #expect(segments.filter { $0.marker == 0xE2 }.allSatisfy { $0.identifier.hasPrefix("ICC_PROFILE") })
        #expect(endsWithEOI)
        #expect(ContainerInspector.propertyKeys(snapshot.bytes).isDisjoint(with: Self.forbiddenPropertyKeys))
    }

    @Test("Control: ImageIO's own encoder output would fail the allowlists")
    func rawImageIOOutputIsCaught() throws {
        let image = try ChartFixture.geometryChart(width: 16, height: 16)
        let png = try ContainerCrafting.pngData(image)
        let jpeg = try ContainerCrafting.jpegData(image)
        #expect(!Set(try ContainerInspector.pngChunkTypes(png)).isSubset(of: Self.allowedPNGChunks))
        #expect(
            !Set(try ContainerInspector.jpegSegments(jpeg).segments.map(\.marker)).isSubset(of: Self.allowedJPEGMarkers)
        )
    }

    @Test("Fully transparent exported pixels carry RGB 0, even when the input stored RGB under alpha 0")
    func transparentPixelsCarryNoRGB() async throws {
        // 4x2 straight-alpha input: every other pixel is fully transparent but stores vivid RGB.
        var input: [UInt8] = []
        for i in 0..<8 { input += i % 2 == 0 ? [250, 10, 200, 0] : [30, 140, 90, 255] }
        let png = try ContainerCrafting.pngData(try ChartFixture.image(width: 4, height: 2, straightRGBA: input))
        // Control: the input really stores RGB under alpha 0, and the raw reader can see it.
        let raw = try #require(ContainerInspector.straightRGBAIfAvailable(png))
        #expect(raw.pixel(x: 0, y: 0) == color(250, 10, 200, 0))

        let harness = ImagingHarness()
        let decoded = try ImageDecoder.decode(png)
        let asset = await harness.store.insert(decoded, origin: .imported)
        var document = Document(asset: asset)
        document.canvasSize = Size(width: 6, height: 3)  // transparent canvas margin as well
        let snapshot = try await harness.export(DocumentSession(document: document))
        let exported = try #require(ContainerInspector.straightRGBAIfAvailable(snapshot.bytes))
        var transparentCount = 0
        for y in 0..<exported.height {
            for x in 0..<exported.width where exported.pixel(x: x, y: y).a == 0 {
                transparentCount += 1
                #expect(exported.pixel(x: x, y: y) == color(0, 0, 0, 0))
            }
        }
        #expect(transparentCount >= 8)
        #expect(exported.pixel(x: 1, y: 0) == color(30, 140, 90, 255))
    }

    @Test("An opaque PNG export drops only the alpha channel; one translucent pixel keeps it")
    func opaqueExportsCarryNoAlphaChannel() async throws {
        var pixels: [UInt8] = []
        for i in 0..<64 { pixels += [UInt8(i * 3), UInt8(255 - i), UInt8(i % 7 * 30), 255] }
        var translucent = pixels
        translucent[27 * 4 + 3] = 254
        // IHDR color type (byte 25): 2 is RGB, 6 is RGBA.
        for (input, colorType) in [(pixels, UInt8(2)), (translucent, UInt8(6))] {
            let harness = ImagingHarness()
            let image = try ChartFixture.image(width: 8, height: 8, straightRGBA: input)
            let asset = try await harness.add(image)
            let snapshot = try await harness.export(DocumentSession(document: Document(asset: asset)))
            #expect(snapshot.bytes[snapshot.bytes.startIndex + 25] == colorType)
            let exported = try ContainerInspector.decodePixels(snapshot.bytes)
            if colorType == 2 {
                #expect(exported == (try ContainerInspector.pixels(of: image)))
            } else {
                #expect(exported.pixel(x: 3, y: 3).a == 254)
            }
        }
        #expect(!PNGRowFilter.prefersUnfiltered(Data(count: 63), width: 4, height: 4, bytesPerRow: 16), "short buffer")
        // Odd width: each row's last pixel lies outside the two-pixel loads; row padding is ignored.
        var odd = [UInt8](repeating: 255, count: 2 * 16)
        for row in 0..<2 { for pad in 12..<16 { odd[row * 16 + pad] = 0 } }
        #expect(AlphaScan.isOpaque(Data(odd), width: 3, height: 2, bytesPerRow: 16))
        odd[16 + 2 * 4 + 3] = 254
        #expect(!AlphaScan.isOpaque(Data(odd), width: 3, height: 2, bytesPerRow: 16))
        #expect(!AlphaScan.isOpaque(Data(count: 27), width: 3, height: 2, bytesPerRow: 16), "short buffer")
    }

    @Test("An opaque raster's JPEG and HEIC skip compositing without changing a byte")
    func opaqueLossyExportsMatchComposited() throws {
        let canonical = try #require(
            try RenderRaster(image: ChartFixture.photographic(width: 64, height: 48)).makeImage())
        let view = try ExportEncoder.opaqueView(canonical)
        try #require(canonical.alphaInfo == .premultipliedLast && view?.pixels != nil)
        for format in [ExportFormat.jpeg(quality: 0.9), .heic(quality: 0.9)] {
            let options = ExportOptions(format: format)
            let composited = try ExportEncoder.flatten(canonical, on: options.jpegBackground)
            #expect(
                try ExportEncoder.encode(canonical, options: options)
                    == ExportEncoder.encode(composited, options: options), "\(format)")
        }
    }

    @Test(
        "Imported EXIF, GPS, TIFF, IPTC, and comment metadata never survive export",
        arguments: [
            ExportFormat.png, .jpeg(quality: 0.9),
        ])
    func importedMetadataIsStripped(format: ExportFormat) async throws {
        let jpeg = try ContainerCrafting.metadataRichJPEG(try ChartFixture.geometryChart(width: 48, height: 32))
        // Control: the canaries and metadata dictionaries are present in the input.
        for canary in ContainerCrafting.metadataCanaries {
            #expect(ContainerInspector.contains(canary, in: jpeg), "fixture lacks \(canary)")
        }
        #expect(ContainerInspector.propertyKeys(jpeg).isSuperset(of: ["{GPS}", "{TIFF}", "{Exif}"]))

        let harness = ImagingHarness()
        let asset = await harness.store.insert(try ImageDecoder.decode(jpeg), origin: .imported)
        let snapshot = try await harness.export(
            DocumentSession(document: Document(asset: asset)), ExportOptions(format: format))
        for canary in ContainerCrafting.metadataCanaries {
            #expect(!ContainerInspector.contains(canary, in: snapshot.bytes), "\(canary) survived export")
        }
        #expect(ContainerInspector.propertyKeys(snapshot.bytes).isDisjoint(with: Self.forbiddenPropertyKeys))
        #expect(!ContainerInspector.contains("Exif", in: snapshot.bytes))
        #expect(!snapshot.suggestedFilename.contains("RECORTIA"))
    }

    @Test("An Automatic JPEG keeps secure masks and carries none of the imported metadata")
    func automaticJPEGIsSanitized() async throws {
        let jpeg = try ContainerCrafting.metadataRichJPEG(try ChartFixture.photographic(width: 1200, height: 900))
        for canary in ContainerCrafting.metadataCanaries {
            #expect(ContainerInspector.contains(canary, in: jpeg), "fixture lacks \(canary)")
        }
        let harness = ImagingHarness()
        let asset = await harness.store.insert(try ImageDecoder.decode(jpeg), origin: .imported)
        var session = DocumentSession(document: Document(asset: asset))
        let masked = Rect<DocumentSpace>(x: 400, y: 300, width: 200, height: 200)
        let unmasked = try decoded(try await harness.export(session, ExportOptions(automaticFormat: true)))
        try session.addSecureMask(covering: masked)

        let snapshot = try await harness.export(session, ExportOptions(automaticFormat: true))
        // Control: the size rule chose JPEG, so this exercises the lossy path.
        try #require(snapshot.format == .jpeg(quality: 0.92))
        let (segments, endsWithEOI) = try ContainerInspector.jpegSegments(snapshot.bytes)
        #expect(Set(segments.map(\.marker)).isSubset(of: Self.allowedJPEGMarkers), "unexpected markers: \(segments)")
        #expect(endsWithEOI)
        for canary in ContainerCrafting.metadataCanaries {
            #expect(!ContainerInspector.contains(canary, in: snapshot.bytes), "\(canary) survived export")
        }
        #expect(ContainerInspector.propertyKeys(snapshot.bytes).isDisjoint(with: Self.forbiddenPropertyKeys))
        let pixels = try decoded(snapshot)
        for y in stride(from: 310, to: 490, by: 15) {
            for x in stride(from: 410, to: 590, by: 15) {
                // Control: the source is far from black there.
                #expect(unmasked.pixel(x: x, y: y).distance(to: color(0, 0, 0)) > 60)
                #expect(pixels.pixel(x: x, y: y).distance(to: color(0, 0, 0)) <= 12, "(\(x), \(y))")
            }
        }
    }
}
