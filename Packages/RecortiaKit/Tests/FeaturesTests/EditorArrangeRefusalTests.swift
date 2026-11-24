import Domain
import Testing

@testable import Features

// Failure mode: an Arrange command (menu bar, context menu) chosen while text input owns the
// keyboard, IME composition included, commits or duplicates the text under the input.
@Suite("Arrange commands refuse during text input")
@MainActor
struct EditorArrangeRefusalTests {
    @Test("Duplicate, reorder and align leave the document and the text input alone")
    func refusesWhileEditingText() throws {
        let h = EditorHarness()
        defer { h.model.close() }
        let model = h.model
        model.selectTool(.text)
        h.click(20, 30)
        model.commitTextEditing("Água")
        let id = try #require(model.document.annotations.first).id
        // A shape above the text, so Bring to Front and Align would each change the document.
        model.selectTool(.rectangle)
        h.drag((120, 120), (220, 200))
        try #require(model.document.annotations.count == 2)
        model.selectTool(.select)
        model.select(.annotation(id))
        #expect(model.canArrangeSelection)
        model.beginEditingText(id)
        let input = model.textEditing
        let before = model.document
        #expect(!model.canArrangeSelection)

        model.duplicateSelection()
        #expect(model.document == before, "Duplicate changed the document")
        model.reorderSelection(.front)
        #expect(model.document == before, "Bring to Front changed the document")
        model.reorderSelection(.forward)
        #expect(model.document == before, "Bring Forward changed the document")
        model.align(.right)
        #expect(model.document == before, "Align changed the document")
        #expect(model.textEditing == input)
    }
}
