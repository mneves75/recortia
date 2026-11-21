import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// Text-only redaction's sweep (A-6) on synthetic typed text: one padded region per recognized
/// line, every painted pixel inside the rectangle covered, nothing outside it.
@Suite("Text-line regions: the automatic-masking sweep, line by line (A-6)")
struct TextLineRegionsTests {
    static let languages = [OCRRecognitionTests.english, OCRRecognitionTests.portuguese]

    /// Pixels of `area` that differ from the sample's background, i.e. that glyphs painted.
    static func inkPixels(of image: CGImage, in area: PixelRect) throws -> [(x: Int, y: Int)] {
        let pixels = try ContainerInspector.pixels(of: image)
        let background = pixels.pixel(x: 0, y: 0)
        var ink: [(x: Int, y: Int)] = []
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX where pixels.pixel(x: x, y: y) != background {
                ink.append((x, y))
            }
        }
        return ink
    }

    static func uncovered(_ ink: [(x: Int, y: Int)], by regions: [PixelRect]) -> [(x: Int, y: Int)] {
        ink.filter { pixel in !regions.contains { $0.contains(x: pixel.x, y: pixel.y) } }
    }

    static func whole(_ image: CGImage) -> PixelRect { PixelRect(x: 0, y: 0, width: image.width, height: image.height) }

    @Test(
        "One region per line, and every painted pixel inside the rectangle is covered",
        VisionRuntime.required, arguments: [TextCorpus.Theme.light, .dark])
    func onePaddedRegionPerLine(theme: TextCorpus.Theme) async throws {
        let sample = try TextCorpus.render(
            id: "lines-\(theme.rawValue)", language: .portugueseBrazil, category: .prose, theme: theme,
            pointSize: 15, scale: 2,
            lines: [
                "Relatório trimestral enviado à diretoria", "Contrato assinado em março de 2026",
                "Próxima revisão agendada para junho",
            ])
        let area = Self.whole(sample.image)
        let regions = try await SensitiveTextScanner().textLineRegions(
            in: sample.image, within: area, hiding: [], pixelsPerPoint: 2, languages: Self.languages)
        #expect(regions.count == sample.lines.count, "\(regions)")
        // Each region lies on its own line (typographic rectangles include empty ascent above the ink).
        for (region, line) in zip(regions, sample.lineRects) {
            #expect(abs(Double(region.y + region.height / 2) - line.midY) < line.height / 2, "\(region) vs \(line)")
        }
        let ink = try Self.inkPixels(of: sample.image, in: area)
        #expect(!ink.isEmpty)
        let missed = Self.uncovered(ink, by: regions)
        #expect(missed.isEmpty, "\(missed.count) painted pixels uncovered, first \(missed.prefix(5))")
        // Text only: the margin around the lines stays visible.
        #expect(regions.reduce(0) { $0 + $1.area } < area.area / 2, "\(regions)")
    }

    @Test(
        "A rectangle that cuts through lines still covers every painted pixel inside it, and nothing outside",
        VisionRuntime.required)
    func rectangleCuttingLines() async throws {
        let sample = try TextCorpus.render(
            id: "cut", language: .english, category: .prose, theme: .light, pointSize: 17, scale: 2,
            lines: ["The quarterly report was sent to the board", "Contract signed in March, next review June"])
        let first = sample.lineRects[0], second = sample.lineRects[1]
        // From the middle of the first line's height to the middle of the second's, and through
        // the middle of their width.
        let area = PixelRect(
            x: Int(first.midX), y: Int(first.midY), width: Int(second.maxX - first.midX) + 4,
            height: Int(second.midY - first.midY))
        let regions = try await SensitiveTextScanner().textLineRegions(
            in: sample.image, within: area, hiding: [], pixelsPerPoint: 2, languages: Self.languages)
        #expect(!regions.isEmpty)
        for region in regions {
            #expect(
                region.x >= area.x && region.y >= area.y && region.maxX <= area.maxX && region.maxY <= area.maxY,
                "\(region) leaves \(area)")
        }
        let missed = Self.uncovered(try Self.inkPixels(of: sample.image, in: area), by: regions)
        #expect(missed.isEmpty, "\(missed.count) painted pixels uncovered, first \(missed.prefix(5))")
    }

    @Test(
        "A line under an existing secure mask is not read; without the mask the same pixels read as a line",
        VisionRuntime.required)
    func hiddenLineIsNotRead() async throws {
        let sample = try TextCorpus.render(
            id: "hidden", language: .english, category: .prose, theme: .light, pointSize: 15, scale: 2,
            lines: ["Account number for the payroll transfer"])
        let area = Self.whole(sample.image)
        let line = sample.lineRects[0].insetBy(dx: -8, dy: -8).integral
        let mask = try #require(
            PixelRect(x: Int(line.minX), y: Int(line.minY), width: Int(line.width), height: Int(line.height))
                .clipped(to: area))
        // Planted control: the fixture's only line is read when nothing hides it.
        let shown = try await SensitiveTextScanner().textLineRegions(
            in: sample.image, within: area, hiding: [], pixelsPerPoint: 2, languages: Self.languages)
        #expect(shown.count == 1, "\(shown)")
        let hidden = try await SensitiveTextScanner().textLineRegions(
            in: sample.image, within: area, hiding: [mask], pixelsPerPoint: 2, languages: Self.languages)
        #expect(hidden.isEmpty, "a line was read under the mask: \(hidden)")
    }

    @Test("Hidden source pixels are filled where they lie on the pixels read, and nowhere else")
    func hiddenPixelsFilledInPlace() throws {
        let image = try TextCorpus.blankImage(width: 100, height: 50)
        let read = CGRect(x: 20, y: 10, width: 60, height: 30)
        let crop = try #require(image.cropping(to: read))
        // One region inside the pixels read, one across their right edge, one wholly outside them.
        let filled = try SensitiveTextScanner.filling(
            [
                PixelRect(x: 30, y: 15, width: 10, height: 5), PixelRect(x: 75, y: 30, width: 20, height: 20),
                PixelRect(x: 0, y: 0, width: 5, height: 5),
            ], in: crop, readFrom: read)
        let original = try ContainerInspector.pixels(of: crop)
        let pixels = try ContainerInspector.pixels(of: filled)
        // Crop pixels: the first region lands at (10, 5), the second keeps only its part on the crop.
        let hidden = [PixelRect(x: 10, y: 5, width: 10, height: 5), PixelRect(x: 55, y: 20, width: 5, height: 10)]
        var wrong: [(x: Int, y: Int)] = []
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let expected =
                    hidden.contains { $0.contains(x: x, y: y) } ? .init(0, 0, 0, 255) : original.pixel(x: x, y: y)
                if pixels.pixel(x: x, y: y) != expected { wrong.append((x, y)) }
            }
        }
        #expect(filled.width == crop.width && filled.height == crop.height)
        #expect(wrong.isEmpty, "\(wrong.count) wrong pixels, first \(wrong.prefix(5))")
        #expect(
            try SensitiveTextScanner.filling([PixelRect(x: 0, y: 0, width: 5, height: 5)], in: crop, readFrom: read)
                === crop)
    }

    @Test("A rectangle without text finds no line", VisionRuntime.required)
    func blankFindsNothing() async throws {
        let image = try TextCorpus.blankImage()
        let regions = try await SensitiveTextScanner().textLineRegions(
            in: image, within: Self.whole(image), hiding: [], pixelsPerPoint: 1, languages: Self.languages)
        #expect(regions.isEmpty)
    }

    @Test("The store entry point reads the stored pixels, and fails when the asset is gone", VisionRuntime.required)
    func storeEntryPoint() async throws {
        let sample = try TextCorpus.render(
            id: "store", language: .english, category: .prose, theme: .light, pointSize: 15, scale: 2,
            lines: ["Stored pixels are read inside Imaging"])
        let store = ImageStore()
        let info = await store.insert(try ImageDecoder.canonicalize(sample.image), origin: .imported)
        let area = Self.whole(sample.image)
        let stored = try await SensitiveTextScanner().textLineRegions(
            of: info.id, in: store, within: area, hiding: [], pixelsPerPoint: 2, languages: Self.languages)
        #expect(stored.count == 1)
        await store.remove(info.id)
        await #expect(throws: SensitiveTextError.assetUnavailable) {
            _ = try await SensitiveTextScanner().textLineRegions(
                of: info.id, in: store, within: area, hiding: [], pixelsPerPoint: 2, languages: Self.languages)
        }
    }

    @Test("An empty rectangle or one outside the image fails instead of reading anything")
    func refusesAreasOutsideTheImage() async throws {
        let image = try TextCorpus.blankImage(width: 100, height: 50)
        for area in [
            PixelRect(x: 0, y: 0, width: 0, height: 10), PixelRect(x: 90, y: 0, width: 20, height: 10),
            PixelRect(x: -1, y: 0, width: 10, height: 10),
        ] {
            await #expect(throws: SensitiveTextError.regionOutsideImage, "\(area)") {
                _ = try await SensitiveTextScanner().textLineRegions(
                    in: image, within: area, hiding: [], pixelsPerPoint: 1, languages: Self.languages)
            }
        }
    }

    @Test("Final lines: merged across tiles, padded, clamped to the rectangle; an unmappable box fails")
    func finalLines() throws {
        let read = CGRect(x: 0, y: 0, width: 400, height: 200)
        let target = CGRect(x: 50, y: 50, width: 200, height: 100)
        // The same line from two tiles, one cut by a tile edge; a second line; one outside the target.
        let found = [
            CGRect(x: 60, y: 60, width: 120, height: 20), CGRect(x: 60, y: 60, width: 80, height: 20),
            CGRect(x: 60, y: 100, width: 100, height: 20), CGRect(x: 300, y: 10, width: 50, height: 20),
        ]
        let regions = try SensitiveTextScanner.finalLineRegions(found, read: read, target: target)
        // Padding: 15% of 20 px, rounded up, on each side.
        #expect(
            regions == [
                PixelRect(x: 57, y: 57, width: 126, height: 26), PixelRect(x: 57, y: 97, width: 106, height: 26),
            ])
        // A line over the rectangle's edge is clamped to it.
        let edge = try SensitiveTextScanner.finalLineRegions(
            [CGRect(x: 40, y: 140, width: 50, height: 20)], read: read, target: target)
        #expect(edge == [PixelRect(x: 50, y: 137, width: 43, height: 13)])
        #expect(throws: SensitiveTextError.regionOutsideImage) {
            try SensitiveTextScanner.finalLineRegions(
                [CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)], read: read, target: target)
        }
    }

    @Test("A coarser sweep runs only where a finer one needs several tiles, which can cut wide text")
    func sweepsForTheArea() {
        let standard = TileLayout.standard(pixelsPerPoint: 2)
        let small = SensitiveTextScanner.lineLayouts(
            for: CGSize(width: 400, height: 120), pixelsPerPoint: 2, fineTileSide: 1024)
        #expect(small == Array(standard.prefix(1)))
        // Several fine tiles, one middle tile: text is whole in the middle sweep.
        let screen = SensitiveTextScanner.lineLayouts(
            for: CGSize(width: 3024, height: 1964), pixelsPerPoint: 2, fineTileSide: 1024)
        #expect(screen == Array(standard.prefix(2)))
        let wide = SensitiveTextScanner.lineLayouts(
            for: CGSize(width: 10000, height: 3000), pixelsPerPoint: 2, fineTileSide: 1024)
        #expect(wide == standard)
    }
}
