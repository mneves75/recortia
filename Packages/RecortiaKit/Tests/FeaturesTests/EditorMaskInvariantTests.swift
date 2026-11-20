import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Features

// Failure modes (FR-06, RED-04, decisions "masks move with layers"): a mask re-binds its hidden
// source pixels as a side effect of an edit that is not an effective move or resize of that mask,
// so the export shows the secret. Every case checks the exported pixels, not only the model.
@Suite("Secure masks keep their secret covered through geometry edits (RED-04)")
@MainActor
struct EditorMaskInvariantTests {
    private static let secret = FixtureRect(x: 10, y: 10, width: 20, height: 20)

    /// A mask over the secret at (10, 10)–(30, 30), its layer then moved 100 px right.
    private func maskWithMovedLayer() async throws -> (SecretExport, MaskID, LayerID) {
        let fixture = try await SecretExport(secret: Self.secret)
        let h = fixture.harness
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        let maskID = try #require(m.document.masks.first).id
        let layerID = try #require(m.document.layers.first).id
        m.selectTool(.select)
        m.setFrame(Rect(x: 100, y: 0, width: 400, height: 300), for: .layer(layerID))
        return (fixture, maskID, layerID)
    }

    private func secretCovered(_ fixture: SecretExport, at x: Int) async throws -> Int {
        fixture.secretPixels(in: try await fixture.exported(), FixtureRect(x: x, y: 10, width: 20, height: 20))
    }

    // MARK: I1 masks follow their layer

    @Test("Moving a layer carries its masks with their bindings; a co-move with the mask keeps them too")
    func masksFollowTheirLayer() async throws {
        let (fixture, maskID, layerID) = try await maskWithMovedLayer()
        let m = fixture.harness.model
        let bound = try #require(m.document.masks.first).sourceRegions
        #expect(m.document.masks.first?.outputRect == Rect(x: 110, y: 10, width: 20, height: 20))
        #expect(try await secretCovered(fixture, at: 110) == 0)

        m.setSelection([.layer(layerID), .mask(maskID)])
        m.nudgeSelection(dx: 1, dy: 0)
        #expect(m.document.masks.first?.outputRect == Rect(x: 111, y: 10, width: 20, height: 20))
        #expect(m.document.masks.first?.sourceRegions == bound)
        #expect(try await secretCovered(fixture, at: 111) == 0)
    }
}
