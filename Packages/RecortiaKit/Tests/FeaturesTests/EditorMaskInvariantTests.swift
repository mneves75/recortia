import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Features

// Failure modes (FR-06, RED-04): an edit that is not an effective move or resize of a mask moves
// its box or drops what it hides, so the export shows the secret. A box moves only when the person
// moves that mask. Every case checks the exported pixels, not only the model.
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

    // MARK: R1–R3 a layer edit never moves a box or drops protection

    @Test("Dragging a layer leaves the box in place and the secret filled where the layer now is")
    func layerDragLeavesBox() async throws {
        let fixture = try await SecretExport(secret: Self.secret)
        let h = fixture.harness
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        let mask = try #require(m.document.masks.first)
        m.selectTool(.select)
        m.clearSelection()
        h.drag((200, 200), (300, 200))
        #expect(m.document.layers.first?.placement.translation == Point(x: 100, y: 0))
        #expect(m.document.masks == [mask])
        let pixels = try await fixture.exported()
        #expect(fixture.secretPixels(in: pixels) == 0)
        #expect(fixture.uncoveredPixels(in: pixels, FixtureRect(x: 10, y: 10, width: 20, height: 20)) == 0)
        #expect(fixture.uncoveredPixels(in: pixels, FixtureRect(x: 110, y: 10, width: 20, height: 20)) == 0)
    }

    @Test("Moving layers does not change what a box hides on a pasted image (paired export, R4-02)")
    func boxKeepsLateCoverage() async throws {
        let box = FixtureRect(x: 100, y: 100, width: 20, height: 20)
        var exports: [[DecodedPixels]] = []
        for green: UInt8 in [0, 200] {
            let fixture = try await SecretExport(secret: box)
            let h = fixture.harness
            let m = h.model
            m.selectTool(.redact)
            h.drag((100, 100), (120, 120))
            let a = try #require(m.document.layers.first).id
            let b = try await fixture.addLayer(secrets: [box], green: green)
            m.selectTool(.select)
            var run = [try await fixture.exported()]
            m.setFrame(Rect(x: 50, y: 0, width: 400, height: 300), for: .layer(a))
            run.append(try await fixture.exported())
            m.setFrame(Rect(x: 50, y: 0, width: 400, height: 300), for: .layer(b))
            run.append(try await fixture.exported())
            #expect(run.allSatisfy { fixture.secretPixels(in: $0) == 0 })
            exports.append(run)
        }
        #expect(exports[0][0] == exports[1][0], "the variants differ only inside the box")
        #expect(exports[0][1] == exports[1][1], "moving A must not uncover B inside the box")
        #expect(exports[0][2] == exports[1][2], "moving B off the box must keep its pixels filled")
    }

    @Test("Moving the image out from under a box keeps a stationary object in the box covered (R4-03)")
    func boxKeepsStationaryObject() async throws {
        let fixture = try await SecretExport(secret: FixtureRect(x: 20, y: 20, width: 10, height: 10))
        let h = fixture.harness
        let m = h.model
        m.setFillColor(.yellow)
        m.selectTool(.rectangle)
        h.drag((40, 20), (100, 40))
        m.selectTool(.redact)
        h.drag((10, 10), (180, 60))
        let layer = try #require(m.document.layers.first).id
        m.selectTool(.select)
        m.setFrame(Rect(x: 200, y: 0, width: 400, height: 300), for: .layer(layer))
        let pixels = try await fixture.exported()
        #expect(fixture.uncoveredPixels(in: pixels, FixtureRect(x: 10, y: 10, width: 170, height: 50)) == 0)
        #expect(fixture.secretPixels(in: pixels, FixtureRect(x: 200, y: 0, width: 200, height: 100)) == 0)
    }

    @Test("Moving a box keeps the protection of pixels its layer already carried away (R3)")
    func explicitMoveKeepsDisplaced() async throws {
        let (fixture, maskID, _) = try await maskWithMovedLayer()
        let m = fixture.harness.model
        #expect(m.document.masks.first?.outputRect == Rect(x: 10, y: 10, width: 20, height: 20))
        #expect(try await secretCovered(fixture, at: 110) == 0)
        m.select(.mask(maskID))
        fixture.harness.drag((20, 20), (60, 20))
        #expect(m.document.masks.first?.outputRect == Rect(x: 50, y: 10, width: 20, height: 20))
        #expect(try await secretCovered(fixture, at: 110) == 0)
    }

    @Test("Align moves a selected layer and its selected mask once, from the same starting document (R4-01)")
    func alignResolvesFromOneSnapshot() async throws {
        let fixture = try await SecretExport(secret: FixtureRect(x: 0, y: 100, width: 20, height: 20))
        let h = fixture.harness
        let m = h.model
        let layer = try #require(m.document.layers.first).id
        m.setFrame(Rect(x: 100, y: 0, width: 400, height: 300), for: .layer(layer))
        m.selectTool(.redact)
        h.drag((100, 100), (120, 120))
        let mask = try #require(m.document.masks.first).id
        m.setFillColor(.yellow)
        m.selectTool(.rectangle)
        h.drag((0, 200), (40, 240))
        let rectangle = try #require(m.document.annotations.first).id
        m.selectTool(.select)
        m.setSelection([.layer(layer), .mask(mask), .annotation(rectangle)])
        m.align(.left)
        #expect(m.document.layers.first?.placement.translation == .zero)
        #expect(m.document.masks.first?.outputRect == Rect(x: 0, y: 100, width: 20, height: 20))
        let pixels = try await fixture.exported()
        #expect(fixture.secretPixels(in: pixels, FixtureRect(x: 0, y: 100, width: 120, height: 20)) == 0)
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

    @Test(
        "A mask handle grabs exactly on the square the canvas draws, in both contrast modes", arguments: [false, true])
    func handleHitMatchesDrawnSquare(increasedContrast: Bool) throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.redact)
        h.drag((100, 100), (120, 120))
        let mask = try #require(m.document.masks.first)
        m.selectTool(.select)
        m.select(.mask(mask.id))
        m.handlesDrawnWithIncreasedContrast = increasedContrast
        let side = EditorModel.handleSquareSide(increasedContrast: increasedContrast)
        #expect(side == (increasedContrast ? 10 : 8))
        // 4.5 pt right of the right handle's center: inside the 10 pt square, outside the 8 pt one.
        // Outside the square the press lands on the image, which carries the mask unresized.
        h.drag((124.5, 110), (134.5, 110))
        let width = try #require(m.document.masks.first).outputRect.width
        #expect(width == (increasedContrast ? 30 : 20))
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

    // MARK: I4 Undo during a gesture cancels only the gesture

    @Test("Undo during a mask drag cancels the drag and keeps the mask")
    func undoDuringDragKeepsMask() async throws {
        let fixture = try await SecretExport(secret: Self.secret)
        let h = fixture.harness
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        let mask = try #require(m.document.masks.first)
        m.selectTool(.select)
        let history = m.session.undoCount
        m.pointerDown(at: Point(x: 20, y: 20))
        m.pointerDragged(to: Point(x: 60, y: 20))
        m.undo()
        #expect(m.document.masks == [mask])
        #expect(m.session.undoCount == history)
        m.pointerUp(at: Point(x: 60, y: 20))
        #expect(m.document.masks == [mask])
        #expect(try await secretCovered(fixture, at: 10) == 0)

        m.undo()
        #expect(m.document.masks.isEmpty)
        m.pointerDown(at: Point(x: 200, y: 200))
        m.pointerDragged(to: Point(x: 220, y: 220))
        m.redo()
        #expect(m.document.masks.isEmpty, "Redo during a gesture cancels the gesture only")
        m.pointerUp(at: Point(x: 220, y: 220))
    }
}
