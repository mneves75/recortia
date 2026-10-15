import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("Curved-arrow sanitized exports (FR-05, RED-02, RED-03)")
struct CurvedArrowExportTests {
    @Test("PNG and JPEG masks replace hidden curves and transformed source pixels before magnification")
    func pairedSecretExports() async throws {
        let pair = try SecretPairFixture.make(
            width: 200, height: 150, secret: FixtureRect(x: 30, y: 20, width: 50, height: 30), seed: 91,
            translucentBackground: true)
        for options in [
            ExportOptions(scale: 0.75), ExportOptions(scale: 2),
            ExportOptions(format: .jpeg(quality: 0.9), scale: 0.75),
            ExportOptions(format: .jpeg(quality: 0.9), scale: 2),
        ] {
            func export(_ image: CGImage, masked: Bool, hiddenControlY: Double = 43, visibleControlY: Double = 130)
                async throws -> ShareSnapshot
            {
                let harness = ImagingHarness()
                let asset = try await harness.add(image)
                var document = Document(asset: asset)
                document.layers[0].placement = LayerPlacement(
                    translation: Point(x: 4, y: 3), scale: 0.9, rotation: 0.07)
                document.annotations = [
                    Annotation(
                        kind: .arrow(
                            start: Point(x: 10, y: 80), end: Point(x: 170, y: 40),
                            control: Point(x: 100, y: visibleControlY)),
                        style: Annotation.Style(stroke: RGBA(r: 255, g: 0, b: 0, a: 128), lineWidth: 4, opacity: 0.6)),
                    Annotation(
                        kind: .arrow(
                            start: Point(x: 40, y: 38), end: Point(x: 60, y: 38),
                            control: Point(x: 50, y: hiddenControlY)),
                        style: Annotation.Style(stroke: .yellow, lineWidth: 1, opacity: 0.7)),
                ]
                let covered = document.layers[0].sourceToDocument(assetSize: asset.pixelSize).apply(
                    pair.secret.sourceRect)
                document.callouts = [
                    Callout(
                        kind: .magnifier(
                            source: covered,
                            destination: Rect(x: 125, y: 80, width: 60, height: 50)))
                ]
                var session = DocumentSession(document: document)
                if masked { try session.addSecureMask(covering: covered) }
                return try await harness.export(session, options)
            }
            let maskedA = try await export(pair.a, masked: true)
            let maskedB = try await export(pair.b, masked: true, hiddenControlY: 33)
            #expect(maskedA.bytes == maskedB.bytes)
            #expect(try decoded(maskedA) == decoded(maskedB))
            let openA = try await export(pair.a, masked: false)
            let changedSource = try await export(pair.b, masked: false)
            let changedHiddenCurve = try await export(pair.a, masked: false, hiddenControlY: 33)
            let changedVisibleCurve = try await export(pair.a, masked: false, visibleControlY: 15)
            #expect(
                try decoded(openA) != decoded(changedSource),
                "positive control: the source secret is observable without masks")
            #expect(
                try decoded(openA) != decoded(changedHiddenCurve),
                "positive control: the hidden curve changes exported pixels without masks")
            #expect(
                try decoded(openA) != decoded(changedVisibleCurve),
                "positive control: the exported curve follows its control")
            let output = try decoded(maskedA)
            let sample = output.pixel(x: Int(45 * options.scale), y: Int(35 * options.scale))
            #expect(sample.r < 4 && sample.g < 4 && sample.b < 4 && sample.a == 255)
            #expect(
                ContainerInspector.propertyKeys(maskedA.bytes).isDisjoint(
                    with: ExportContainerTests.forbiddenPropertyKeys))
            if options.format == .png {
                #expect(
                    Set(try ContainerInspector.pngChunkTypes(maskedA.bytes)).isSubset(
                        of: ExportContainerTests.allowedPNGChunks))
            }
        }
    }
}
