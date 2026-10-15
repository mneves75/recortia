import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("Text appearance exports (FR-05, EXP-01)")
struct TextAppearanceExportTests {
    @Test(
        "Each font design retains source-independent PNG/JPEG exports and sanitized magnifiers",
        arguments: TextAppearance.allCases)
    func secureExports(appearance: TextAppearance) async throws {
        let pair = try RedactionFixtures.pair(seed: 42)
        for options in [ExportOptions(scale: 1.25), ExportOptions(format: .jpeg(quality: 0.9), scale: 1.25)] {
            func export(_ source: CGImage, masked: Bool) async throws -> ShareSnapshot {
                let h = ImagingHarness()
                let asset = try await h.add(source)
                var document = Document(asset: asset)
                document.annotations = [
                    Annotation(
                        kind: .text(
                            .init(
                                origin: Point(x: 3, y: 3),
                                string: "A\u{301}gua🙂 العربية", fontSize: 11, maxWidth: 48, appearance: appearance)),
                        style: Annotation.Style(stroke: .white))
                ]
                document.callouts = [
                    Callout(
                        kind: .magnifier(
                            source: RedactionFixtures.secret.documentRect,
                            destination: Rect(x: 60, y: 40, width: 30, height: 30)))
                ]
                var session = DocumentSession(document: document)
                if masked { try session.addSecureMask(covering: RedactionFixtures.secret.documentRect) }
                return try await h.export(session, options)
            }
            let a = try await export(pair.a, masked: true), b = try await export(pair.b, masked: true)
            let sameBytes = a.bytes == b.bytes
            #expect(sameBytes)
            let openA = try await export(pair.a, masked: false), openB = try await export(pair.b, masked: false)
            let controlDiffers = try decoded(openA) != decoded(openB)
            #expect(controlDiffers)
            #expect(
                ContainerInspector.propertyKeys(a.bytes).isDisjoint(with: ExportContainerTests.forbiddenPropertyKeys))
            if case .png = options.format {
                #expect(
                    Set(try ContainerInspector.pngChunkTypes(a.bytes)).isSubset(
                        of: ExportContainerTests.allowedPNGChunks))
            } else {
                let segments = try ContainerInspector.jpegSegments(a.bytes)
                #expect(segments.endsWithEOI)
                #expect(Set(segments.segments.map(\.marker)).isSubset(of: ExportContainerTests.allowedJPEGMarkers))
            }
        }
    }

    @Test(
        "Text pixel rendering stays off MainActor and rejects layout failures",
        arguments: TextAppearance.allCases)
    @MainActor
    func backgroundAndFailure(appearance: TextAppearance) async throws {
        let h = ImagingHarness()
        let asset = try await h.add(try ChartFixture.solid(width: 100, height: 80, color: color(255, 255, 255)))
        var document = Document(asset: asset)
        document.annotations = [
            Annotation(
                kind: .text(
                    .init(
                        origin: Point(x: 10, y: 10),
                        string: "Água🙂\nمرحبا\n", fontSize: 16, appearance: appearance)), style: .default)
        ]
        let outcome = try await h.renderer.renderOutcome(document, scale: 1)
        #expect(!outcome.renderedOnMainThread)
        #expect(RenderEngine.isMainThread())
        document.annotations = [
            Annotation(
                kind: .text(
                    .init(
                        origin: Point(x: .greatestFiniteMagnitude, y: 10),
                        string: "Text", fontSize: 24, maxWidth: .greatestFiniteMagnitude, appearance: appearance)),
                style: .default)
        ]
        await #expect(throws: RenderError.textLayoutFailed(.unmeasurableText)) {
            _ = try await h.renderer.render(document, scale: 1)
        }
    }

    @Test("Empty text preserves legacy no-paint behavior even with fill")
    func emptyTextDoesNotPaint() async throws {
        let h = ImagingHarness()
        let asset = try await h.add(try ChartFixture.solid(width: 40, height: 40, color: color(255, 255, 255)))
        let initial = Document(asset: asset)
        let baseline = try await h.export(DocumentSession(document: initial))
        for appearance in TextAppearance.allCases {
            var document = initial
            document.annotations = [
                Annotation(
                    kind: .text(
                        .init(
                            origin: Point(x: 10, y: 10), string: "",
                            appearance: appearance)), style: Annotation.Style(stroke: .black, fill: .red))
            ]
            let snapshot = try await h.export(DocumentSession(document: document))
            let unchanged = snapshot.bytes == baseline.bytes
            #expect(unchanged)
        }
    }

    @Test("Public system font designs produce distinct exported pixels")
    func designsDiffer() async throws {
        let h = ImagingHarness()
        let asset = try await h.add(try ChartFixture.solid(width: 300, height: 100, color: color(255, 255, 255)))
        var outputs: [DecodedPixels] = []
        for appearance in TextAppearance.allCases {
            var document = Document(asset: asset)
            document.annotations = [
                Annotation(
                    kind: .text(
                        .init(
                            origin: Point(x: 10, y: 10), string: "Wi fi 123 Agua", fontSize: 28,
                            appearance: appearance)), style: Annotation.Style(stroke: .black))
            ]
            outputs.append(try decoded(await h.export(DocumentSession(document: document))))
        }
        let standardDiffersFromRounded = outputs[0] != outputs[1]
        let standardDiffersFromMonospaced = outputs[0] != outputs[2]
        let roundedDiffersFromMonospaced = outputs[1] != outputs[2]
        #expect(standardDiffersFromRounded)
        #expect(standardDiffersFromMonospaced)
        #expect(roundedDiffersFromMonospaced)
    }
}
