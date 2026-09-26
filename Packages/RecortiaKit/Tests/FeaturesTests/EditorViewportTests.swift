import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-04, EDIT-02): geometry stored in view coordinates so zoom moves objects;
// nudges or hit targets that scale with zoom in document space; zoom that drifts the point under
// the cursor; fit/actual-size that ignore the display's backing scale; non-finite zoom input.
@Suite("Editor zoom and viewport (EDIT-02)")
@MainActor
struct EditorViewportTests {
    nonisolated static let zooms: [Double] = [0.25, 1, 2, 8]

    /// The same document-space script, driven through view coordinates at `zoom`.
    private func runScript(zoom: Double) -> Document {
        let h = EditorHarness()
        let m = h.model
        m.setViewport(EditorViewport(zoom: zoom, offset: Point(x: 13, y: -7)))
        func view(_ x: Double, _ y: Double) -> Point<ViewSpace> { m.viewport.viewPoint(Point(x: x, y: y)) }

        m.selectTool(.arrow)
        h.dragInView(view(20, 20), view(180, 120))
        m.selectTool(.rectangle)
        h.dragInView(view(200, 40), view(300, 140))
        m.selectTool(.freehand)
        h.dragInView(view(40, 200), view(160, 260), steps: 8)
        m.selectTool(.step)
        h.dragInView(view(350, 50), view(350, 50), steps: 1)
        m.selectTool(.redact)
        h.dragInView(view(20, 150), view(80, 190))

        // Select the rectangle by its top edge and move it; then nudge 1 and 10 document pixels.
        m.selectTool(.select)
        h.dragInView(view(250, 40), view(270, 60))
        m.nudgeSelection(dx: 1, dy: 0)
        m.nudgeSelection(dx: 0, dy: 10)
        return m.document
    }

    @Test("The same document-space operations give identical geometry at 25/100/200/800 %")
    func zoomInvariance() {
        let results = Self.zooms.map { runScript(zoom: $0) }
        let reference = results[0]
        #expect(reference.annotations.count == 4)
        #expect(reference.masks.count == 1)
        for (zoom, document) in zip(Self.zooms, results).dropFirst() {
            #expect(document.annotationShapes == reference.annotationShapes, "zoom \(zoom)")
            #expect(document.annotations.map(\.style) == reference.annotations.map(\.style), "zoom \(zoom)")
            #expect(document.masks.map(\.outputRect) == reference.masks.map(\.outputRect), "zoom \(zoom)")
        }
        let rectangle = reference.annotations.first { if case .rectangle = $0.kind { true } else { false } }
        #expect(rectangle?.kind == .rectangle(Rect(x: 221, y: 70, width: 100, height: 100)))
    }

    @Test("Viewport conversions round-trip and zoom keeps the anchor point fixed", arguments: zooms)
    func viewportMath(zoom: Double) {
        var viewport = EditorViewport(zoom: 1, offset: Point(x: 40, y: 30))
        let anchor = Point<ViewSpace>(x: 200, y: 150)
        let fixed = viewport.documentPoint(anchor)
        viewport.setZoom(zoom, anchor: anchor)
        #expect(viewport.documentPoint(anchor) == fixed)
        let p = Point<DocumentSpace>(x: 123.5, y: 77.25)
        #expect(viewport.documentPoint(viewport.viewPoint(p)) == p)
        #expect(viewport.documentLength(8) == 8 / zoom)
    }

    @Test("Zoom clamps and ignores non-finite input")
    func zoomClamping() {
        var viewport = EditorViewport(zoom: .nan)
        #expect(viewport.zoom == 1)
        viewport.setZoom(1000, anchor: .zero)
        #expect(viewport.zoom == EditorViewport.zoomRange.upperBound)
        viewport.setZoom(0, anchor: .zero)
        #expect(viewport.zoom == 1)
        viewport.pan(dx: .infinity, dy: 1)
        #expect(viewport.offset.isFinite)
    }

    @Test("Fit, actual pixels, and zoom steps use the display's backing scale")
    func fitAndActualPixels() {
        let h = EditorHarness(session: EditorFixtures.session(width: 2000, height: 1000))
        let m = h.model
        m.setViewportSize(Size(width: 1048, height: 548), backingScale: 2)
        // Fit: (1048 − 48) / 2000 = 0.5 view points per pixel.
        #expect(m.viewport.zoom == 0.5)
        #expect(m.zoomPercent == 100)
        m.zoomToActualPixels()
        #expect(m.viewport.zoom == 0.5)
        m.zoomIn()
        #expect(m.viewport.zoom == 2.0 / 3)
        m.zoomOut()
        m.zoomOut()
        #expect(m.viewport.zoom == 1.0 / 3)
        m.setZoom(8)
        #expect(m.zoomPercent == 1600)
    }

    @Test("Hit targets are a constant size on screen, so tolerance shrinks in document units")
    func hitToleranceFollowsZoom() throws {
        let h = EditorHarness()
        let m = h.model
        m.selectTool(.arrow)
        h.drag((20, 100), (300, 100))
        let arrow = try #require(m.document.annotations.first?.id)
        m.setViewport(EditorViewport(zoom: 1))
        #expect(m.item(at: Point(x: 150, y: 104)) == .annotation(arrow))
        m.setViewport(EditorViewport(zoom: 8))
        #expect(m.item(at: Point(x: 150, y: 104)) == .layer(m.document.layers[0].id))
        #expect(m.item(at: Point(x: 150, y: 102.4)) == .annotation(arrow))
    }

    @Test("Zoom to selection frames the selected objects")
    func zoomToSelection() throws {
        let h = EditorHarness()
        let m = h.model
        m.setViewportSize(Size(width: 500, height: 400), backingScale: 1)
        m.selectTool(.rectangle)
        h.drag((100, 100), (140, 130))
        m.zoomToSelection()
        let frame = try #require(m.selection.first.flatMap(m.frame(of:)))
        let shown = m.viewport.viewRect(frame)
        #expect(abs(shown.midX - 250) < 0.001)
        #expect(abs(shown.midY - 200) < 0.001)
        #expect(shown.width <= 500 - 96 + 0.001)
    }
}
