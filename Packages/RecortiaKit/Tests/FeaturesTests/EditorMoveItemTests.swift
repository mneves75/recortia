import Domain
import Testing

@testable import Features

// Failure modes: a drag in the object list that moves the wrong object, leaves its stack, runs
// past either end, or takes more than one undo step.
@Suite("Editor object list reorder")
@MainActor
struct EditorMoveItemTests {
    @Test("Moving an object reorders only its own stack, clamps at the ends and undoes in one step")
    func moveWithinStack() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.rectangle)
        h.drag((20, 20), (60, 60))
        h.drag((80, 20), (120, 60))
        h.drag((140, 20), (180, 60))
        let ids = m.document.annotations.map(\.id)
        try #require(ids.count == 3)
        let layers = m.document.layers
        let undoBefore = m.session.undoCount

        m.moveItem(.annotation(ids[0]), by: 2)
        #expect(m.document.annotations.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(m.document.layers == layers)
        #expect(m.session.undoCount == undoBefore + 1)

        m.moveItem(.annotation(ids[0]), by: 5)
        #expect(m.document.annotations.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(m.session.undoCount == undoBefore + 1)

        m.moveItem(.annotation(ids[0]), by: -9)
        #expect(m.document.annotations.map(\.id) == [ids[0], ids[1], ids[2]])

        m.undo()
        #expect(m.document.annotations.map(\.id) == [ids[1], ids[2], ids[0]])
    }
}
