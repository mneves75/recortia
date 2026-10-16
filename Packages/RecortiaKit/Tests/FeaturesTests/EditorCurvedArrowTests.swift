import Domain
import Features
import Foundation
import Testing

@Suite("Editable curved arrows (FR-05, EDIT-01, EDIT-02)")
@MainActor
struct EditorCurvedArrowTests {

    @Test("Refused curve creation keeps the preceding adjustment open")
    func refusedCreationPreservesAdjustment() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        let original = m.document
        let adjustment = m.beginContinuousChange()
        m.setLineWidth(40)
        let adjusted = m.document, revision = m.session.revision
        let undoCount = m.session.undoCount
        h.drag((220, 40), (224, 40))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == adjusted && m.session.revision == revision)
        #expect(m.session.undoCount == undoCount && m.beginContinuousChange() == adjustment)
        h.drag((220, 40), (400, 40))
        #expect(m.document.annotations.count == 2 && m.session.undoCount == undoCount + 2)
        m.undo()
        #expect(m.document == adjusted)
        m.undo()
        #expect(m.document == original)
    }

    @Test("Refused and cancelled curve drags preserve an open adjustment; an admitted drag starts its own Undo")
    func refusedGesturePreservesAdjustment() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.setArrowCurved(true))
        h.drag((20, 40), (180, 40))
        m.selectTool(.select)
        let original = m.document
        let adjustment = m.beginContinuousChange()
        m.setLineWidth(6)
        let adjusted = m.document, revision = m.session.revision
        let undoCount = m.session.undoCount
        m.pointerDown(at: Point(x: 180, y: 40))
        m.pointerDragged(to: Point(x: 20, y: 40))
        m.pointerUp(at: Point(x: 20, y: 40))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == adjusted && m.session.revision == revision)
        #expect(m.session.undoCount == undoCount && m.session.isGrouping)
        #expect(m.beginContinuousChange() == adjustment)
        m.pointerDown(at: Point(x: 180, y: 40))
        m.cancelGesture()
        #expect(m.document == adjusted && m.beginContinuousChange() == adjustment)
        h.drag((180, 40), (220, 60))
        #expect(m.document != adjusted && m.session.undoCount == undoCount + 2)
        m.undo()
        #expect(m.document == adjusted)
        m.undo()
        #expect(m.document == original)
    }

    @Test("Collinear curves support frame movement and gaining extent on either axis", arguments: [false, true])
    func collinearFrame(_ vertical: Bool) throws {
        let start: Point<DocumentSpace> = vertical ? Point(x: 40, y: 180) : Point(x: 180, y: 40)
        let end: Point<DocumentSpace> = vertical ? Point(x: 40, y: 20) : Point(x: 20, y: 40)
        let control: Point<DocumentSpace> = vertical ? Point(x: 40, y: 100) : Point(x: 100, y: 40)
        let arrow = Annotation(kind: .arrow(start: start, end: end, control: control), style: .default)
        var document = EditorFixtures.session().document
        document.annotations = [arrow]
        let h = EditorHarness(session: DocumentSession(document: document))
        let m = h.model
        let moved: Rect<DocumentSpace> =
            vertical
            ? Rect(x: 60, y: 30, width: 0, height: 240)
            : Rect(x: 30, y: 60, width: 240, height: 0)
        m.setFrame(moved, for: .annotation(arrow.id))
        #expect(m.frame(of: .annotation(arrow.id)) == moved)
        #expect(m.session.undoCount == 1)
        let expanded = Rect<DocumentSpace>(x: 30, y: 60, width: 240, height: 120)
        m.setFrame(expanded, for: .annotation(arrow.id))
        #expect(m.frame(of: .annotation(arrow.id)) == expanded)
        #expect(
            m.document.annotations.last?.kind
                == .arrow(
                    start: Point(x: 270, y: 180), end: Point(x: 30, y: 60), control: Point(x: 150, y: 120)))
        m.undo()
        #expect(m.frame(of: .annotation(arrow.id)) == moved)
        m.undo()
        #expect(m.document == document)
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

}
