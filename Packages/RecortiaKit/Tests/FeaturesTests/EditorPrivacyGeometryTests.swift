import Domain
import Testing

@testable import Features

@Suite("Mask geometry fails closed without changing editor history (RED-03, RED-04)")
@MainActor
struct EditorPrivacyGeometryTests {
    @Test("Creating and duplicating masks refuse overflowing source bounds", arguments: [false, true])
    func overflowingMaskAdmission(duplicate: Bool) throws {
        var document = EditorFixtures.session().document
        document.canvasSize.width = 1e304
        document.layers[0].placement.scale = 1e-5
        document.layers[0].placement.translation = Point(x: 20, y: 20)
        let rect = Rect<DocumentSpace>(x: 0, y: 0, width: 1e304, height: 40)
        let proposed =
            duplicate ? rect.offsetBy(dx: EditorModel.duplicateOffset, dy: EditorModel.duplicateOffset) : rect
        #expect(document.layers[0].documentBounds(assetSize: PixelSize(width: 400, height: 300)).intersects(proposed))
        let inverse = try document.layers[0].sourceToDocument(assetSize: PixelSize(width: 400, height: 300)).inverted()
        #expect(inverse.isFinite)
        #expect(inverse.apply(proposed).width.isInfinite)
        let assetID = try #require(document.layers.first?.assetID)
        let mask = SecureMask(
            outputRect: rect, sourceRegions: [assetID: [PixelRect(x: 0, y: 0, width: 400, height: 300)]], fill: .black)
        if duplicate { document.masks.append(mask) }
        let h = EditorHarness(session: DocumentSession(document: document))
        // This test exercises admission, not rendering an enormous canvas.
        h.renderer.baseImage = makeImage(width: 1, height: 1)
        defer { h.model.close() }
        let m = h.model
        m.setPadding(1)
        m.undo()
        let before = m.document
        let identity = m.session.requestIdentity()
        let redo = m.session.redoLabel
        if duplicate {
            m.select(.mask(mask.id))
            m.duplicateSelection()
        } else {
            #expect(m.addRedaction(covering: rect) == nil)
        }
        #expect(m.notice == .redactionRefused)
        #expect(m.document == before)
        #expect(m.session.revision == identity.revision)
        #expect(m.session.privacyEpoch == identity.privacyEpoch)
        #expect(m.session.document.id == identity.documentID)
        #expect(m.session.undoCount == 0)
        #expect(m.session.redoLabel == redo && m.session.canRedo)
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.files.saves.isEmpty)
    }
}
