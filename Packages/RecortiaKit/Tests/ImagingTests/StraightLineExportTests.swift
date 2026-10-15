import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@Suite("Straight-line sanitized exports (FR-05, RED-02, RED-03)")
struct StraightLineExportTests {
    @Test("PNG flattens line stroke and opacity with round caps and no arrowhead", arguments: [1.0, 2.0])
    func flattenedLinePixels(scale: Double) async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 120, height: 80, color: color(255, 255, 255)))
        var document = Document(asset: asset)
        document.annotations = [
            Annotation(
                kind: .line(start: Point(x: 10, y: 40), end: Point(x: 110, y: 40)),
                style: Annotation.Style(stroke: .red, fill: .yellow, lineWidth: 4, opacity: 0.5))
        ]
        let snapshot = try await harness.export(DocumentSession(document: document), ExportOptions(scale: scale))
        let raster = try decoded(snapshot)
        #expect(raster.pixel(x: Int(40 * scale), y: Int(40 * scale)).distance(to: color(242, 156, 154)) <= 2)
        #expect(raster.pixel(x: Int(111 * scale), y: Int(40 * scale)) != color(255, 255, 255))
        #expect(raster.pixel(x: Int(96 * scale), y: Int(46 * scale)) == color(255, 255, 255))
        #expect(raster.pixel(x: Int(96 * scale), y: Int(33 * scale)) == color(255, 255, 255))
        #expect(
            Set(try ContainerInspector.pngChunkTypes(snapshot.bytes)).isSubset(
                of: ExportContainerTests.allowedPNGChunks))
        #expect(
            ContainerInspector.propertyKeys(snapshot.bytes).isDisjoint(with: ExportContainerTests.forbiddenPropertyKeys)
        )
    }

    @Test("Opaque output masks replace hidden line strokes and source pixels after fractional scaling")
    func maskSanitizesLinesAndSource() async throws {
        // Synthetic sRGB 96x72 SecretPairFixture, seed 2; only its declared 26x15 secret differs.
        let pair = try SecretPairFixture.make(
            width: 96, height: 72, secret: FixtureRect(x: 31, y: 21, width: 26, height: 15), seed: 2)
        let first = Annotation.Kind.line(start: Point(x: 35, y: 25), end: Point(x: 52, y: 32))
        let second = Annotation.Kind.line(start: Point(x: 35, y: 32), end: Point(x: 52, y: 25))
        func export(_ source: CGImage, line: Annotation.Kind, masked: Bool) async throws -> ShareSnapshot {
            let harness = ImagingHarness()
            let asset = try await harness.add(source)
            var document = Document(asset: asset)
            document.annotations = [Annotation(kind: line, style: Annotation.Style(stroke: RGBA(r: 255, g: 0, b: 0)))]
            var session = DocumentSession(document: document)
            if masked {
                try session.addSecureMask(
                    covering: Rect(x: 31, y: 21, width: 26, height: 15), fill: RGBA(r: 9, g: 9, b: 9))
            }
            return try await harness.export(session, ExportOptions(scale: 1.5))
        }
        let maskedFirst = try await export(pair.a, line: first, masked: true)
        let maskedSecond = try await export(pair.b, line: second, masked: true)
        #expect(maskedFirst.bytes == maskedSecond.bytes)
        let raster = try decoded(maskedFirst)
        // Outward output coverage: x 46...85, y 31...53, including fractional mask edges.
        for y in 31..<54 {
            for x in 46..<86 { #expect(raster.pixel(x: x, y: y) == color(9, 9, 9)) }
        }
        let unmaskedFirst = try await export(pair.a, line: first, masked: false)
        let changedLine = try await export(pair.a, line: second, masked: false)
        let changedSource = try await export(pair.b, line: first, masked: false)
        #expect(unmaskedFirst.bytes != changedLine.bytes, "the control detects different hidden vector strokes")
        #expect(unmaskedFirst.bytes != changedSource.bytes, "the control detects different hidden source pixels")
        #expect(try decoded(unmaskedFirst).pixel(x: 60, y: 40) == color(255, 0, 0))
    }

    @Test("Malformed line coordinates and stroke widths are refused before creating a ShareSnapshot")
    func malformedLinesRefused() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 20, height: 20, color: color(255, 255, 255)))
        for line in [
            Annotation(kind: .line(start: Point(x: .nan, y: 2), end: Point(x: 18, y: 18)), style: .default),
            Annotation(kind: .line(start: Point(x: 2, y: 2), end: Point(x: 18, y: .infinity)), style: .default),
            Annotation(
                kind: .line(start: Point(x: 2, y: 2), end: Point(x: 18, y: 18)),
                style: Annotation.Style(stroke: .red, lineWidth: -1)),
        ] {
            var document = Document(asset: asset)
            document.annotations = [line]
            await #expect(throws: ExportError.render(.invalidGeometry)) {
                try await harness.export(DocumentSession(document: document))
            }
        }
    }
}
