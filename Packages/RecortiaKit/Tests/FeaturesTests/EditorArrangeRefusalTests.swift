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
        model.selectTool(.select)
        model.select(.annotation(id))
        #expect(model.canArrangeSelection)
        model.beginEditingText(id)
        let input = model.textEditing
        let before = model.document
        #expect(!model.canArrangeSelection)

        model.duplicateSelection()
        model.reorderSelection(.front)
        model.align(.left)

        #expect(model.document == before)
        #expect(model.textEditing == input)
    }
}
