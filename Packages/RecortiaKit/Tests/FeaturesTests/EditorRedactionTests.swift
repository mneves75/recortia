import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Features

// Failure modes (FR-06, RED-04): blur or pixelate classified or stored as secure; a redaction
// stored as a translucent overlay or an annotation; mask edges rounded inward so an edge pixel
// survives; a moved mask still bound to its old source pixels; a mask over an unmappable layer
// silently accepted; a translucent redaction color accepted.
@Suite("Editor redaction labeling and masks (RED-04)")
@MainActor
struct EditorRedactionTests {

    @Test("Blur and Pixelate add cosmetic effects only and leave the privacy epoch alone")
    func cosmeticToolsAreNotMasks() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.blur)
        h.drag((10, 10), (60, 60))
        m.selectTool(.pixelate)
        h.drag((100, 10), (160, 60))
        #expect(m.document.masks.isEmpty)
        #expect(m.document.obfuscations.map(\.style) == [.blur(radius: 12), .pixelate(blockSize: 12)])
        #expect(m.session.privacyEpoch == 0)
        #expect(m.listItems.filter { $0.kind.isCosmetic }.count == 2)
        #expect(m.listItems.allSatisfy { !$0.kind.isSecure })
    }

    @Test("Redact adds an opaque source-bound mask with edges rounded outward")
    func redactIsOpaqueAndOutward() throws {
        let h = EditorHarness()
        let m = h.model
        m.setRedactionFill(RGBA(r: 255, g: 255, b: 255, a: 10))
        #expect(m.redactionFill == .white)
        m.selectTool(.redact)
        h.drag((10.6, 20.2), (30.1, 40.9))
        let mask = try #require(m.document.masks.first)
        #expect(mask.outputRect == Rect(x: 10, y: 20, width: 21, height: 21))
        #expect(mask.fill == .white)
        #expect(mask.fill.isOpaque)
        let assetID = try #require(m.document.layers.first?.assetID)
        #expect(mask.sourceRegions[assetID] == [PixelRect(x: 10, y: 20, width: 21, height: 21)])
        #expect(m.session.privacyEpoch == 1)
        #expect(m.selection == [.mask(mask.id)])
    }

    @Test("A redaction is clipped to the canvas; one fully outside adds nothing")
    func redactClipsToCanvas() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.redact)
        h.drag((380, 280), (450, 350))
        #expect(m.document.masks.first?.outputRect == Rect(x: 380, y: 280, width: 20, height: 20))
        h.drag((500, 500), (600, 600))
        #expect(m.document.masks.count == 1)
    }

    @Test("Moving or resizing a redaction re-derives its source pixels")
    func movedMaskRebinds() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        let assetID = try #require(m.document.layers.first?.assetID)
        m.selectTool(.select)
        h.drag((20, 20), (70.4, 20.2))
        var mask = try #require(m.document.masks.first)
        #expect(mask.outputRect == Rect(x: 60, y: 10, width: 20, height: 20))
        #expect(mask.sourceRegions[assetID] == [PixelRect(x: 60, y: 10, width: 20, height: 20)])
        m.setFrame(Rect(x: 5.5, y: 5, width: 10, height: 10), for: .mask(mask.id))
        mask = try #require(m.document.masks.first)
        #expect(mask.outputRect == Rect(x: 5, y: 5, width: 11, height: 10))
        #expect(mask.sourceRegions[assetID] == [PixelRect(x: 5, y: 5, width: 11, height: 10)])
    }

    @Test("A stationary click on a mask handle keeps the mask; a drag moves the edge by the pointer's delta")
    func handleClickKeepsMask() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        let assetID = try #require(m.document.layers.first?.assetID)
        m.selectTool(.select)
        let historyBefore = m.session.undoCount
        h.click(26, 20)
        var mask = try #require(m.document.masks.first)
        #expect(mask.outputRect == Rect(x: 10, y: 10, width: 20, height: 20))
        #expect(m.session.undoCount == historyBefore)
        h.drag((26, 20), (36, 20))
        mask = try #require(m.document.masks.first)
        #expect(mask.outputRect == Rect(x: 10, y: 10, width: 30, height: 20))
        #expect(mask.sourceRegions[assetID] == [PixelRect(x: 10, y: 10, width: 30, height: 20)])
    }

    @Test("A click on a mask covering a magnifier selects the mask, which draws on top")
    func maskOverMagnifierWinsHitTest() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.magnifier)
        h.drag((100, 100), (130, 120))
        guard case .magnifier(_, let destination) = try #require(m.document.callouts.first).kind else {
            Issue.record("expected a magnifier")
            return
        }
        m.selectTool(.redact)
        h.drag((destination.minX - 2, destination.minY - 2), (destination.maxX + 2, destination.maxY + 2))
        let mask = try #require(m.document.masks.first)
        m.selectTool(.select)
        m.clearSelection()
        h.click(destination.midX, destination.midY)
        #expect(m.selection == [.mask(mask.id)])
    }

    @Test("A drag on magnifier pixels beside a mask moves the magnifier and the secret stays covered")
    func magnifierBesideMaskKeepsSecretCovered() async throws {
        let fixture = try await SecretExport(secret: FixtureRect(x: 100, y: 100, width: 20, height: 20))
        let h = fixture.harness
        let m = h.model
        m.selectTool(.redact)
        h.drag((100, 100), (120, 120))
        let mask = try #require(m.document.masks.first)
        m.selectTool(.magnifier)
        h.drag((300, 200), (330, 220))
        let magnifier = try #require(m.document.callouts.first)
        m.setFrame(Rect(x: 118, y: 100, width: 60, height: 40), for: .callout(magnifier.id))
        #expect(m.frame(of: .callout(magnifier.id))?.minX == 118)
        m.selectTool(.select)
        m.clearSelection()
        // x = 122 is outside the mask but inside its hit tolerance, and on the magnifier's pixels.
        h.drag((122, 110), (137, 110))
        #expect(m.document.masks.first?.outputRect == mask.outputRect)
        #expect(m.selection == [.callout(magnifier.id)])
        let pixels = try await fixture.exported()
        #expect(fixture.secretPixels(in: pixels, FixtureRect(x: 100, y: 100, width: 20, height: 20)) == 0)
    }

    @Test("A redaction over a layer whose transform cannot be inverted is refused")
    func unmappableLayerRefused() {
        let asset = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 100, height: 100), origin: .imported)
        let degenerate = ImageLayer(assetID: asset.id, placement: LayerPlacement(scale: 0))
        let document = Document(
            assets: [asset.id: asset], canvasSize: Size(width: 100, height: 100), layers: [degenerate])
        let h = EditorHarness(session: DocumentSession(document: document))
        h.model.selectTool(.redact)
        h.drag((10, 10), (40, 40))
        #expect(h.model.document.masks.isEmpty)
        #expect(h.model.notice == .redactionRefused)
        #expect(h.model.session.privacyEpoch == 0)
    }

    @Test("Changing the redaction color of a selected mask keeps it opaque and bumps the epoch")
    func recolorMask() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.redact)
        h.drag((10, 10), (30, 30))
        m.setRedactionFill(RGBA(r: 20, g: 40, b: 60, a: 0))
        #expect(m.document.masks.first?.fill == RGBA(r: 20, g: 40, b: 60))
        #expect(m.session.privacyEpoch == 2)
    }
}
