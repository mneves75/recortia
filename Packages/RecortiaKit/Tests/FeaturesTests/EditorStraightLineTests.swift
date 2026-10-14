import Domain
import Features
import Foundation
import Testing

@Suite("Straight-line editor behavior (FR-05, EDIT-01, EDIT-02)")
@MainActor
struct EditorStraightLineTests {
    @Test("D creates a distinct styled line with one undo step for the entire drag")
    func creationAndUndo() throws {
        let h = EditorHarness()
        let m = h.model
        let original = m.document
        let tool = try #require(EditorTool.forShortcut("d"))
        #expect(tool == EditorTool.line)
        #expect(EditorTool.forShortcut("D") == EditorTool.line)
        #expect(tool.createsObject && tool.usesStyle)
        m.selectTool(tool)
        m.setStrokeColor(.yellow)
        m.setLineWidth(8)
        m.setOpacity(0.5)
        h.drag((30, 40), (170, 90), steps: 40)
        let line = try #require(m.document.annotations.first)
        #expect(line.kind == .line(start: Point(x: 30, y: 40), end: Point(x: 170, y: 90)))
        #expect(line.style == Annotation.Style(stroke: .yellow, lineWidth: 8, opacity: 0.5))
        #expect(m.kind(of: .annotation(line.id)) == .line)
        #expect(m.selection == [.annotation(line.id)])
        #expect(m.session.undoCount == 1)
        let created = m.document
        m.undo()
        #expect(m.document == original)
        m.redo()
        #expect(m.document == created)
    }

    @Test("A line exposes only endpoint handles, resizes either endpoint, and cancels without history")
    func endpointEditing() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.line)
        h.drag((20, 40), (160, 100))
        #expect(m.selectionHandles.map(\.handle) == [.start, .end])
        #expect(m.selectionHandles.map(\.point) == [Point(x: 20, y: 40), Point(x: 160, y: 100)])
        let created = m.document
        m.selectTool(.select)
        h.drag((160, 100), (200, 20), steps: 20)
        #expect(m.document.annotations.first?.kind == .line(start: Point(x: 20, y: 40), end: Point(x: 200, y: 20)))
        #expect(m.session.undoCount == 2)
        let resized = m.document
        m.undo()
        #expect(m.document == created)
        m.redo()
        #expect(m.document == resized)
        h.drag((20, 40), (60, 80))
        #expect(m.document.annotations.first?.kind == .line(start: Point(x: 60, y: 80), end: Point(x: 200, y: 20)))
        let beforeCancel = m.document
        m.pointerDown(at: Point(x: 60, y: 80))
        m.pointerDragged(to: Point(x: 30, y: 90))
        m.cancelGesture()
        #expect(m.document == beforeCancel)
        #expect(m.session.undoCount == 3)
    }

    @Test("Horizontal and vertical line frames resize while retaining reversed endpoint order")
    func axisAlignedFrames() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.line)
        h.drag((90, 20), (10, 20))
        let horizontal = try #require(m.selection.first)
        m.setFrame(Rect(x: 30, y: 50, width: 160, height: 0), for: horizontal)
        #expect(m.document.annotations.first?.kind == .line(start: Point(x: 190, y: 50), end: Point(x: 30, y: 50)))
        h.drag((20, 90), (20, 10))
        let vertical = try #require(m.selection.first)
        m.setFrame(Rect(x: 50, y: 30, width: 0, height: 160), for: vertical)
        #expect(m.document.annotations.last?.kind == .line(start: Point(x: 50, y: 190), end: Point(x: 50, y: 30)))
        #expect(m.session.undoCount == 4)
        let beforeInvalid = m.document
        for invalid in [
            Rect<DocumentSpace>(x: 10, y: 10, width: 0, height: 0),
            Rect(x: 10, y: 10, width: -1, height: 10),
            Rect(x: .nan, y: 10, width: 10, height: 10),
        ] {
            m.setFrame(invalid, for: vertical)
        }
        #expect(m.document == beforeInvalid)
        #expect(m.session.undoCount == 4)
    }

    @Test("Line selection follows the segment and round cap without an arrowhead hit region")
    func segmentHitTesting() throws {
        let lineEditor = EditorHarness()
        lineEditor.model.selectTool(.line)
        lineEditor.drag((20, 100), (100, 100))
        let line = EditorItemID.annotation(try #require(lineEditor.model.document.annotations.first?.id))
        #expect(lineEditor.model.item(at: Point(x: 50, y: 100)) == line)
        #expect(lineEditor.model.item(at: Point(x: 105, y: 100)) == line)
        #expect(lineEditor.model.item(at: Point(x: 108, y: 100)) != line)
        #expect(lineEditor.model.item(at: Point(x: 96, y: 111)) != line)

        let arrowEditor = EditorHarness()
        arrowEditor.model.selectTool(.arrow)
        arrowEditor.drag((20, 100), (100, 100))
        let arrow = EditorItemID.annotation(try #require(arrowEditor.model.document.annotations.first?.id))
        #expect(arrowEditor.model.item(at: Point(x: 96, y: 111)) == arrow)
    }

    @Test("Shift snaps creation to 45 degrees at every editor zoom", arguments: [0.25, 1.0, 2.0, 8.0])
    func constrainedCreationAtZoom(zoom: Double) throws {
        let h = EditorHarness()
        let m = h.model
        m.setViewport(EditorViewport(zoom: zoom, offset: Point(x: 17, y: 23)))
        let viewport = m.viewport
        m.selectTool(.line)
        let start = viewport.documentPoint(Point<ViewSpace>(x: 20 * zoom + 17, y: 30 * zoom + 23))
        let end = viewport.documentPoint(Point<ViewSpace>(x: 80 * zoom + 17, y: 110 * zoom + 23))
        m.pointerDown(at: start, modifiers: .shift)
        m.pointerDragged(to: end, modifiers: .shift)
        guard case .annotation(let draft) = m.draft, case .line(let draftStart, let draftEnd) = draft.kind else {
            Issue.record("Line creation must show a line draft")
            return
        }
        #expect(draftStart == Point(x: 20, y: 30))
        #expect(abs(draftEnd.x - 90.71067811865476) < 1e-9)
        #expect(abs(draftEnd.y - 100.71067811865476) < 1e-9)
        m.pointerUp(at: end, modifiers: .shift)
        #expect(m.document.annotations.first?.kind == draft.kind)
        #expect(m.session.undoCount == 1)
    }

    @Test("Clicks, canceled drafts and invalid pointers create no line or undo history")
    func failedCreation() {
        let h = EditorHarness()
        let m = h.model
        let original = m.document
        m.selectTool(.line)
        h.click(40, 40)
        m.pointerDown(at: Point(x: .nan, y: 40))
        m.pointerUp(at: Point(x: 50, y: 50))
        m.pointerDown(at: Point(x: 20, y: 20))
        m.pointerDragged(to: Point(x: 160, y: 60))
        m.cancelGesture()
        m.pointerUp(at: Point(x: 160, y: 60))
        #expect(m.draft == nil)
        #expect(m.document == original)
        #expect(!m.canUndo)
        m.selectTool(.text)
        h.click(20, 20)
        m.selectTool(.line)
        #expect(m.tool == .text && m.textEditing != nil)
    }

    @Test("Moving, nudging, duplicating and deleting a reversed line replay exactly")
    func editingCommands() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.line)
        h.drag((90, 20), (10, 20))
        var snapshots = [m.document]
        m.selectTool(.select)
        h.drag((60, 20), (80, 40))
        #expect(m.document.annotations.first?.kind == .line(start: Point(x: 110, y: 40), end: Point(x: 30, y: 40)))
        snapshots.append(m.document)
        m.nudgeSelection(dx: 1, dy: -1)
        #expect(m.document.annotations.first?.kind == .line(start: Point(x: 111, y: 39), end: Point(x: 31, y: 39)))
        snapshots.append(m.document)
        m.duplicateSelection()
        #expect(m.document.annotations.count == 2)
        #expect(m.document.annotations.last?.kind == .line(start: Point(x: 121, y: 49), end: Point(x: 41, y: 49)))
        #expect(m.document.annotations.first?.id != m.document.annotations.last?.id)
        snapshots.append(m.document)
        m.deleteSelection()
        #expect(m.document == snapshots[2])
        snapshots.append(m.document)
        #expect(m.session.undoCount == 5)
        for snapshot in snapshots.dropLast().reversed() {
            m.undo()
            #expect(m.document == snapshot)
        }
        for snapshot in snapshots.dropFirst() {
            m.redo()
            #expect(m.document == snapshot)
        }
    }
}
