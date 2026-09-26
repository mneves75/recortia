import CoreGraphics
import Domain
import Foundation
import FramepinFixtures
import Testing

@testable import Imaging

@Suite("RED-03: mask changes, undo/redo, and stale results")
struct RenderMaskStalenessTests {
    private let secret = FixtureRect(x: 10, y: 8, width: 12, height: 6)

    @Test("Snapshots from older revisions or privacy epochs are rejected after mask edits, undo, and redo")
    func staleSnapshotsAreRejected() async throws {
        let harness = ImagingHarness()
        let pair = try SecretPairFixture.make(width: 40, height: 30, secret: secret, seed: 9)
        let asset = try await harness.add(pair.a)
        var session = DocumentSession(document: Document(asset: asset))

        let unmasked = try await harness.export(session)
        #expect(session.accepts(unmasked))

        try session.addSecureMask(covering: secret.documentRect)
        #expect(!session.accepts(unmasked))
        let masked = try await harness.export(session)
        #expect(session.accepts(masked))
        #expect(masked.privacyEpoch > unmasked.privacyEpoch)
        #expect(masked.bytes != unmasked.bytes)

        session.undo()
        #expect(!session.accepts(masked))
        #expect(!session.accepts(unmasked), "undo restored old masks but the epoch must not go back")
        let undone = try await harness.export(session)
        #expect(undone.bytes == unmasked.bytes)

        session.redo()
        #expect(!session.accepts(masked) && !session.accepts(undone))
        let redone = try await harness.export(session)
        #expect(session.accepts(redone))
        #expect(redone.bytes == masked.bytes)

        // A snapshot from another document is never accepted.
        let other = DocumentSession(document: Document(asset: asset))
        #expect(!other.accepts(redone))
    }

    @Test("Moving a mask re-renders from the source: the new area is filled, the old area shows source pixels")
    func changingTheMaskRerenders() async throws {
        let harness = ImagingHarness()
        let chart = try ChartFixture.geometryChart(width: 40, height: 30)
        let asset = try await harness.add(chart)
        var session = DocumentSession(document: Document(asset: asset))
        let fill = RGBA(r: 1, g: 2, b: 3)
        try session.addSecureMask(covering: Rect(x: 2, y: 2, width: 6, height: 6), fill: fill)
        let first = try decoded(try await harness.export(session))
        #expect(first.pixel(x: 4, y: 4) == color(1, 2, 3))

        try session.perform("Move mask") { document in
            document.masks = []
        }
        try session.addSecureMask(covering: Rect(x: 30, y: 20, width: 6, height: 6), fill: fill)
        let second = try decoded(try await harness.export(session))
        #expect(second.pixel(x: 4, y: 4) == ChartFixture.quadrantColors[0])
        #expect(second.pixel(x: 32, y: 22) == color(1, 2, 3))
    }

    @Test("A singular layer transform is rejected rather than rendered without its mask")
    func singularTransformIsRejected() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.geometryChart(width: 20, height: 20))
        let layer = ImageLayer(assetID: asset.id, placement: LayerPlacement(scale: 0))
        var session = DocumentSession(
            document: Document(assets: [asset.id: asset], canvasSize: Size(width: 20, height: 20), layers: [layer]))
        // Domain skips the degenerate layer (its zero-size bounds never intersect the mask), so
        // the mask carries no source region for it; the renderer must refuse the layer instead.
        try session.addSecureMask(covering: Rect(x: 0, y: 0, width: 5, height: 5))
        #expect(session.document.masks.first?.sourceRegions[asset.id] == nil)
        await #expect(throws: ExportError.render(.invalidGeometry)) {
            try await harness.export(session)
        }
    }

    @Test("A translucent secure mask is refused by the renderer")
    func translucentMaskIsRefused() async throws {
        let harness = ImagingHarness()
        let asset = try await harness.add(try ChartFixture.geometryChart(width: 20, height: 20))
        var document = Document(asset: asset)
        document.masks = [
            SecureMask(
                outputRect: Rect(x: 0, y: 0, width: 5, height: 5),
                sourceRegions: [asset.id: [PixelRect(x: 0, y: 0, width: 5, height: 5)]],
                fill: RGBA(r: 0, g: 0, b: 0, a: 250))
        ]
        await #expect(throws: RenderError.translucentSecureMask) {
            try await harness.renderer.render(document, scale: 1)
        }
    }
}
