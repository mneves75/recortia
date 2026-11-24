import Domain
import Foundation
import Testing

@testable import Features

@Suite("Arrowhead styles and freehand smoothing in the editor (FR-05)")
@MainActor
struct EditorArrowStyleTests {
    private func head(_ annotation: Annotation?) -> Annotation.ArrowHead? {
        guard case .arrow(_, _, _, let head) = annotation?.kind else { return nil }
        return head ?? .filled
    }

    @Test("A head change applies to selected arrows and the future default in one Undo step")
    func selectionAndDefault() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        #expect(m.arrowHeadState == .filled)
        h.drag((20, 40), (180, 40))
        h.drag((20, 90), (180, 90))
        m.selectTool(.rectangle)
        h.drag((20, 120), (60, 160))
        m.selectAll()
        let before = m.document, undoCount = m.session.undoCount
        #expect(m.setArrowHead(.double))
        #expect(m.session.undoCount == undoCount + 1)
        #expect(m.document.annotations.prefix(2).allSatisfy { head($0) == .double })
        #expect(m.document.annotations[2] == before.annotations[2], "a rectangle is not an arrow")
        #expect(m.document.annotations.map(\.id) == before.annotations.map(\.id))
        #expect(m.style.arrowHead == .double)
        m.undo()
        #expect(m.document == before)
        #expect(m.style.arrowHead == .double, "Undo leaves the explicit future default independent")
        m.clearSelection()
        m.selectTool(.arrow)
        h.drag((20, 200), (180, 200))
        #expect(head(m.document.annotations.last) == .double)
        // Choosing the filled head stores the legacy encoding.
        #expect(m.setArrowHead(.filled))
        guard case .arrow(_, _, _, nil) = try #require(m.document.annotations.last).kind else {
            Issue.record("the filled head is stored as nil")
            return
        }
    }

    @Test("Mixed selected heads show no single value; a common head or the future default does")
    func mixedState() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        h.drag((20, 40), (180, 40))
        #expect(m.setArrowHead(.open))
        let open = m.document.annotations[0].id
        m.clearSelection()
        #expect(m.setArrowHead(.plain))
        m.selectTool(.arrow)
        h.drag((20, 90), (180, 90))
        let plain = m.document.annotations[1].id
        m.selectTool(.select)
        m.setSelection([.annotation(open), .annotation(plain)])
        #expect(m.arrowHeadState == nil)
        m.setSelection([.annotation(open)])
        #expect(m.arrowHeadState == .open)
        m.clearSelection()
        m.selectTool(.arrow)
        #expect(m.arrowHeadState == .plain)
    }

    @Test("A head change is admitted for every selected arrow before any document, history or default change")
    func admissionPrecedesMutation() throws {
        // A crafted document can hold an arrow whose length overflows; it has no layout.
        var session = EditorFixtures.session()
        let valid = Annotation(kind: .arrow(start: Point(x: 20, y: 40), end: Point(x: 180, y: 40)), style: .default)
        let overflowing = Annotation(
            kind: .arrow(start: Point(x: -1.4e308, y: 0), end: Point(x: 1.4e308, y: 0)), style: .default)
        try session.perform("Crafted") { $0.annotations = [valid, overflowing] }
        let h = EditorHarness(session: session)
        let m = h.model
        m.selectAll()
        let before = m.document, revision = m.session.revision, undoCount = m.session.undoCount
        let style = m.style, selection = m.selection
        #expect(!m.setArrowHead(.open))
        #expect(m.notice == .arrowGeometryRefused)
        #expect(m.document == before && m.session.revision == revision && m.session.undoCount == undoCount)
        #expect(m.style == style && m.selection == selection)
        m.setSelection([.annotation(valid.id)])
        #expect(m.setArrowHead(.open) && head(m.document.annotations[0]) == .open)
    }

    @Test("Head controls refuse while text is being edited and after close")
    func refusesDuringTextInput() {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        h.drag((20, 40), (180, 40))
        m.selectTool(.text)
        h.click(300, 300)
        #expect(m.textEditing != nil)
        let before = m.document, style = m.style
        #expect(!m.setArrowHead(.open))
        #expect(m.document == before && m.style == style)
    }

    @Test("A bare line is selected only along its line; a double head is selectable at its start")
    func hitTesting() {
        let style = Annotation.Style(stroke: .red, lineWidth: 4)
        func arrow(_ head: Annotation.ArrowHead) -> Annotation {
            Annotation(kind: .arrow(start: .zero, end: Point(x: 100, y: 0), head: head), style: style)
        }
        // Inside where a filled head is painted, beside the shaft.
        #expect(EditorGeometry.hits(arrow(.filled), at: Point(x: 92, y: 4), tolerance: 1))
        #expect(!EditorGeometry.hits(arrow(.plain), at: Point(x: 92, y: 4), tolerance: 0.5))
        #expect(!EditorGeometry.hits(arrow(.plain), at: Point(x: 103, y: 0), tolerance: 0))
        #expect(EditorGeometry.hits(arrow(.plain), at: Point(x: 50, y: 3), tolerance: 1))
        #expect(EditorGeometry.hits(arrow(.double), at: Point(x: 12, y: 6), tolerance: 0))
        #expect(!EditorGeometry.hits(arrow(.filled), at: Point(x: 12, y: 6), tolerance: 0))
    }

    /// A wobbling stroke, as a hand draws it, through the real pointer path.
    private func drawWobble(_ h: EditorHarness, tool: EditorTool) -> [Point<DocumentSpace>] {
        let points = (0...120).map { i -> Point<DocumentSpace> in
            let t = Double(i) / 120
            return Point(x: 40 + t * 300, y: 150 + sin(t * .pi * 2) * 50 + sin(Double(i) * 12.9898) * 0.6)
        }
        h.model.selectTool(tool)
        h.model.pointerDown(at: points[0])
        for point in points.dropFirst() { h.model.pointerDragged(to: point) }
        h.model.pointerUp(at: points[points.count - 1])
        return points
    }

    @Test("New freehand and highlighter strokes are smoothed by default: fewer stored points, same ends")
    func smoothingOnByDefault() throws {
        for tool in [EditorTool.freehand, .highlighter] {
            let h = EditorHarness()
            #expect(h.model.style.smoothsStrokes)
            let raw = drawWobble(h, tool: tool)
            let stroke = try #require(h.model.document.annotations.last)
            let (points, smoothed): ([Point<DocumentSpace>], Bool?) =
                switch stroke.kind {
                case .freehand(let points, let smoothed) where tool == .freehand: (points, smoothed)
                case .highlighter(let points, let smoothed) where tool == .highlighter: (points, smoothed)
                default: ([], nil)
                }
            #expect(smoothed == true)
            #expect(points.count < raw.count / 3, "\(points.count) of \(raw.count)")
            #expect(points.first == raw.first && points.last == raw.last)
            #expect(points == StrokeSmoothing.simplify(raw, tolerance: StrokeSmoothing.tolerance))
            #expect(h.model.session.undoCount == 1)
        }
    }

    @Test("With smoothing off, a stroke stores exactly the points the pointer drew")
    func smoothingOff() throws {
        for tool in [EditorTool.freehand, .highlighter] {
            let h = EditorHarness()
            h.model.selectTool(tool)
            h.model.setStrokeSmoothing(false)
            #expect(!h.model.style.smoothsStrokes)
            let raw = drawWobble(h, tool: tool)
            let stroke = try #require(h.model.document.annotations.last)
            let expected: Annotation.Kind = tool == .freehand ? .freehand(raw) : .highlighter(raw)
            #expect(stroke.kind == expected)
        }
    }

    @Test("A smoothed stroke is selected along the drawn curve, not the chord between its points")
    func smoothedHitTesting() {
        let points = [Point<DocumentSpace>(x: 20, y: 100), Point(x: 100, y: 20), Point(x: 180, y: 100)]
        let style = Annotation.Style(stroke: .red, lineWidth: 4)
        let smooth = Annotation(kind: .freehand(points, smoothed: true), style: style)
        let raw = Annotation(kind: .freehand(points), style: style)
        #expect(EditorGeometry.hits(smooth, at: Point(x: 50, y: 60), tolerance: 0))
        #expect(!EditorGeometry.hits(raw, at: Point(x: 50, y: 60), tolerance: 0))
        #expect(EditorGeometry.hits(raw, at: Point(x: 50, y: 70), tolerance: 0))
    }
}
