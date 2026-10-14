import CoreGraphics
import Domain
import Features
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@Suite("Native text font designs (FR-05)")
@MainActor
struct EditorTextAppearanceTests {
    @Test("Canvas reports layout failure explicitly and restores caller drawing state")
    func canvasFailure() throws {
        var document = EditorFixtures.session().document
        document.annotations = [
            Annotation(
                kind: .text(
                    .init(
                        origin: Point(x: .greatestFiniteMagnitude, y: 10), string: "WWWW",
                        fontSize: 24, maxWidth: .greatestFiniteMagnitude, appearance: .rounded)), style: .default)
        ]
        let context = try #require(ChartFixture.context(width: 400, height: 300))
        let transform = context.ctm
        #expect(throws: RenderError.textLayoutFailed(.unmeasurableText)) {
            try EditorCanvasRenderer.draw(document, base: nil, calloutBase: nil, in: context)
        }
        #expect(context.ctm == transform)
        let h = EditorHarness()
        defer { h.model.close() }
        h.model.reportCanvasRenderFailure()
        let serial = h.model.noticeSerial
        h.model.reportCanvasRenderFailure()
        #expect(h.model.notice == .previewFailed)
        #expect(h.model.noticeSerial == serial)
    }

    @Test("Active text input and closed editors refuse without changing input or history")
    func inputAndClosedRefusal() throws {
        let h = EditorHarness()
        let model = h.model
        model.selectTool(.text)
        h.click(20, 30)
        model.commitTextEditing("Água🙂")
        let id = try #require(model.document.annotations.first).id
        let original = model.document
        let count = model.session.undoCount
        let group = model.beginContinuousChange()
        model.setStrokeColor(.yellow)
        model.beginEditingText(id)
        let input = model.textEditing
        let before = model.document
        let revision = model.session.revision
        let style = model.style
        #expect(!model.canSetTextAppearance)
        #expect(!model.setTextAppearance(.rounded))
        #expect(model.textEditing == input)
        #expect(model.document == before)
        #expect(model.style == style)
        #expect(model.session.revision == revision)
        model.cancelTextEditing()
        model.setStrokeColor(.white)
        model.endContinuousChange(group)
        #expect(model.session.undoCount == count + 1)
        model.undo()
        #expect(model.document == original)
        model.close()
        let closedStyle = model.style
        let closedRevision = model.session.revision
        #expect(!model.canSetTextAppearance)
        #expect(!model.setTextAppearance(.monospaced))
        #expect(model.style == closedStyle)
        #expect(model.session.revision == closedRevision)
    }

    @Test("Unmeasurable text refuses appearance, resize and fit before mutation")
    func unmeasurableRefusal() throws {
        var session = EditorFixtures.session()
        let text = Annotation(
            kind: .text(
                .init(
                    origin: Point(x: .greatestFiniteMagnitude, y: 10), string: "WWWW",
                    fontSize: 24, maxWidth: .greatestFiniteMagnitude)), style: .default)
        try session.perform("Fixture") { $0.annotations = [text] }
        let h = EditorHarness(session: session)
        defer { h.model.close() }
        let model = h.model
        model.select(.annotation(text.id))
        let count = model.session.undoCount
        let original = model.document
        let group = model.beginContinuousChange()
        model.setStrokeColor(.yellow)
        let before = model.document
        let revision = model.session.revision
        let style = model.style
        #expect(model.frame(of: .annotation(text.id)) == nil)
        #expect(!model.setTextAppearance(.rounded))
        #expect(model.document == before)
        #expect(model.style == style)
        #expect(model.session.revision == revision)
        model.setStrokeColor(.white)
        model.endContinuousChange(group)
        #expect(model.session.undoCount == count + 1)
        model.undo()
        #expect(model.document == original)
        let geometryRevision = model.session.revision
        model.setFrame(Rect(x: 20, y: 20, width: 90, height: 40), for: .annotation(text.id))
        model.fitCanvasToContent()
        #expect(model.session.revision == geometryRevision)
        #expect(model.document == original)
    }

    @Test("Creation, reopening, cancel, confirm and duplication preserve font design and wrapping")
    func editingRoundTrip() throws {
        var session = EditorFixtures.session()
        let text = Annotation(
            kind: .text(
                .init(
                    origin: Point(x: 20, y: 30), string: "Original",
                    fontSize: 450, maxWidth: 140, appearance: .rounded)), style: .default)
        try session.perform("Fixture") { $0.annotations = [text] }
        let h = EditorHarness(session: session)
        defer { h.model.close() }
        let model = h.model
        model.select(.annotation(text.id))
        #expect(model.style.textAppearance == .rounded)
        #expect(model.style.fontSize == 450)
        model.beginEditingText(text.id)
        #expect(model.textEditing?.appearance == .rounded)
        #expect(model.textEditing?.maxWidth == 140)
        model.cancelTextEditing()
        #expect(model.document.annotations.first == text)
        model.beginEditingText(text.id)
        model.commitTextEditing("Confirmed🙂")
        model.duplicateSelection()
        let copied = try #require(model.document.annotations.last)
        guard case .text(let content) = copied.kind else { Issue.record("Expected text"); return }
        #expect(content.string == "Confirmed🙂")
        #expect(content.resolvedAppearance == .rounded)
        #expect(content.maxWidth == 140 && content.fontSize == 450)
        model.clearSelection()
        model.setFontSize(24)
        #expect(model.setTextAppearance(.monospaced))
        model.selectTool(.text)
        h.click(2000, 2000)
        #expect(model.textEditing?.appearance == .monospaced)
        model.commitTextEditing("Next")
        guard case .text(let created) = try #require(model.document.annotations.last).kind else {
            Issue.record("Expected text"); return
        }
        #expect(created.resolvedAppearance == .monospaced)
    }

    @Test(
        "Advertised text frames contain exported Unicode ink at fractional and doubled scales",
        arguments: TextAppearance.allCases)
    func exportedInkFitsSelection(appearance: TextAppearance) async throws {
        let store = ImageStore()
        let decoded = try ImageDecoder.canonicalize(
            try ChartFixture.solid(
                width: 300, height: 280, color: ChartFixture.Color(0, 0, 0, 0)))
        let asset = await store.insert(decoded, origin: .imported)
        var document = Document(asset: asset)
        let text = Annotation(
            kind: .text(
                .init(
                    origin: Point(x: 40, y: 30),
                    string: "A\u{301}gua Wi\nمرحبا🙂\n👩🏽‍💻 fi", fontSize: 28, maxWidth: 85, appearance: appearance)),
            style: Annotation.Style(stroke: .black))
        document.annotations = [text]
        let h = EditorHarness(session: DocumentSession(document: document))
        defer { h.model.close() }
        let frame = try #require(h.model.frame(of: .annotation(text.id)))
        let pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        for scale in [0.75, 2.0] {
            let snapshot = try await pipeline.snapshot(
                of: h.model.session, options: ExportOptions(scale: scale),
                date: Date(timeIntervalSince1970: 0))
            let output = try ContainerInspector.decodePixels(snapshot.bytes)
            var painted = 0
            var outside = 0
            for y in 0..<output.height {
                for x in 0..<output.width where output.pixel(x: x, y: y).a > 0 {
                    painted += 1
                    let px = (Double(x) + 0.5) / scale, py = (Double(y) + 0.5) / scale
                    if px < frame.minX || px > frame.maxX || py < frame.minY || py > frame.maxY { outside += 1 }
                }
            }
            #expect(painted > 200)
            #expect(outside == 0)
        }
    }

    @Test("Monospaced selection geometry uses equal i and W advances")
    func geometryMatchesDesign() throws {
        let h = EditorHarness()
        defer { h.model.close() }
        #expect(h.model.setTextAppearance(.monospaced))
        h.model.selectTool(.text)
        h.click(20, 30)
        h.model.commitTextEditing("iiii")
        let first = try #require(h.model.document.annotations.first).id
        h.click(20, 80)
        h.model.commitTextEditing("WWWW")
        let second = try #require(h.model.document.annotations.last).id
        let narrow = try #require(h.model.frame(of: .annotation(first)))
        let wide = try #require(h.model.frame(of: .annotation(second)))
        #expect(abs(narrow.width - wide.width) <= 2)
    }

    @Test("Appearance edits selected text in one independent undo step")
    func applyAndUndo() throws {
        let h = EditorHarness()
        defer { h.model.close() }
        let model = h.model
        model.selectTool(.text)
        h.click(20, 30)
        model.commitTextEditing("Água Wi fi 123")
        let original = model.document
        let id = try #require(original.annotations.first).id
        let group = model.beginContinuousChange()
        model.setStrokeColor(.yellow)
        let colored = model.document
        let count = model.session.undoCount
        #expect(model.setTextAppearance(.rounded))
        #expect(model.style.textAppearance == .rounded)
        let changed = try #require(model.document.annotations.first)
        guard case .text(let content) = changed.kind else { Issue.record("Expected text"); return }
        #expect(content.resolvedAppearance == .rounded)
        #expect(model.session.undoCount == count + 2)
        model.endContinuousChange(group)
        model.undo()
        #expect(model.document == colored)
        #expect(model.style.textAppearance == .standard)
        model.undo()
        #expect(model.document == original)
        model.redo()
        model.redo()
        #expect(model.document.annotations.first == changed)
        #expect(model.style.textAppearance == .rounded)
        model.select(.annotation(id))
        #expect(model.style.textAppearance == .rounded)
    }
}
