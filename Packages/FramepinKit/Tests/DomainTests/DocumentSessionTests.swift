import Foundation
import Testing

@testable import Domain

private func makeDocument(assetSize: PixelSize = PixelSize(width: 200, height: 100)) -> (Document, AssetID) {
    let asset = ImageAssetInfo(id: AssetID(), pixelSize: assetSize, origin: .imported)
    return (Document(asset: asset), asset.id)
}

private func arrow(_ x: Double) -> Annotation {
    Annotation(kind: .arrow(start: Point(x: x, y: 0), end: Point(x: x + 10, y: 10)), style: .default)
}

@Suite("Document session: revisions, undo, privacy epoch (EDIT-01, RED-03)")
struct DocumentSessionTests {
    @Test("A new document is sized to its asset and has one layer")
    func newDocumentFromAsset() {
        let (doc, assetID) = makeDocument()
        #expect(doc.canvasSize == Size(width: 200, height: 100))
        #expect(doc.layers.count == 1)
        #expect(doc.layers[0].assetID == assetID)
        #expect(doc.assets[assetID]?.pixelSize == PixelSize(width: 200, height: 100))
    }

    @Test("Every change bumps the revision; undo and redo restore the model exactly")
    func undoRedoRestoresModel() throws {
        var session = DocumentSession(document: makeDocument().0)
        let original = session.document
        try session.perform("Add arrow") { $0.annotations.append(arrow(1)) }
        try session.perform("Add arrow") { $0.annotations.append(arrow(2)) }
        let edited = session.document
        #expect(session.revision == 2)

        session.undo()
        session.undo()
        #expect(session.document == original)
        #expect(session.revision == 4, "undo is a new revision so stale results are rejected")
        session.redo()
        session.redo()
        #expect(session.document == edited)
        #expect(!session.canRedo)
    }

    @Test("A gesture group is one undo step no matter how many updates it contains")
    func gestureIsOneUndoGroup() throws {
        var session = DocumentSession(document: makeDocument().0)
        try session.perform("Add") { $0.annotations.append(arrow(0)) }
        let beforeDrag = session.document
        session.beginGroup("Move")
        for step in 1...50 {
            try session.perform("Move") { $0.annotations[0] = arrow(Double(step)) }
        }
        session.endGroup()
        #expect(session.undoCount == 2)
        session.undo()
        #expect(session.document == beforeDrag)
    }

    @Test("A failing change leaves the document and revision untouched")
    func failedChangeIsAtomic() {
        struct Boom: Error {}
        var session = DocumentSession(document: makeDocument().0)
        let before = session.document
        #expect(throws: Boom.self) {
            try session.perform("Bad") { doc in
                doc.annotations.append(arrow(1))
                throw Boom()
            }
        }
        #expect(session.document == before)
        #expect(session.revision == 0)
        #expect(!session.canUndo)
    }

    @Test("The undo budget evicts the oldest complete groups and reports it")
    func undoBudgetEvictsOldest() throws {
        var session = DocumentSession(document: makeDocument().0, undoLimit: 3)
        for i in 0..<5 { try session.perform("Add \(i)") { $0.annotations.append(arrow(Double(i))) } }
        #expect(session.undoCount == 3)
        #expect(session.evictedUndoCount == 2)
        session.undo(); session.undo(); session.undo()
        #expect(session.document.annotations.count == 2, "the two evicted steps stay applied")
        #expect(!session.canUndo)
    }

    @Test("The privacy epoch only increases, including when undo removes a mask")
    func privacyEpochIsMonotonic() throws {
        let (doc, _) = makeDocument()
        var session = DocumentSession(document: doc)
        #expect(session.privacyEpoch == 0)
        try session.perform("Annotate") { $0.annotations.append(arrow(1)) }
        #expect(session.privacyEpoch == 0, "annotations do not change privacy state")
        try session.addSecureMask(covering: Rect(x: 10, y: 10, width: 20, height: 5))
        #expect(session.privacyEpoch == 1)
        session.undo()
        #expect(session.document.masks.isEmpty)
        #expect(session.privacyEpoch == 2)
        session.redo()
        #expect(session.privacyEpoch == 3)
    }

    @Test("Saved marker tracks dirtiness across undo")
    func savedMarker() throws {
        var session = DocumentSession(document: makeDocument().0)
        #expect(!session.isDirty)
        try session.perform("Add") { $0.annotations.append(arrow(1)) }
        #expect(session.isDirty)
        session.markSaved()
        #expect(!session.isDirty)
        session.undo()
        #expect(session.isDirty)
        session.redo()
        #expect(!session.isDirty)
    }

    @Test("Request identity goes stale on any revision or epoch change")
    func requestIdentityStaleness() throws {
        var session = DocumentSession(document: makeDocument().0)
        let identity = session.requestIdentity()
        #expect(session.accepts(identity))
        try session.perform("Add") { $0.annotations.append(arrow(1)) }
        #expect(!session.accepts(identity))
        let fresh = session.requestIdentity()
        #expect(session.accepts(fresh))
        #expect(fresh.requestID != identity.requestID)
    }
}

@Suite("Secure masks are bound to source pixels (FR-06)")
struct SecureMaskTests {
    @Test("A mask maps outward into the asset's pixel space")
    func maskMapsToSource() throws {
        let (doc, assetID) = makeDocument()
        var session = DocumentSession(document: doc)
        try session.addSecureMask(covering: Rect(x: 10.4, y: 5.6, width: 20, height: 3))
        let mask = try #require(session.document.masks.first)
        #expect(mask.sourceRegions[assetID] == [PixelRect(x: 10, y: 5, width: 21, height: 4)])
        #expect(mask.fill.alpha == 255)
    }

    @Test("A scaled, translated layer maps the mask through the inverse transform")
    func maskThroughScaledLayer() throws {
        var (doc, assetID) = makeDocument()
        doc.layers[0].placement = LayerPlacement(translation: Point(x: 100, y: 50), scale: 2, rotation: 0)
        doc.canvasSize = Size(width: 600, height: 300)
        var session = DocumentSession(document: doc)
        try session.addSecureMask(covering: Rect(x: 120, y: 60, width: 40, height: 20))
        #expect(session.document.masks[0].sourceRegions[assetID] == [PixelRect(x: 10, y: 5, width: 20, height: 10)])
    }

    @Test("Two layers sharing one asset both receive the source-bound mask")
    func duplicateReferencesShareMask() throws {
        var (doc, assetID) = makeDocument()
        var copy = doc.layers[0]
        copy.id = LayerID()
        copy.placement.translation = Point(x: 300, y: 0)
        doc.layers.append(copy)
        doc.canvasSize = Size(width: 600, height: 100)
        var session = DocumentSession(document: doc)
        try session.addSecureMask(covering: Rect(x: 0, y: 0, width: 5, height: 5))
        let regions = try #require(session.document.masks.first?.sourceRegions[assetID])
        #expect(regions == [PixelRect(x: 0, y: 0, width: 5, height: 5)])
        #expect(session.document.masks[0].appliesToEveryReference)
    }

    @Test("A mask outside every layer still keeps its output-space coverage")
    func maskOutsideLayersKeepsOutputCoverage() throws {
        var (doc, _) = makeDocument()
        doc.canvasSize = Size(width: 400, height: 100)
        var session = DocumentSession(document: doc)
        try session.addSecureMask(covering: Rect(x: 300, y: 10, width: 20, height: 20))
        #expect(session.document.masks[0].sourceRegions.isEmpty)
        #expect(session.document.masks[0].outputRect == Rect(x: 300, y: 10, width: 20, height: 20))
    }

    @Test("Translucent mask fills are refused")
    func refusesTranslucentFill() {
        var session = DocumentSession(document: makeDocument().0)
        #expect(throws: DocumentError.translucentSecureMask) {
            try session.addSecureMask(
                covering: Rect(x: 0, y: 0, width: 5, height: 5), fill: RGBA(r: 0, g: 0, b: 0, a: 254))
        }
        #expect(session.document.masks.isEmpty)
    }

    @Test("A degenerate layer transform refuses the mask instead of silently skipping the layer")
    func degenerateLayerRefusesMask() {
        var (doc, _) = makeDocument()
        doc.layers[0].placement.scale = 0
        var session = DocumentSession(document: doc)
        #expect(throws: DocumentError.unmappableTransform) {
            try session.addSecureMask(covering: Rect(x: 0, y: 0, width: 5, height: 5))
        }
        #expect(session.document.masks.isEmpty)
    }
}
