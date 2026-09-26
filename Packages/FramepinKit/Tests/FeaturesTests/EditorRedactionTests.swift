import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-06, RED-04): blur or pixelate classified or stored as secure; a redaction
// stored as a translucent overlay or an annotation; mask edges rounded inward so an edge pixel
// survives; a moved mask still bound to its old source pixels; a mask over an unmappable layer
// silently accepted; a translucent redaction color accepted.
@Suite("Editor redaction labeling and masks (RED-04)")
@MainActor
struct EditorRedactionTests {
    @Test("Only Redact is secure; Blur and Pixelate are cosmetic and never secure")
    func toolClassification() {
        for tool in EditorTool.allCases {
            switch tool {
            case .redact:
                #expect(tool.isSecureRedaction && !tool.isCosmeticObfuscation)
            case .blur, .pixelate:
                #expect(!tool.isSecureRedaction && tool.isCosmeticObfuscation)
            default:
                #expect(!tool.isSecureRedaction && !tool.isCosmeticObfuscation)
            }
        }
        #expect(EditorItemKind.redaction.isSecure && !EditorItemKind.redaction.isCosmetic)
        #expect(!EditorItemKind.blur.isSecure && EditorItemKind.blur.isCosmetic)
        #expect(!EditorItemKind.pixelate.isSecure && EditorItemKind.pixelate.isCosmetic)
    }

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
