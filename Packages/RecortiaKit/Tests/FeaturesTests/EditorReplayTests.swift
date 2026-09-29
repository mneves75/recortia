import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-04, FR-05, EDIT-01): a gesture that records one undo step per pointer move;
// an operation that undo cannot restore exactly (float drift, lost IDs, reordered arrays); redo
// that diverges from the original edit; a click that creates a zero-size object; text editing
// that splits into several undo steps; eviction at the undo budget that breaks the remaining
// history; renumbering that is implicit instead of an explicit command.
@Suite("Editor deterministic replay (EDIT-01)")
@MainActor
struct EditorReplayTests {
    /// Runs one fixed script covering every annotation kind and editing operation; returns the
    /// document after each undoable step, starting with the initial document.
    private func runScript(_ h: EditorHarness) throws -> [Document] {
        let m = h.model
        var snapshots = [m.document]
        func record(_ sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(m.document != snapshots.last, "step made no change", sourceLocation: sourceLocation)
            snapshots.append(m.document)
        }

        m.selectTool(.arrow)
        h.drag((20, 20), (120, 80))
        record()
        m.selectTool(.rectangle)
        h.drag((150, 20), (250, 90))
        record()
        m.selectTool(.ellipse)
        h.drag((20, 120), (100, 180))
        record()
        m.selectTool(.freehand)
        h.drag((120, 120), (200, 170), steps: 12)
        record()
        m.selectTool(.highlighter)
        h.drag((220, 130), (300, 130), steps: 6)
        record()
        m.selectTool(.step)
        h.click(330, 40)
        record()
        h.click(370, 40)
        record()
        m.selectTool(.text)
        h.click(200, 220)
        #expect(m.textEditing != nil)
        m.commitTextEditing("Olá, café ☕️ مرحبا\nsegunda linha")
        record()
        let textID = try #require(m.document.annotations.last?.id)
        m.beginEditingText(textID)
        m.commitTextEditing("Olá, edição")
        record()

        // Move the arrow by its shaft, then resize the rectangle by a corner handle.
        m.selectTool(.select)
        h.drag((70, 50), (90, 60))
        record()
        h.click(150, 50)  // selects the rectangle by its left edge; no change
        #expect(m.selection.count == 1)
        h.drag((250, 90), (270, 110))
        record()
        m.duplicateSelection()
        record()
        m.reorderSelection(.back)
        record()

        // Send the second step to the back, then renumber: numbers now follow z-order.
        let stepIDs = m.document.annotations.compactMap { a -> AnnotationID? in
            if case .step = a.kind { return a.id }
            return nil
        }
        m.select(.annotation(try #require(stepIDs.last)))
        m.reorderSelection(.back)
        record()
        m.renumberSteps()
        record()

        m.selectTool(.redact)
        h.drag((300.4, 200.6), (340.2, 230.1))
        record()
        m.selectTool(.blur)
        h.drag((20, 240), (80, 280))
        record()
        m.setCrop(Rect(x: 10, y: 10, width: 380, height: 280))
        record()
        m.setResizeScale(0.5)
        record()
        return snapshots
    }

    @Test("Undo every step, then redo every step, reproduces each recorded document exactly")
    func undoRedoReplay() async throws {
        let h = EditorHarness()
        let snapshots = try runScript(h)
        let m = h.model
        #expect(m.session.undoCount == snapshots.count - 1)

        let kinds = Set(m.document.annotations.map { EditorItemKind($0.kind) })
        #expect(kinds == [.arrow, .rectangle, .ellipse, .freehand, .highlighter, .step, .text])
        #expect(m.document.masks.count == 1)
        #expect(m.document.obfuscations.count == 1)

        for expected in snapshots.dropLast().reversed() {
            m.undo()
            #expect(m.document == expected)
        }
        #expect(!m.canUndo)
        for expected in snapshots.dropFirst() {
            m.redo()
            #expect(m.document == expected)
        }
        #expect(!m.canRedo)
        #expect(m.document == snapshots.last)
    }

    @Test("Replaying the same script on two editors yields the same geometry")
    func replayIsDeterministic() throws {
        let a = EditorHarness(), b = EditorHarness()
        let first = try runScript(a).map(\.annotationShapes)
        let second = try runScript(b).map(\.annotationShapes)
        #expect(first == second)
    }

    @Test("One drag with many pointer moves is one undo step")
    func gestureIsOneUndoGroup() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.rectangle)
        h.drag((10, 10), (60, 60))
        let afterCreate = m.document
        m.selectTool(.select)
        h.drag((10, 30), (110, 90), steps: 40)
        #expect(m.session.undoCount == 2)
        #expect(m.document != afterCreate)
        m.undo()
        #expect(m.document == afterCreate)
    }

    @Test("A resize drag is one undo step and restores the original frame on undo")
    func resizeIsOneUndoGroup() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.ellipse)
        h.drag((50, 50), (150, 100))
        let id = try #require(m.selection.first)
        let before = m.frame(of: id)
        m.selectTool(.select)
        h.drag((150, 100), (200, 180), steps: 25)
        #expect(m.frame(of: id) == Rect(x: 50, y: 50, width: 150, height: 130))
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.frame(of: id) == before)
    }

    @Test("A click with a shape tool creates nothing")
    func clickCreatesNothing() {
        let h = EditorHarness()
        for tool in [EditorTool.arrow, .rectangle, .ellipse, .redact, .blur, .pixelate, .spotlight, .magnifier, .crop] {
            h.model.selectTool(tool)
            h.click(40, 40)
        }
        #expect(!h.model.canUndo)
        #expect(h.model.document.annotations.isEmpty)
    }

    @Test("Canceling a move restores the document and records nothing")
    func cancelMove() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.rectangle)
        h.drag((10, 10), (60, 60))
        let created = m.document
        m.selectTool(.select)
        m.pointerDown(at: Point(x: 10, y: 30))
        m.pointerDragged(to: Point(x: 90, y: 90))
        m.cancelGesture()
        #expect(m.document == created)
        #expect(m.session.undoCount == 1)
    }

    @Test("Canceling numbered-step placement restores the document without adding history")
    func cancelStepCreation() {
        let h = EditorHarness()
        let original = h.model.document
        h.model.selectTool(.step)
        h.model.pointerDown(at: Point(x: 20, y: 30))
        h.model.pointerDragged(to: Point(x: 80, y: 90))
        h.model.cancelGesture()
        #expect(h.model.document == original)
        #expect(!h.model.canUndo)
        #expect(h.model.selection.isEmpty)
    }

    @Test("Emptying a text deletes it; a blank new text adds nothing")
    func textCommitRules() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.text)
        h.click(20, 20)
        m.commitTextEditing("   \n ")
        #expect(m.document.annotations.isEmpty)
        #expect(!m.canUndo)
        h.click(20, 20)
        m.commitTextEditing("Hello")
        let id = try #require(m.document.annotations.first?.id)
        m.beginEditingText(id)
        m.commitTextEditing("")
        #expect(m.document.annotations.isEmpty)
        #expect(m.session.undoCount == 2)
    }

    @Test("Tool shortcuts and edits are ignored while text is being edited")
    func noToolChangeWhileEditingText() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.text)
        h.click(20, 20)
        m.selectTool(.rectangle)
        m.undo()
        #expect(m.tool == .text)
        #expect(m.textEditing != nil)
    }

    @Test("At the undo budget the oldest steps are evicted and the rest still undo")
    func undoBudgetBoundary() {
        let h = EditorHarness(session: EditorFixtures.session(undoLimit: 3))
        let m = h.model
        m.selectTool(.rectangle)
        h.drag((10, 10), (60, 60))
        var states = [m.document]
        for _ in 0..<4 {
            m.nudgeSelection(dx: 1, dy: 0)
            states.append(m.document)
        }
        #expect(m.session.evictedUndoCount == 2)
        #expect(m.session.undoCount == 3)
        for expected in states.dropLast().suffix(3).reversed() {
            m.undo()
            #expect(m.document == expected)
        }
        #expect(!m.canUndo)
    }

    @Test("Evicting undo history is visible to the user (SPEC FR-04)")
    func undoEvictionIsVisible() {
        let h = EditorHarness(session: EditorFixtures.session(undoLimit: 2))
        let m = h.model
        m.selectTool(.rectangle)
        h.drag((10, 10), (60, 60))
        m.nudgeSelection(dx: 1, dy: 0)
        #expect(m.notice != .undoHistoryTrimmed, "no step evicted yet")
        m.nudgeSelection(dx: 1, dy: 0)
        #expect(m.notice == .undoHistoryTrimmed)

        m.dismissNotice()
        m.selectTool(.rectangle)
        h.drag((100, 10), (140, 60))
        #expect(m.notice == .undoHistoryTrimmed, "a gesture commit that evicts also tells the user")
    }

    @Test("Z-order commands move the selection within its layer")
    func zOrder() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.rectangle)
        for i in 0..<3 { h.drag((10 + Double(i) * 50, 10), (50 + Double(i) * 50, 50)) }
        let ids = m.document.annotations.map(\.id)
        m.select(.annotation(ids[0]))
        m.reorderSelection(.forward)
        #expect(m.document.annotations.map(\.id) == [ids[1], ids[0], ids[2]])
        m.reorderSelection(.front)
        #expect(m.document.annotations.map(\.id) == [ids[1], ids[2], ids[0]])
        m.reorderSelection(.backward)
        #expect(m.document.annotations.map(\.id) == [ids[1], ids[0], ids[2]])
        m.reorderSelection(.back)
        #expect(m.document.annotations.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    @Test("Delete and duplicate cover every object kind in one undo step each")
    func deleteAndDuplicate() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        h.drag((10, 10), (100, 10))
        m.selectTool(.redact)
        h.drag((10, 100), (50, 140))
        m.selectTool(.pixelate)
        h.drag((100, 100), (150, 140))
        m.selectTool(.spotlight)
        h.drag((200, 100), (260, 160))
        m.selectAll()
        let before = m.document
        m.duplicateSelection()
        #expect(m.document.annotations.count == 2)
        #expect(m.document.masks.count == 2)
        #expect(m.document.obfuscations.count == 2)
        #expect(m.document.callouts.count == 2)
        #expect(m.document.layers.count == 2)
        #expect(m.selection.count == 5)
        m.deleteSelection()
        #expect(m.document == before)
        #expect(m.session.undoCount == 6)
    }
}
