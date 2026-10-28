import Domain
import Foundation
import Testing

@testable import Features

/// `listItems` is asked for by the canvas on every observed change, including the draft that moves
/// on each pointer event, and resolving a text item's frame is a full Core Text layout. The memo is
/// therefore a performance invariant: these tests assert how many times geometry is resolved, which
/// is deterministic, rather than how long it takes, which this host cannot qualify.
@Suite("Editor list items are memoised against the document revision")
@MainActor
struct EditorListItemsMemoTests {
    @Test("Repeated reads and pointer work resolve geometry once until the document changes")
    func memoisesUntilRevisionMoves() throws {
        let harness = EditorHarness()
        defer { harness.model.close() }
        let model = harness.model

        let first = model.listItems
        let resolved = model.listItemGeometryResolutions
        #expect(resolved > 0, "the first read has to resolve geometry")
        #expect(resolved == first.count, "one resolution per item on the first read")

        // Selection, tool and zoom are observed by the canvas but do not touch the document.
        let layer = try #require(first.first?.id)
        model.select(layer)
        model.selectTool(.rectangle)
        model.setZoom(1.75)
        #expect(model.listItems == first, "selection, tool and zoom must not change the list")
        #expect(
            model.listItemGeometryResolutions == resolved,
            "selection, tool or zoom re-resolved the list: \(model.listItemGeometryResolutions - resolved) extra")

        // A drawing gesture moves the draft on every pointer event and only commits on mouse up.
        model.pointerDown(at: Point(x: 900, y: 900))
        model.pointerDragged(to: Point(x: 980, y: 950))
        #expect(
            model.listItemGeometryResolutions == resolved,
            "an in-flight draft re-resolved the list: \(model.listItemGeometryResolutions - resolved) extra")
        model.pointerUp(at: Point(x: 980, y: 950))
        #expect(model.listItems != first, "the committed rectangle belongs in the list")

        // A document change invalidates the memo, and only once.
        try model.session.addSecureMask(covering: Rect(x: 0, y: 0, width: 2, height: 2))
        let afterMask = model.listItems
        let afterResolution = model.listItemGeometryResolutions
        #expect(afterMask != first, "the new mask belongs in the list")
        #expect(
            afterResolution > resolved,
            "a document change must resolve the new list at least once")
        // The exact count is not the invariant: a mutation may read the list itself (selection
        // cleanup does). What must hold is that the *same* revision is never resolved twice.
        let settled = model.listItemGeometryResolutions
        _ = model.listItems
        _ = model.listItems
        #expect(
            model.listItemGeometryResolutions == settled,
            "a settled revision was resolved again: +\(model.listItemGeometryResolutions - settled)")
        #expect(model.listItems == afterMask)
    }
}
