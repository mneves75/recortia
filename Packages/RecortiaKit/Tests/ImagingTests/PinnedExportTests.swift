import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Failure modes (PIN-02, RED-01, RED-02): a pinned export that differs from the document's own
// sanitized export, keeps source metadata, depends on pixels under a secure mask, or is resampled
// away from the pinned raster's size.
@Suite("PIN-02: a pin's raster exports through the single pipeline")
struct PinnedExportTests {
    private static let secret = FixtureRect(x: 5, y: 5, width: 10, height: 10)

    private func maskedSession(_ harness: ImagingHarness, _ image: CGImage) async throws -> DocumentSession {
        let asset = try await harness.add(image)
        var session = DocumentSession(document: Document(asset: asset))
        try session.addSecureMask(covering: Rect(x: 5, y: 5, width: 10, height: 10))
        try session.perform("Annotate") {
            $0.annotations.append(Annotation(kind: .step(center: Point(x: 30, y: 20), number: 1), style: .default))
        }
        return session
    }

    private func pinnedSnapshot(
        _ harness: ImagingHarness, _ session: DocumentSession, _ options: ExportOptions = ExportOptions(),
        exportID: DocumentID = DocumentID()
    ) async throws -> ShareSnapshot {
        // The pin holds what the sanitizing renderer produced at 1x (PinsModel.pin).
        let raster = try await harness.renderer.render(session.document, scale: 1)
        return try await harness.pipeline.snapshot(
            ofPinned: raster, exportID: exportID, privacyEpoch: session.privacyEpoch, options: options,
            date: fixedExportDate)
    }

    @Test("A pinned raster exports the same bytes as the document's 1x export, under the pin's identity")
    func matchesDocumentExport() async throws {
        let harness = ImagingHarness()
        let pair = try SecretPairFixture.make(width: 50, height: 40, secret: Self.secret, seed: 11)
        let session = try await maskedSession(harness, pair.a)
        let exportID = DocumentID()
        for options in [ExportOptions(), ExportOptions(format: .jpeg(quality: 0.8))] {
            let pinned = try await pinnedSnapshot(harness, session, options, exportID: exportID)
            let document = try await harness.export(session, options)
            #expect(pinned.bytes == document.bytes, "same sanitized pixels, same fresh encoding")
            #expect(pinned.documentID == exportID && pinned.revision == 0)
            #expect(pinned.privacyEpoch == session.privacyEpoch)
            #expect(pinned.pixelSize == document.pixelSize)
            #expect(pinned.suggestedFilename == document.suggestedFilename)
        }
        let png = try await pinnedSnapshot(harness, session)
        let chunks = try ContainerInspector.pngChunkTypes(png.bytes)
        #expect(Set(chunks).isSubset(of: ExportContainerTests.allowedPNGChunks), "unexpected chunks: \(chunks)")
        #expect(ContainerInspector.propertyKeys(png.bytes).isDisjoint(with: ExportContainerTests.forbiddenPropertyKeys))
    }

    @Test("RED-01: two sources differing only under the mask give identical pinned exports")
    func pairedSecretsAreIndistinguishable() async throws {
        let harness = ImagingHarness()
        let pair = try SecretPairFixture.make(width: 50, height: 40, secret: Self.secret, seed: 17)
        let a = try await maskedSession(harness, pair.a)
        let b = try await maskedSession(harness, pair.b)
        for options in [ExportOptions(), ExportOptions(format: .jpeg(quality: 0.9))] {
            let exportA = try await pinnedSnapshot(harness, a, options)
            let exportB = try await pinnedSnapshot(harness, b, options)
            #expect(exportA.bytes == exportB.bytes)
        }
        // Control: without the mask the two sources must differ, or the comparison proves nothing.
        let rawA = DocumentSession(document: Document(asset: try await harness.add(pair.a)))
        let rawB = DocumentSession(document: Document(asset: try await harness.add(pair.b)))
        let unmaskedA = try await pinnedSnapshot(harness, rawA)
        let unmaskedB = try await pinnedSnapshot(harness, rawB)
        #expect(unmaskedA.bytes != unmaskedB.bytes)
    }

    @Test("A pinned raster exports only at its own size")
    func onlyOwnScale() async throws {
        let harness = ImagingHarness()
        let pair = try SecretPairFixture.make(width: 50, height: 40, secret: Self.secret, seed: 5)
        let session = try await maskedSession(harness, pair.a)
        await #expect(throws: ExportError.invalidOptions(.invalidScale)) {
            try await pinnedSnapshot(harness, session, ExportOptions(scale: 2))
        }
        await #expect(throws: ExportError.invalidOptions(.invalidQuality)) {
            try await pinnedSnapshot(harness, session, ExportOptions(format: .jpeg(quality: 2)))
        }
    }
}
