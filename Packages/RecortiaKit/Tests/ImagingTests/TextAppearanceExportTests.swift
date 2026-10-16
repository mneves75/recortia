import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("Text appearance exports (FR-05, EXP-01)")
struct TextAppearanceExportTests {

    @Test(
        "Text pixel rendering stays off MainActor and rejects layout failures",
        arguments: [TextAppearance.rounded])
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
