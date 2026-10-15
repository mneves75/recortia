import Domain
import Features
import Foundation
import Testing

@Suite("Editable curved arrows (FR-05, EDIT-01, EDIT-02)")
@MainActor
struct EditorCurvedArrowTests {
    @Test("A nonfinite bend is explained without mutating the selected curve", arguments: [Double.nan, .infinity])
    func nonfiniteBend(_ invalid: Double) {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        let before = m.document
        let style = m.style
        let revision = m.session.revision
        #expect(!m.setArrowBend(Point(x: invalid, y: 60)))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == before && m.style == style && m.session.revision == revision)
    }

    @Test("Future defaults belong to one editor and closed editors refuse curve changes")
    func localDefaultAndClose() {
        let first = EditorHarness()
        #expect(first.model.setArrowCurved(true))
        let second = EditorHarness()
        #expect(!second.model.style.curvedArrows)
        first.model.close()
        let document = first.model.document, style = first.model.style
        let revision = first.model.session.revision
        #expect(!first.model.canSetArrowCurve)
        #expect(!first.model.setArrowCurved(false))
        #expect(!first.model.setArrowBend(Point(x: 20, y: 30)))
        #expect(first.model.document == document && first.model.style == style)
        #expect(first.model.session.revision == revision)
        second.model.close()
    }

    @Test("Drawing an unconstructible short curve refuses before creating an annotation")
    func creationRefusal() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        m.setLineWidth(40)
        let before = m.document
        h.drag((20, 40), (24, 40))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == before && m.session.undoCount == 0)
        m.setLineWidth(1)
        h.drag((20, 40), (24, 40))
        #expect(m.document.annotations.count == 1 && m.session.undoCount == 1)
    }

    @Test("A coincident endpoint drag refuses with a visible notice and no history entry")
    func endpointRefusal() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        m.selectTool(.select)
        let before = m.document
        let revision = m.session.revision
        m.pointerDown(at: Point(x: 180, y: 40))
        m.pointerDragged(to: Point(x: 20, y: 40))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == before && m.session.revision == revision)
        m.pointerUp(at: Point(x: 20, y: 40))
        #expect(m.document == before && m.session.undoCount == 1)
        h.drag((180, 40), (200, 60))
        #expect(
            m.document.annotations.last?.kind
                == .arrow(
                    start: Point(x: 20, y: 40), end: Point(x: 200, y: 60), control: Point(x: 110, y: 90)))
        m.undo()
        #expect(m.document == before)
    }

    @Test("An unconstructible frame reports an arrow refusal and preserves its valid shape")
    func frameRefusal() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        let id = try #require(m.document.annotations.last?.id)
        let before = m.document
        let revision = m.session.revision
        m.setFrame(Rect(x: 50, y: 50, width: 1, height: 0.5), for: .annotation(id))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == before && m.session.revision == revision)
        #expect(m.session.undoCount == 1)
    }

    @Test("Stroke width refuses an unconstructible curve before changing document or future style")
    func widthAdmission() throws {
        let arrow = Annotation(
            kind: .arrow(start: Point(x: 20, y: 40), end: Point(x: 24, y: 40), control: Point(x: 22, y: 41)),
            style: Annotation.Style(stroke: .red, lineWidth: 1))
        var document = EditorFixtures.session().document
        document.annotations = [arrow]
        let h = EditorHarness(session: DocumentSession(document: document))
        let m = h.model
        m.setLineWidth(1)
        m.select(.annotation(arrow.id))
        #expect(m.frame(of: .annotation(arrow.id)) != nil)
        let style = m.style
        m.setLineWidth(40)
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == document && m.style == style)
        #expect(m.session.undoCount == 0 && m.session.revision == 0)
        m.setLineWidth(2)
        #expect(m.document.annotations.last?.style.lineWidth == 2)
        #expect(m.style.lineWidth == 2)
        #expect(m.session.undoCount == 1)
        m.undo()
        #expect(m.document == document)
    }

    @Test("A finite move that collapses curve coordinates refuses without destroying Redo")
    func overflowingMovePreservesRedo() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        #expect(m.setArrowBend(Point(x: 100, y: 100)))
        let redo = m.document
        m.undo()
        let before = m.document
        let revision = m.session.revision
        let count = m.session.undoCount
        let redoLabel = m.session.redoLabel
        m.nudgeSelection(dx: .greatestFiniteMagnitude, dy: 0)
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == before)
        #expect(m.session.revision == revision && m.session.undoCount == count)
        #expect(m.session.redoLabel == redoLabel)
        m.redo()
        #expect(m.document == redo)
        m.nudgeSelection(dx: 2, dy: 3)
        #expect(m.document.annotations.last == redo.annotations.last?.translated(dx: 2, dy: 3))
        m.undo()
        #expect(m.document == redo)
    }

    @Test("An overflowing bend refuses explicitly before changing an active adjustment")
    func invalidBendPreservesAdjustment() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        let adjustment = m.beginContinuousChange()
        m.setLineWidth(6)
        let before = m.document
        let style = m.style
        let revision = m.session.revision
        let selection = m.selection
        let undoCount = m.session.undoCount
        let redoLabel = m.session.redoLabel
        #expect(!m.setArrowBend(Point(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude)))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == before && m.style == style && m.selection == selection)
        #expect(m.session.revision == revision && m.session.undoCount == undoCount)
        #expect(m.session.redoLabel == redoLabel)
        #expect(m.beginContinuousChange() == adjustment)
        m.endContinuousChange(adjustment)
    }

    @Test("Numeric bend editing targets the visible handle and selection follows painted ink")
    func numericBendAndSelection() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        let id = try #require(m.document.annotations.last?.id)
        let created = m.document
        #expect(m.setArrowBend(Point(x: 100, y: 100)))
        #expect(m.selectedArrowBend == Point(x: 100, y: 100))
        #expect(
            m.document.annotations.last?.kind
                == .arrow(
                    start: Point(x: 20, y: 40), end: Point(x: 180, y: 40), control: Point(x: 100, y: 160)))
        #expect(m.item(at: Point(x: 100, y: 100)) == .annotation(id))
        #expect(m.item(at: Point(x: 100, y: 40)) != .annotation(id))
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.document == created)
        m.redo()
        m.setFrame(Rect(x: 40, y: 60, width: 320, height: 120), for: .annotation(id))
        #expect(
            m.document.annotations.last?.kind
                == .arrow(
                    start: Point(x: 40, y: 60), end: Point(x: 360, y: 60), control: Point(x: 200, y: 300)))
        #expect(m.selectedArrowBend == Point(x: 200, y: 180))
    }

    @Test("The on-curve bend handle and endpoints drag atomically and Escape restores the gesture")
    func bendAndEndpointGestures() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        let created = m.document
        let id = try #require(m.document.annotations.last?.id)
        m.selectTool(.select)
        #expect(m.selectionHandles.count == 3)
        #expect(m.selectionHandles.contains { $0.point == Point(x: 100, y: 60) })
        h.drag((100, 60), (110, 90), steps: 20)
        #expect(
            m.document.annotations.last?.kind
                == .arrow(
                    start: Point(x: 20, y: 40), end: Point(x: 180, y: 40), control: Point(x: 120, y: 140)))
        #expect(m.selection == [.annotation(id)])
        #expect(m.session.undoCount == 2)
        let bent = m.document
        h.drag((180, 40), (200, 60), steps: 20)
        #expect(
            m.document.annotations.last?.kind
                == .arrow(
                    start: Point(x: 20, y: 40), end: Point(x: 200, y: 60), control: Point(x: 130, y: 150)))
        #expect(m.session.undoCount == 3)
        let resized = m.document
        m.pointerDown(at: Point(x: 120, y: 100))
        m.pointerDragged(to: Point(x: 100, y: 120))
        #expect(m.document != resized)
        m.cancelGesture()
        #expect(m.document == resized)
        #expect(m.session.undoCount == 3)
        m.undo()
        #expect(m.document == bent)
        m.undo()
        #expect(m.document == created)
        m.redo()
        #expect(m.document == bent)
    }

    @Test("Curved creation and selected straightening preserve independent defaults and undo")
    func creationAndStraightening() throws {
        let h = EditorHarness()
        let m = h.model
        let original = m.document
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        #expect(m.style.curvedArrows)
        #expect(m.session.undoCount == 0)
        h.drag((20, 40), (180, 40))
        let arrow = try #require(m.document.annotations.last)
        #expect(
            arrow.kind == .arrow(start: Point(x: 20, y: 40), end: Point(x: 180, y: 40), control: Point(x: 100, y: 80)))
        #expect(m.selectedArrowBend == Point(x: 100, y: 60))
        #expect(m.session.undoCount == 1)
        let curved = m.document
        #expect(m.setArrowCurved(false))
        #expect(m.document.annotations.last?.id == arrow.id)
        #expect(m.document.annotations.last?.kind == .arrow(start: Point(x: 20, y: 40), end: Point(x: 180, y: 40)))
        #expect(!m.style.curvedArrows)
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.document == curved)
        #expect(!m.style.curvedArrows)
        m.redo()
        #expect(m.selectedArrowBend == nil)
        m.undo()
        m.undo()
        #expect(m.document == original)
    }
}
