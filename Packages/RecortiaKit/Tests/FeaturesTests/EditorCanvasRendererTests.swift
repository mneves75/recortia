import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

// Failure modes (EXP-01, FR-13): the canvas drawing annotations with different code or order
// than the export, so preview and export disagree; masks drawn under annotations in the preview
// while the export covers them; a magnifier preview showing annotations or unsanitized pixels.
@Suite("Editor canvas matches export (EXP-01)")
struct EditorCanvasRendererTests {
    private static func context(width: Int, height: Int) throws -> CGContext {
        let context = try #require(ChartFixture.context(width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static func maxChannelDifference(_ a: CGImage, _ b: CGImage) throws -> Int {
        let pa = try ContainerInspector.pixels(of: a), pb = try ContainerInspector.pixels(of: b)
        #expect(pa.width == pb.width && pa.height == pb.height)
        var worst = 0
        for y in 0..<pa.height {
            for x in 0..<pa.width {
                let p = pa.pixel(x: x, y: y), q = pb.pixel(x: x, y: y)
                worst = max(
                    worst, abs(Int(p.r) - Int(q.r)), abs(Int(p.g) - Int(q.g)), abs(Int(p.b) - Int(q.b)),
                    abs(Int(p.a) - Int(q.a)))
            }
        }
        return worst
    }

    @Test("Base, annotations, masks, and callouts drawn by the canvas equal the export at scale 1")
    func canvasEqualsExport() async throws {
        let store = ImageStore()
        let decoded = try ImageDecoder.canonicalize(try ChartFixture.geometryChart(width: 96, height: 64))
        let info = await store.insert(decoded, origin: .imported)
        var session = DocumentSession(document: Document(asset: info))
        try session.perform("Annotate") { document in
            document.annotations = [
                Annotation(kind: .rectangle(Rect(x: 8, y: 8, width: 40, height: 24)), style: .default),
                Annotation(
                    kind: .arrow(start: Point(x: 60, y: 50), end: Point(x: 90, y: 10)),
                    style: Annotation.Style(stroke: .yellow, lineWidth: 3, opacity: 0.8)),
                Annotation(
                    kind: .text(Annotation.TextContent(origin: Point(x: 4, y: 36), string: "Olá ☕️", fontSize: 14)),
                    style: Annotation.Style(stroke: .white)),
                Annotation(kind: .step(center: Point(x: 70, y: 40), number: 3), style: .default),
            ]
            document.callouts = [
                Callout(kind: .spotlight(Rect(x: 50, y: 4, width: 30, height: 20), dimOpacity: 0.4))
            ]
            document.obfuscations = [
                CosmeticObfuscation(rect: Rect(x: 0, y: 50, width: 20, height: 14), style: .pixelate(blockSize: 4))
            ]
        }
        // The mask covers part of the rectangle's stroke: the export draws it over annotations.
        try session.addSecureMask(covering: Rect(x: 30, y: 4, width: 12, height: 10))
        let renderer = PrivacyRenderer(store: store)
        let exported = try await renderer.render(session.document, scale: 1)
        let base = try await renderer.renderBase(session.document, scale: 1)

        let context = try Self.context(width: 96, height: 64)
        EditorCanvasRenderer.draw(session.document, base: base, calloutBase: base, in: context)
        let canvas = try #require(context.makeImage())
        #expect(try Self.maxChannelDifference(canvas, exported) <= 1)
    }

    @Test("A magnifier preview enlarges the sanitized base only, never annotations")
    func magnifierShowsBaseOnly() async throws {
        let store = ImageStore()
        let decoded = try ImageDecoder.canonicalize(try ChartFixture.geometryChart(width: 64, height: 64))
        let info = await store.insert(decoded, origin: .imported)
        var session = DocumentSession(document: Document(asset: info))
        try session.perform("Magnify") { document in
            document.annotations = [
                Annotation(
                    kind: .rectangle(Rect(x: 2, y: 2, width: 12, height: 12)),
                    style: Annotation.Style(stroke: .black, fill: .black))
            ]
            document.callouts = [
                Callout(
                    kind: .magnifier(
                        source: Rect(x: 0, y: 0, width: 16, height: 16),
                        destination: Rect(x: 32, y: 32, width: 32, height: 32)))
            ]
        }
        try session.addSecureMask(covering: Rect(x: 0, y: 0, width: 4, height: 4))
        let renderer = PrivacyRenderer(store: store)
        // The export magnifies by re-rendering the base at 2×; the preview enlarges the 1× base
        // without interpolation, so only content (not edge resampling) is compared here.
        let base = try await renderer.renderBase(session.document, scale: 1)
        let context = try Self.context(width: 64, height: 64)
        EditorCanvasRenderer.draw(session.document, base: base, calloutBase: base, in: context)
        let canvas = try #require(context.makeImage())
        let pixels = try ContainerInspector.pixels(of: canvas)
        // Inside the magnifier, the black annotation is absent and the mask (black, 2×) is present.
        let masked = pixels.pixel(x: 33, y: 33), quadrant = pixels.pixel(x: 50, y: 50)
        #expect(masked.r == 0 && masked.g == 0 && masked.b == 0)
        #expect(ChartFixture.Color(quadrant.r, quadrant.g, quadrant.b) == ChartFixture.quadrantColors[0])
    }

    @Test("Without a current base, masks still draw opaque and magnifiers draw no pixels")
    func noBase() throws {
        let asset = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 16, height: 16), origin: .imported)
        var document = Document(asset: asset)
        document.masks = [
            SecureMask(outputRect: Rect(x: 2, y: 2, width: 4, height: 4), sourceRegions: [:], fill: .black)
        ]
        document.callouts = [
            Callout(
                kind: .magnifier(
                    source: Rect(x: 2, y: 2, width: 4, height: 4), destination: Rect(x: 8, y: 8, width: 8, height: 8)))
        ]
        let context = try Self.context(width: 16, height: 16)
        EditorCanvasRenderer.draw(document, base: nil, calloutBase: nil, in: context)
        let pixels = try ContainerInspector.pixels(of: try #require(context.makeImage()))
        #expect(pixels.pixel(x: 3, y: 3).a == 255)
        #expect(pixels.pixel(x: 12, y: 12).a == 0)
    }
}
