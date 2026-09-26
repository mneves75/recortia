import CoreGraphics
import Domain
import Foundation
import FramepinFixtures
import Testing

@testable import Imaging

@Suite("EXP-01: single export pipeline and visual fidelity")
struct ExportPipelineTests {
    /// A 20x10 opaque chart on a 30x14 canvas at 50% layer opacity: transparent margin + half alpha.
    private func translucentSession(_ harness: ImagingHarness) async throws -> DocumentSession {
        let asset = try await harness.add(try ChartFixture.solid(width: 20, height: 10, color: color(200, 40, 80)))
        let layer = ImageLayer(assetID: asset.id, opacity: 0.5)
        return DocumentSession(
            document: Document(assets: [asset.id: asset], canvasSize: Size(width: 30, height: 14), layers: [layer]))
    }

    @Test("The same session always yields byte-identical snapshots with its identity and a safe filename")
    func snapshotsAreDeterministic() async throws {
        let harness = ImagingHarness()
        let pair = try SecretPairFixture.make(
            width: 50, height: 40, secret: FixtureRect(x: 5, y: 5, width: 10, height: 10), seed: 3)
        let asset = try await harness.add(pair.a)
        var session = DocumentSession(document: Document(asset: asset))
        try session.addSecureMask(covering: Rect(x: 5, y: 5, width: 10, height: 10))
        try session.perform("Annotate") {
            $0.annotations.append(Annotation(kind: .step(center: Point(x: 30, y: 20), number: 1), style: .default))
        }
        for options in [ExportOptions(), ExportOptions(format: .jpeg(quality: 0.7), scale: 1.5)] {
            let first = try await harness.export(session, options)
            let second = try await harness.export(session, options)
            #expect(first == second)
            #expect(first.revision == session.revision && first.privacyEpoch == session.privacyEpoch)
            #expect(first.documentID == session.document.id)
            #expect(first.format == options.format)
            #expect(first.pixelSize == session.document.outputPixelSize(exportScale: options.scale))
            #expect(first.suggestedFilename == ExportFilename.make(for: fixedExportDate, format: options.format))
            let decodedPixels = try decoded(first)
            #expect(decodedPixels.width == first.pixelSize.width && decodedPixels.height == first.pixelSize.height)
        }
    }

    @Test("PNG keeps alpha: transparent canvas stays transparent and layer opacity becomes pixel alpha")
    func pngAlpha() async throws {
        let harness = ImagingHarness()
        let snapshot = try await harness.export(try await translucentSession(harness))
        let p = try decoded(snapshot)
        #expect(p.pixel(x: 25, y: 12) == color(0, 0, 0, 0))
        let half = p.straight(x: 5, y: 5)
        #expect(abs(Int(half.a) - 128) <= 1)
        #expect(half.distance(to: color(200, 40, 80, half.a)) <= 2)
    }

    @Test("JPEG flattens transparency against the declared background")
    func jpegBackground() async throws {
        let harness = ImagingHarness()
        let background = RGBA(r: 0, g: 128, b: 255)
        let snapshot = try await harness.export(
            try await translucentSession(harness), ExportOptions(format: .jpeg(quality: 1), jpegBackground: background))
        let p = try decoded(snapshot)
        #expect(p.pixel(x: 27, y: 12).distance(to: color(0, 128, 255)) <= 4)
        #expect(p.pixel(x: 5, y: 5).distance(to: color(100, 84, 168)) <= 5)  // 50% over the background
        #expect(p.pixel(x: 5, y: 5).a == 255)
    }

    @Test("Invalid export options are rejected before rendering")
    func invalidOptions() async throws {
        let harness = ImagingHarness()
        let session = try await translucentSession(harness)
        await #expect(throws: ExportError.invalidOptions(.invalidScale)) {
            try await harness.export(session, ExportOptions(scale: 0))
        }
        await #expect(throws: ExportError.invalidOptions(.invalidQuality)) {
            try await harness.export(session, ExportOptions(format: .jpeg(quality: 1.5)))
        }
        await #expect(throws: ExportError.invalidOptions(.translucentJPEGBackground)) {
            try await harness.export(session, ExportOptions(format: .jpeg(quality: 0.5), jpegBackground: .clear))
        }
    }

    @Test("Preview geometry (renderBase + AnnotationRenderer) matches export geometry", arguments: [1.0, 2.0])
    func previewMatchesExport(scale: Double) async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.geometryChart(width: 60, height: 40))
        var document = Document(asset: asset)
        document.annotations = [
            Annotation(kind: .rectangle(Rect(x: 4, y: 4, width: 20, height: 12)), style: .default),
            Annotation(kind: .arrow(start: Point(x: 30, y: 30), end: Point(x: 55, y: 6)), style: .default),
            Annotation(kind: .text(.init(origin: Point(x: 5, y: 22), string: "Olá ✓", fontSize: 10)), style: .default),
        ]
        document.obfuscations = [
            CosmeticObfuscation(rect: Rect(x: 40, y: 25, width: 15, height: 10), style: .blur(radius: 2))
        ]
        document.masks = [
            SecureMask(
                outputRect: Rect(x: 44, y: 30, width: 8, height: 6),
                sourceRegions: [asset.id: [PixelRect(x: 44, y: 30, width: 8, height: 6)]], fill: .black)
        ]

        let exported = try await harness.renderer.render(document, scale: scale)
        let base = try await harness.renderer.renderBase(document, scale: scale)
        #expect(base.width == exported.width && base.height == exported.height)

        let context = try #require(ChartFixture.context(width: base.width, height: base.height))
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: scale, y: -scale)
        AnnotationRenderer.draw(document.annotations, in: context)
        let preview = try #require(context.makeImage())
        #expect(try pixels(preview) == pixels(exported))
    }
}

@Suite("Render budget and isolation")
struct RenderBudgetTests {
    @Test("Oversized outputs are refused before any allocation")
    func budgetIsEnforced() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 10, height: 10, color: color(1, 2, 3)))
        var document = Document(asset: asset)
        document.canvasSize = Size(width: 30_000, height: 30_000)
        await #expect(throws: RenderError.self) { try await harness.renderer.render(document, scale: 1) }
        do {
            _ = try await harness.renderer.render(document, scale: 1)
        } catch {
            guard case .budgetExceeded(let estimated, let limit) = error else {
                Issue.record("expected budgetExceeded, got \(error)")
                return
            }
            #expect(estimated > limit)
        }
        #expect(RenderLimits.maxOutputPixels == ImportLimits.maxPixelArea)
        #expect(RenderLimits.maxWorkingBytes <= 512 * 1024 * 1024)
    }

    @Test("Non-finite or non-positive scales are rejected")
    func invalidScales() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 10, height: 10, color: color(1, 2, 3)))
        for scale in [0, -1, Double.nan, Double.infinity] {
            await #expect(throws: RenderError.invalidScale) {
                try await harness.renderer.render(Document(asset: asset), scale: scale)
            }
        }
    }

    @Test("Assets missing from the store are an error, not a blank render")
    func missingAsset() async throws {
        let harness = ImagingHarness()
        let other = ImagingHarness()
        let asset = try await other.add(try ChartFixture.solid(width: 10, height: 10, color: color(1, 2, 3)))
        await #expect(throws: RenderError.missingPixels) {
            try await harness.renderer.render(Document(asset: asset), scale: 1)
        }
        await other.store.remove(asset.id)
        await #expect(throws: RenderError.missingPixels) {
            try await other.renderer.render(Document(asset: asset), scale: 1)
        }
    }

    @Test("Rendering runs off the main thread even when requested from the main actor")
    @MainActor
    func renderRunsOffMain() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.solid(width: 10, height: 10, color: color(1, 2, 3)))
        let outcome = try await harness.renderer.renderOutcome(Document(asset: asset), scale: 1)
        #expect(!outcome.renderedOnMainThread)
        // Control: the probe does report the main thread when the core runs there.
        #expect(RenderEngine.isMainThread())
    }
}
