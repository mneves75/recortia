import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@Suite("Text decorations (FR-05, EXP-01)")
struct TextDecorationExportTests {
    @Test("The public passive background shares padded geometry and applies opacity once without glyphs")
    func passiveBackground() throws {
        let context = try #require(ChartFixture.context(width: 260, height: 140))
        context.translateBy(x: 0, y: 140)
        context.scaleBy(x: 1, y: -1)
        let transform = context.ctm
        let text = Annotation.TextContent(
            origin: Point(x: 30, y: 30), string: "HAM", fontSize: 40, maxWidth: 160, appearance: .roundedBoxed)
        try AnnotationRenderer.drawTextBackground(
            text, style: Annotation.Style(stroke: .black, opacity: 0.5), in: context)
        #expect(context.ctm == transform)
        let output = try pixels(try #require(context.makeImage()))
        #expect(output.pixel(x: 20, y: 24).a == 0)
        let interior = output.pixel(x: 60, y: 50)
        #expect(interior.a == 128 && interior.r == 128 && interior.g == 128 && interior.b == 128)
        for y in 40..<60 {
            for x in 35..<130 {
                let pixel = output.pixel(x: x, y: y)
                #expect(pixel.r == pixel.a && pixel.g == pixel.a && pixel.b == pixel.a)
            }
        }
    }

    @Test(
        "Transformed source masks remain topmost over every appearance and sanitize magnifier exports",
        arguments: [TextAppearance.outlined, .boxed, .roundedBoxed, .monospacedBoxed])
    func transformedMaskedExports(appearance: TextAppearance) async throws {
        let pair = try SecretPairFixture.make(
            width: 200, height: 150, secret: FixtureRect(x: 30, y: 20, width: 50, height: 30), seed: 91,
            translucentBackground: true)
        for options in [ExportOptions(scale: 0.75), ExportOptions(format: .jpeg(quality: 0.9), scale: 2)] {
            func export(_ image: CGImage, masked: Bool) async throws -> ShareSnapshot {
                let h = ImagingHarness()
                let asset = try await h.add(image)
                var document = Document(asset: asset)
                document.layers[0].placement = LayerPlacement(
                    translation: Point(x: 4, y: 3), scale: 0.9, rotation: 0.07)
                document.annotations = [
                    Annotation(
                        kind: .text(
                            .init(origin: Point(x: 40, y: 25), string: "MW", fontSize: 30, appearance: appearance)),
                        style: Annotation.Style(stroke: .yellow, fill: RGBA(r: 255, g: 0, b: 0, a: 100), lineWidth: 12)),
                    Annotation(
                        kind: .text(
                            .init(origin: Point(x: 5, y: 90), string: "Á🙂", fontSize: 22, appearance: appearance)),
                        style: Annotation.Style(stroke: .white, opacity: 0.6)),
                ]
                let covered = document.layers[0].sourceToDocument(assetSize: asset.pixelSize).apply(
                    pair.secret.sourceRect)
                document.callouts = [
                    Callout(kind: .magnifier(source: covered, destination: Rect(x: 125, y: 80, width: 60, height: 50)))
                ]
                var session = DocumentSession(document: document)
                if masked { try session.addSecureMask(covering: covered) }
                return try await h.export(session, options)
            }
            let maskedA = try await export(pair.a, masked: true), maskedB = try await export(pair.b, masked: true)
            #expect(try decoded(maskedA) == decoded(maskedB))
            let output = try decoded(maskedA)
            let sample = output.pixel(x: Int(45 * options.scale), y: Int(35 * options.scale))
            #expect(sample.r < 4 && sample.g < 4 && sample.b < 4 && sample.a == 255)
            let openA = try await export(pair.a, masked: false), openB = try await export(pair.b, masked: false)
            #expect(try decoded(openA) != decoded(openB))
            #expect(
                ContainerInspector.propertyKeys(maskedA.bytes).isDisjoint(
                    with: ExportContainerTests.forbiddenPropertyKeys))
        }
    }

    @Test(
        "Finite-overflow font geometry is rejected before native font resolution", arguments: [TextAppearance.standard])
    func overflowFontAdmission(appearance: TextAppearance) {
        #expect(throws: TextLayoutError.invalidGeometry) {
            _ = try TextLayout.nativeFont(for: appearance, size: .greatestFiniteMagnitude)
        }
    }

    @Test("Monospaced boxes use rectangular corners and the monospaced system glyphs")
    func monospacedBoxPixels() async throws {
        let appearance = try #require(TextAppearance(rawValue: "monospacedBoxed"))
        let h = ImagingHarness()
        let asset = try await h.add(try ChartFixture.solid(width: 260, height: 140, color: color(0, 70, 0)))
        var document = Document(asset: asset)
        let text = Annotation.TextContent(
            origin: Point(x: 30, y: 30), string: "Wi fi", fontSize: 40, maxWidth: 160, appearance: appearance)
        document.annotations = [Annotation(kind: .text(text), style: Annotation.Style(stroke: .black))]
        let output = try decoded(await h.export(DocumentSession(document: document)))
        #expect(output.pixel(x: 20, y: 24) == color(255, 255, 255))
        let metrics = try TextLayout.metrics(for: text, style: Annotation.Style(stroke: .black))
        #expect(metrics.cornerRadius == 0)
        document.annotations[0].style.fill = .clear
        let transparent = try decoded(await h.export(DocumentSession(document: document)))
        var monospaced = text
        monospaced.appearance = .monospaced
        document.annotations[0].kind = .text(monospaced)
        let control = try decoded(await h.export(DocumentSession(document: document)))
        #expect(transparent == control)
    }

    @Test("Rounded boxes have rounded corner pixels and the rounded system glyphs")
    func roundedBoxPixels() async throws {
        let appearance = try #require(TextAppearance(rawValue: "roundedBoxed"))
        let h = ImagingHarness()
        let asset = try await h.add(try ChartFixture.solid(width: 260, height: 140, color: color(0, 70, 0)))
        var document = Document(asset: asset)
        let text = Annotation.TextContent(
            origin: Point(x: 30, y: 30), string: "Wi fi", fontSize: 40, maxWidth: 160, appearance: appearance)
        document.annotations = [Annotation(kind: .text(text), style: Annotation.Style(stroke: .black))]
        let output = try decoded(await h.export(DocumentSession(document: document)))
        #expect(output.pixel(x: 20, y: 24) == color(0, 70, 0))
        #expect(output.pixel(x: 30, y: 26) == color(255, 255, 255))
        let metrics = try TextLayout.metrics(for: text, style: Annotation.Style(stroke: .black))
        #expect(metrics.cornerRadius == 8)
        document.annotations[0].style.fill = .clear
        let transparent = try decoded(await h.export(DocumentSession(document: document)))
        var rounded = text
        rounded.appearance = .rounded
        document.annotations[0].kind = .text(rounded)
        let control = try decoded(await h.export(DocumentSession(document: document)))
        #expect(transparent == control)
    }

    @Test("Box padding preserves the content origin and uses automatic white, explicit alpha or custom fill")
    func boxedBackgroundPixels() async throws {
        let appearance = try #require(TextAppearance(rawValue: "boxed"))
        let h = ImagingHarness()
        let asset = try await h.add(try ChartFixture.solid(width: 260, height: 140, color: color(0, 70, 0)))
        let text = Annotation.TextContent(
            origin: Point(x: 30, y: 30), string: "Box", fontSize: 40, maxWidth: 160, appearance: appearance)
        let fills: [(RGBA?, ChartFixture.Color)] = [
            (nil, color(255, 255, 255)), (.clear, color(0, 70, 0)),
            (RGBA(r: 10, g: 20, b: 200), color(10, 20, 200)),
            (RGBA(r: 10, g: 20, b: 200, a: 128), color(5, 45, 100)),
        ]
        for (fill, expected) in fills {
            let style = Annotation.Style(stroke: .black, fill: fill)
            let metrics = try TextLayout.metrics(for: text, style: style)
            #expect(metrics.contentFrame.origin == Point(x: 30, y: 30))
            #expect(metrics.contentFrame.width == 160)
            var document = Document(asset: asset)
            document.annotations = [Annotation(kind: .text(text), style: style)]
            let output = try decoded(await h.export(DocumentSession(document: document)))
            #expect(output.pixel(x: 22, y: 26).distance(to: expected) <= 1)
            #expect(output.pixel(x: 18, y: 26) == color(0, 70, 0))
        }
    }

    @Test("Outlined exports have white glyph interiors and the selected colored stroke")
    func outlinedGlyphPixels() async throws {
        let appearance = try #require(TextAppearance(rawValue: "outlined"))
        let h = ImagingHarness()
        let asset = try await h.add(try ChartFixture.solid(width: 360, height: 140, color: color(0, 70, 0)))
        var document = Document(asset: asset)
        document.annotations = [
            Annotation(
                kind: .text(
                    .init(origin: Point(x: 25, y: 20), string: "HAM", fontSize: 76, appearance: appearance)),
                style: Annotation.Style(stroke: RGBA(r: 255, g: 0, b: 0), lineWidth: 3))
        ]
        let output = try decoded(await h.export(DocumentSession(document: document)))
        var white = 0, red = 0
        for y in 0..<output.height {
            for x in 0..<output.width {
                let pixel = output.pixel(x: x, y: y)
                if pixel.r == 255 && pixel.g == 255 && pixel.b == 255 { white += 1 }
                if pixel.r > 200 && pixel.g < 50 && pixel.b < 50 { red += 1 }
            }
        }
        #expect(white > 200)
        #expect(red > 200)
        #expect(output.pixel(x: 0, y: 0) == color(0, 70, 0))
    }
}
