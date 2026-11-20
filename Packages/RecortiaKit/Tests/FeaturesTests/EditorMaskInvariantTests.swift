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

    // MARK: I2 only an effective move or resize re-binds

    @Test("A stationary handle click at 12.5 % zoom leaves the mask, history and export untouched")
    func stationaryHandleClickAtLowZoom() async throws {
        let (fixture, maskID, _) = try await maskWithMovedLayer()
        let m = fixture.harness.model
        m.setZoom(0.125)
        #expect(m.viewport.documentLength(4) == 32, "the resize minimum exceeds the 20 px mask")
        m.select(.mask(maskID))
        let mask = try #require(m.document.masks.first)
        let history = m.session.undoCount
        let before = try await fixture.exported()
        let corner = Point<DocumentSpace>(x: mask.outputRect.minX, y: mask.outputRect.minY)
        m.pointerDown(at: corner)
        m.pointerUp(at: corner)
        #expect(m.document.masks.first == mask)
        #expect(m.session.undoCount == history)
        #expect(try await fixture.exported() == before)
    }

    @Test(
        "A handle drag that returns to its start leaves the mask, history and export untouched",
        arguments: [1.0, 0.125])
    func dragOutAndBack(zoom: Double) async throws {
        let (fixture, maskID, _) = try await maskWithMovedLayer()
        let m = fixture.harness.model
        m.setZoom(zoom)
        m.select(.mask(maskID))
        let mask = try #require(m.document.masks.first)
        let history = m.session.undoCount
        let before = try await fixture.exported()
        let grab = Point<DocumentSpace>(x: mask.outputRect.maxX - 4, y: mask.outputRect.midY)
        m.pointerDown(at: grab)
        m.pointerDragged(to: Point(x: grab.x + 100, y: grab.y))
        m.pointerDragged(to: grab)
        m.pointerUp(at: grab)
        #expect(m.document.masks.first == mask)
        #expect(m.session.undoCount == history)
        #expect(try await fixture.exported() == before)
    }

    @Test("A mask moved alone re-links to what is under its new place")
    func explicitMoveRebinds() async throws {
        let fixture = try await SecretExport(secret: Self.secret)
        let h = fixture.harness
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        m.selectTool(.select)
        h.drag((20, 20), (70, 20))
        let assetID = try #require(m.document.layers.first?.assetID)
        #expect(m.document.masks.first?.sourceRegions[assetID] == [PixelRect(x: 60, y: 10, width: 20, height: 20)])
        #expect(try await secretCovered(fixture, at: 10) == 400, "the person moved the mask off the secret")
    }

    // MARK: I3 the tolerance band only selects

    @Test("Beside a selected mask's handle, a drag on magnifier pixels moves the magnifier")
    func handleBandYieldsToMagnifier() async throws {
        let fixture = try await SecretExport(secret: FixtureRect(x: 100, y: 100, width: 20, height: 20))
        let h = fixture.harness
        let m = h.model
        m.selectTool(.redact)
        h.drag((100, 100), (120, 120))
        let mask = try #require(m.document.masks.first)
        m.selectTool(.magnifier)
        h.drag((300, 200), (330, 220))
        let magnifier = try #require(m.document.callouts.first).id
        m.setFrame(Rect(x: 118, y: 100, width: 60, height: 40), for: .callout(magnifier))
        m.selectTool(.select)
        m.select(.mask(mask.id))
        // (125, 110) is 5 pt from the right handle's center: inside its hit radius, outside its square.
        h.drag((125, 110), (115, 110))
        #expect(m.document.masks.first == mask)
        #expect(m.frame(of: .callout(magnifier))?.minX == 108)
        let pixels = try await fixture.exported()
        #expect(fixture.secretPixels(in: pixels, FixtureRect(x: 100, y: 100, width: 20, height: 20)) == 0)
    }

    @Test("A drag on a rectangle beside a mask moves the rectangle; the band never moves the mask")
    func bandYieldsToAnnotation() async throws {
        let fixture = try await SecretExport(secret: FixtureRect(x: 100, y: 100, width: 20, height: 20))
        let h = fixture.harness
        let m = h.model
        m.selectTool(.redact)
        h.drag((100, 100), (120, 120))
        let mask = try #require(m.document.masks.first)
        m.setFillColor(.yellow)
        m.selectTool(.rectangle)
        h.drag((122, 100), (160, 130))
        let rectangle = try #require(m.document.annotations.first).id
        m.selectTool(.select)
        m.clearSelection()
        h.drag((122, 110), (137, 110))
        #expect(m.document.masks.first == mask)
        #expect(m.frame(of: .annotation(rectangle))?.minX ?? 0 > 130)

        // Over the image alone, the band selects the mask but a drag does not move it.
        m.clearSelection()
        h.drag((110, 122), (110, 140))
        #expect(m.selection == [.mask(mask.id)])
        #expect(m.document.masks.first == mask)
        let pixels = try await fixture.exported()
        #expect(fixture.secretPixels(in: pixels, FixtureRect(x: 100, y: 100, width: 20, height: 20)) == 0)
    }
}
