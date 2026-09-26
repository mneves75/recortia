import CoreGraphics
import Domain
import Foundation
import FramepinFixtures
import Testing

@testable import Imaging

/// One edit recipe applied identically to both images of a secret pair.
struct RedactionRecipe: Sendable, CustomTestStringConvertible {
    let name: String
    let options: ExportOptions
    /// Builds the session for `asset`; `masked` adds the fully covering secure mask.
    let build: @Sendable (ImageAssetInfo, FixtureRect, Bool) throws -> DocumentSession

    var testDescription: String { name }
}

enum RedactionFixtures {
    static let width = 96
    static let height = 72
    /// Odd coordinates, so every non-integer scale maps mask edges to fractional output pixels.
    static let secret = FixtureRect(x: 31, y: 21, width: 26, height: 15)
    static let seeds: [UInt64] = [1, 2, 3, 7, 42, 1337]

    static func pair(seed: UInt64, secret: FixtureRect = secret) throws -> SecretPair {
        try SecretPairFixture.make(
            width: width, height: height, secret: secret, seed: seed, translucentBackground: seed % 2 == 1)
    }

    static func session(_ document: Document, maskRect: Rect<DocumentSpace>?) throws -> DocumentSession {
        var session = DocumentSession(document: document)
        if let maskRect { try session.addSecureMask(covering: maskRect, fill: RGBA(r: 12, g: 34, b: 56)) }
        return session
    }

    static func single(_ edit: @escaping @Sendable (inout Document) -> Void)
        -> @Sendable (
            ImageAssetInfo, FixtureRect, Bool
        ) throws -> DocumentSession
    {
        { asset, secret, masked in
            var document = Document(asset: asset)
            edit(&document)
            return try session(document, maskRect: masked ? secret.documentRect : nil)
        }
    }

    static let recipes: [RedactionRecipe] = [
        RedactionRecipe(name: "plain PNG 1x", options: ExportOptions(), build: single { _ in }),
        RedactionRecipe(
            name: "document crop", options: ExportOptions(),
            build: single { $0.crop = Rect(x: 17, y: 9.5, width: 60.25, height: 50) }),
        RedactionRecipe(name: "resize 0.5x", options: ExportOptions(), build: single { $0.resizeScale = 0.5 }),
        RedactionRecipe(name: "export 2x", options: ExportOptions(scale: 2), build: single { _ in }),
        RedactionRecipe(
            name: "fractional 0.75x", options: ExportOptions(scale: 1.5), build: single { $0.resizeScale = 0.5 }),
        RedactionRecipe(
            name: "blur and pixelate adjacent to mask", options: ExportOptions(),
            build: single { document in
                let s = secret
                document.obfuscations = [
                    CosmeticObfuscation(
                        rect: Rect(x: Double(s.maxX), y: Double(s.y - 6), width: 22, height: Double(s.height + 12)),
                        style: .blur(radius: 5)),
                    CosmeticObfuscation(
                        rect: Rect(x: Double(s.x - 14), y: Double(s.y), width: 14, height: Double(s.height)),
                        style: .pixelate(blockSize: 5)),
                ]
            }),
        RedactionRecipe(
            name: "rotated and scaled layer", options: ExportOptions(),
            build: { asset, secret, masked in
                let layer = ImageLayer(
                    assetID: asset.id,
                    placement: LayerPlacement(translation: Point(x: 60, y: 8), scale: 1.35, rotation: 0.4))
                let document = Document(
                    assets: [asset.id: asset], canvasSize: Size(width: 170, height: 150), layers: [layer])
                let footprint = layer.sourceToDocument(assetSize: asset.pixelSize).apply(secret.sourceRect)
                return try session(document, maskRect: masked ? footprint : nil)
            }),
        RedactionRecipe(
            name: "magnifier over masked area", options: ExportOptions(),
            build: single { document in
                let s = secret
                document.callouts = [
                    Callout(
                        kind: .magnifier(
                            source: Rect(x: Double(s.x - 6), y: Double(s.y - 4), width: 30, height: 20),
                            destination: Rect(x: 50, y: 40, width: 45, height: 30)))
                ]
            }),
        RedactionRecipe(
            name: "two layers share one asset", options: ExportOptions(),
            build: { asset, secret, masked in
                let first = ImageLayer(assetID: asset.id)
                let second = ImageLayer(
                    assetID: asset.id, placement: LayerPlacement(translation: Point(x: 100, y: 4), scale: 0.9))
                let document = Document(
                    assets: [asset.id: asset], canvasSize: Size(width: 200, height: 80), layers: [first, second])
                // The mask touches only the first layer; source binding must protect the second.
                return try session(document, maskRect: masked ? secret.documentRect : nil)
            }),
        RedactionRecipe(
            name: "presentation, spotlight, annotation", options: ExportOptions(),
            build: single { document in
                let s = secret
                document.presentation = Presentation(
                    background: .linearGradient(from: RGBA(r: 10, g: 20, b: 200), to: .white, angleDegrees: 30),
                    padding: 12, cornerRadius: 10, shadow: Presentation.Shadow(radius: 6, offsetY: 3, opacity: 0.4))
                document.callouts = [
                    Callout(
                        kind: .spotlight(
                            Rect(x: Double(s.x - 8), y: Double(s.y - 8), width: 40, height: 30), dimOpacity: 0.5))
                ]
                document.annotations = [
                    Annotation(
                        kind: .arrow(start: Point(x: 5, y: 5), end: Point(x: Double(s.midX), y: Double(s.midY))),
                        style: .default)
                ]
            }),
        RedactionRecipe(name: "JPEG 1x", options: ExportOptions(format: .jpeg(quality: 0.9)), build: single { _ in }),
        RedactionRecipe(
            name: "JPEG fractional with blur", options: ExportOptions(format: .jpeg(quality: 0.8), scale: 1.25),
            build: single { document in
                let s = secret
                document.obfuscations = [
                    CosmeticObfuscation(
                        rect: Rect(x: Double(s.x - 10), y: Double(s.maxY), width: 50, height: 10),
                        style: .blur(radius: 3))
                ]
            }),
    ]
}

extension FixtureRect {
    var midX: Int { x + width / 2 }
    var midY: Int { y + height / 2 }
}

@Suite("RED-01: exported pixels do not depend on securely masked source pixels")
struct RenderRedactionMetamorphicTests {
    private func exports(
        _ recipe: RedactionRecipe, pair: SecretPair, masked: Bool
    ) async throws -> (ShareSnapshot, ShareSnapshot) {
        let harnessA = ImagingHarness(), harnessB = ImagingHarness()
        let assetA = try await harnessA.add(pair.a)
        let assetB = try await harnessB.add(pair.b)
        let sessionA = try recipe.build(assetA, pair.secret, masked)
        let sessionB = try recipe.build(assetB, pair.secret, masked)
        return (
            try await harnessA.export(sessionA, recipe.options), try await harnessB.export(sessionB, recipe.options)
        )
    }

    @Test("Masked exports are byte-identical and unmasked exports differ", arguments: RedactionFixtures.recipes)
    func maskedExportsAreSourceIndependent(recipe: RedactionRecipe) async throws {
        for seed in RedactionFixtures.seeds {
            let pair = try RedactionFixtures.pair(seed: seed)

            let (maskedA, maskedB) = try await exports(recipe, pair: pair, masked: true)
            #expect(maskedA.bytes == maskedB.bytes, "encoded bytes differ for seed \(seed)")
            #expect(try decoded(maskedA) == decoded(maskedB), "decoded pixels differ for seed \(seed)")

            // Non-vacuity: the recipe really exposes the secret region when it is not masked.
            let (openA, openB) = try await exports(recipe, pair: pair, masked: false)
            #expect(try decoded(openA) != decoded(openB), "recipe hides the secret even unmasked (seed \(seed))")
        }
    }

    @Test("Output-space masks hide annotations beneath them, rounded outward in output pixels")
    func outputMasksCoverVectorContent() async throws {
        let maskRect = Rect<DocumentSpace>(x: 10.3, y: 12.6, width: 40.5, height: 17.2)
        let scale = 1.5
        func export(_ text: String) async throws -> ShareSnapshot {
            let harness = ImagingHarness()
            let asset = try await harness.add(
                try ChartFixture.solid(width: 80, height: 50, color: color(240, 240, 240)))
            var document = Document(asset: asset)
            document.annotations = [
                Annotation(
                    kind: .text(.init(origin: Point(x: 12, y: 14), string: text, fontSize: 10)),
                    style: Annotation.Style(stroke: .black, fill: RGBA(r: 255, g: 255, b: 0))),
                Annotation(kind: .arrow(start: Point(x: 70, y: 45), end: Point(x: 30, y: 20)), style: .default),
            ]
            var session = DocumentSession(document: document)
            try session.addSecureMask(covering: maskRect, fill: RGBA(r: 9, g: 9, b: 9))
            return try await harness.export(session, ExportOptions(scale: scale))
        }
        let a = try await export("4821"), b = try await export("9053")
        let pixelsA = try decoded(a)
        // Outward rounding: floor(10.3 * 1.5) = 15 ... ceil(50.8 * 1.5) = 77; y 18 ... 45.
        for y in 18..<45 {
            for x in 15..<77 { #expect(pixelsA.pixel(x: x, y: y) == color(9, 9, 9), "(\(x), \(y))") }
        }
        // Same mask, different hidden text: identical exports. Without the output mask the text
        // (drawn above the layers) would differ inside the region.
        #expect(a.bytes == b.bytes)
    }

    @Test("Source-bound masks cover mask regions touching every image edge under fractional transforms")
    func edgeTouchingMasks() async throws {
        let w = RedactionFixtures.width, h = RedactionFixtures.height
        let secrets = [
            FixtureRect(x: 0, y: 0, width: w, height: 9),  // top edge
            FixtureRect(x: 0, y: h - 7, width: w, height: 7),  // bottom edge
            FixtureRect(x: 0, y: 0, width: 5, height: h),  // left edge
            FixtureRect(x: w - 6, y: 0, width: 6, height: h),  // right edge
            FixtureRect(x: w - 11, y: h - 9, width: 11, height: 9),  // corner
        ]
        let recipe = RedactionRecipe(
            name: "fractional edge", options: ExportOptions(scale: 1.5),
            build: { asset, secret, masked in
                let layer = ImageLayer(
                    assetID: asset.id,
                    placement: LayerPlacement(translation: Point(x: 13.3, y: 17.7), scale: 0.73, rotation: 0.2))
                // A second reference outside the mask's output rect: only source binding protects it.
                let duplicate = ImageLayer(
                    assetID: asset.id, placement: LayerPlacement(translation: Point(x: 115.4, y: 20.2), scale: 0.55))
                let document = Document(
                    assets: [asset.id: asset], canvasSize: Size(width: 170, height: 100), layers: [layer, duplicate])
                let footprint = layer.sourceToDocument(assetSize: asset.pixelSize).apply(secret.sourceRect)
                return try RedactionFixtures.session(document, maskRect: masked ? footprint : nil)
            })
        for secret in secrets {
            for seed: UInt64 in [5, 6] {
                let pair = try RedactionFixtures.pair(seed: seed, secret: secret)
                let (a, b) = try await exports(recipe, pair: pair, masked: true)
                #expect(a.bytes == b.bytes, "edge secret \(secret) leaks (seed \(seed))")
                let (openA, openB) = try await exports(recipe, pair: pair, masked: false)
                #expect(try decoded(openA) != decoded(openB))
            }
        }
    }
}

/// Deliberately broken pipelines, built only here, that the RED-01 comparison must catch.
/// If any of these ever compares equal, the metamorphic test has become vacuous.
@Suite("RED-01 planted controls fail the same comparison")
struct RenderRedactionControlTests {
    private let secret = RedactionFixtures.secret
    private let fill = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    private func encodeAndDecode(_ image: CGImage) throws -> DecodedPixels {
        let data = try ExportEncoder.encode(image, options: ExportOptions())
        return try ContainerInspector.decodePixels(data)
    }

    /// Runs `pipeline` on both images of several pairs and reports whether any pair differs.
    private func anyPairDiffers(_ pipeline: (CGImage) throws -> CGImage) throws -> Bool {
        var differs = false
        for seed in RedactionFixtures.seeds {
            let pair = try RedactionFixtures.pair(seed: seed)
            let a = try encodeAndDecode(pipeline(try ImageDecoder.canonicalize(pair.a).image))
            let b = try encodeAndDecode(pipeline(try ImageDecoder.canonicalize(pair.b).image))
            differs = differs || a != b
        }
        return differs
    }

    @Test("C1: mask applied after resampling, in output space, with truncating rounding, leaks")
    func controlMaskAfterResampling() throws {
        let scale = 0.5
        let outW = Int((Double(RedactionFixtures.width) * scale).rounded())
        let outH = Int((Double(RedactionFixtures.height) * scale).rounded())
        let differs = try anyPairDiffers { source in
            let context = try #require(ChartFixture.context(width: outW, height: outH))
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            let x0 = Int(Double(secret.x) * scale), x1 = Int(Double(secret.maxX) * scale)
            let y0 = Int(Double(secret.y) * scale), y1 = Int(Double(secret.maxY) * scale)
            context.setFillColor(fill)
            context.fill(CGRect(x: x0, y: outH - y1, width: x1 - x0, height: y1 - y0))
            return try #require(context.makeImage())
        }
        #expect(differs, "C1 control compared equal: the RED-01 comparison is vacuous")
    }

    @Test("C2: blur applied before the mask leaks")
    func controlBlurBeforeMask() throws {
        let blurRect = PixelRect(x: secret.maxX, y: secret.y - 6, width: 22, height: secret.height + 12)
        let maskRect = PixelRect(x: secret.x, y: secret.y, width: secret.width, height: secret.height)
        let differs = try anyPairDiffers { source in
            var raster = try RenderRaster(image: source)
            RenderEffects.blur(&raster, rect: blurRect, radius: 5)
            raster.fill(maskRect, with: .black)
            return try #require(raster.makeImage())
        }
        #expect(differs, "C2 control compared equal: the RED-01 comparison is vacuous")

        // The same operations in the correct order (mask, then blur) compare equal.
        let correctDiffers = try anyPairDiffers { source in
            var raster = try RenderRaster(image: source)
            raster.fill(maskRect, with: .black)
            RenderEffects.blur(&raster, rect: blurRect, radius: 5)
            return try #require(raster.makeImage())
        }
        #expect(!correctDiffers)
    }

    @Test("C3: a 0.99-alpha overlay instead of an opaque fill leaks")
    func controlTranslucentOverlay() throws {
        let differs = try anyPairDiffers { source in
            let context = try #require(ChartFixture.context(width: source.width, height: source.height))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.99))
            context.fill(
                CGRect(x: secret.x, y: source.height - secret.maxY, width: secret.width, height: secret.height))
            return try #require(context.makeImage())
        }
        #expect(differs, "C3 control compared equal: the RED-01 comparison is vacuous")
    }

    @Test("C4: an output-space-only mask does not protect a second reference to the same asset")
    func controlOutputOnlyMaskOnDuplicateLayer() async throws {
        var differs = false
        for seed in RedactionFixtures.seeds.prefix(3) {
            let pair = try RedactionFixtures.pair(seed: seed)
            var outputs: [Data] = []
            for image in [pair.a, pair.b] {
                let harness = ImagingHarness()
                let asset = try await harness.add(image)
                var document = Document(
                    assets: [asset.id: asset], canvasSize: Size(width: 200, height: 80),
                    layers: [
                        ImageLayer(assetID: asset.id),
                        ImageLayer(
                            assetID: asset.id, placement: LayerPlacement(translation: Point(x: 100, y: 4), scale: 0.9)),
                    ])
                document.masks = [SecureMask(outputRect: secret.documentRect, sourceRegions: [:], fill: .black)]
                outputs.append(try await harness.export(DocumentSession(document: document)).bytes)
            }
            differs = differs || outputs[0] != outputs[1]
        }
        #expect(differs, "C4 control compared equal: duplicate-reference coverage is untested")
    }
}
