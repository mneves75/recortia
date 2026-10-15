import CoreGraphics
import Domain
import Features
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@Suite("Text decoration editing (FR-05, EDIT-01)")
@MainActor
struct EditorTextDecorationTests {
    @Test("Switching sole selected plain text to a box loads its retained fill for the background control")
    func switchingAppearanceLoadsActualFill() throws {
        var session = EditorFixtures.session()
        let annotation = Annotation(
            kind: .text(.init(origin: Point(x: 20, y: 20), string: "Stored fill")),
            style: Annotation.Style(stroke: .black, fill: .yellow))
        try session.perform("Fixture") { $0.annotations = [annotation] }
        let h = EditorHarness(session: session)
        defer { h.model.close() }
        let model = h.model
        #expect(model.setTextBackgroundColor(.red))
        model.select(.annotation(annotation.id))
        #expect(model.style.textBackgroundColor == .red)
        #expect(model.setTextAppearance(.boxed))
        #expect(model.style.textBackgroundColor == .yellow)
        #expect(model.document.annotations[0].style.fill == .yellow)
        #expect(model.setTextAppearance(.standard))
        #expect(model.document.annotations[0].style.fill == .yellow)
        #expect(model.setTextAppearance(.roundedBoxed))
        #expect(model.style.textBackgroundColor == .yellow)
        model.clearSelection()
        #expect(model.setTextBackgroundColor(.clear))
        #expect(model.style.textBackgroundColor == .clear)
        #expect(model.document.annotations[0].style.fill == .yellow)
    }

    @Test(
        "Selected text changes appearance independently while retaining stored fill", arguments: TextAppearance.allCases
    )
    func selectedAppearanceAndFill(appearance: TextAppearance) throws {
        var session = EditorFixtures.session()
        let initial: TextAppearance = appearance == .standard ? .boxed : .standard
        let annotation = Annotation(
            kind: .text(.init(origin: Point(x: 20, y: 20), string: "Água🙂", appearance: initial)),
            style: Annotation.Style(stroke: .black, fill: .yellow, lineWidth: 7, opacity: 0.6))
        let shape = Annotation(kind: .ellipse(Rect(x: 150, y: 20, width: 30, height: 30)), style: .default)
        try session.perform("Fixture") { $0.annotations = [annotation, shape] }
        let h = EditorHarness(session: session)
        defer { h.model.close() }
        let model = h.model
        model.setSelection([.annotation(annotation.id), .annotation(shape.id)])
        let original = model.document, count = model.session.undoCount
        #expect(model.setTextAppearance(appearance))
        let changed = model.document
        guard case .text(let text) = changed.annotations[0].kind else { Issue.record("Expected text"); return }
        #expect(text.resolvedAppearance == appearance)
        #expect(changed.annotations[0].style == annotation.style)
        #expect(changed.annotations[1] == shape)
        #expect(model.session.undoCount == count + 1)
        model.undo()
        #expect(model.document == original)
        model.redo()
        #expect(model.document == changed)
    }

    @Test("Continuous backgrounds coalesce, while Reset owns one independent undo step")
    func backgroundContinuousReset() throws {
        var session = EditorFixtures.session()
        let annotation = Annotation(
            kind: .text(.init(origin: Point(x: 20, y: 20), string: "Box", appearance: .roundedBoxed)),
            style: Annotation.Style(stroke: .black, fill: .red))
        try session.perform("Fixture") { $0.annotations = [annotation] }
        let h = EditorHarness(session: session)
        defer { h.model.close() }
        let model = h.model
        model.select(.annotation(annotation.id))
        #expect(model.style.textBackgroundColor == .red)
        let original = model.document, count = model.session.undoCount
        let group = model.beginContinuousChange()
        #expect(model.setTextBackgroundColor(.yellow))
        #expect(model.setTextBackgroundColor(.clear))
        let transparent = model.document
        #expect(model.setTextBackgroundColor(nil))
        model.endContinuousChange(group)
        #expect(model.session.undoCount == count + 2)
        model.undo()
        #expect(model.document == transparent)
        #expect(model.style.textBackgroundColor == .clear)
        model.undo()
        #expect(model.document == original)
        #expect(model.style.textBackgroundColor == .red)
    }

    @Test("Input and closed background refusals retain style, document and the open adjustment")
    func backgroundInputAndClosedRefusal() throws {
        var session = EditorFixtures.session()
        let annotation = Annotation(
            kind: .text(.init(origin: Point(x: 20, y: 20), string: "Box", appearance: .boxed)), style: .default)
        try session.perform("Fixture") { $0.annotations = [annotation] }
        let h = EditorHarness(session: session)
        let model = h.model
        model.select(.annotation(annotation.id))
        let original = model.document, count = model.session.undoCount
        let group = model.beginContinuousChange()
        model.setStrokeColor(.yellow)
        model.beginEditingText(annotation.id)
        let before = model.document, style = model.style, editing = model.textEditing, revision = model.session.revision
        #expect(!model.setTextBackgroundColor(.clear))
        #expect(!model.setTextBackgroundColor(nil))
        #expect(model.document == before && model.style == style && model.textEditing == editing)
        #expect(model.session.revision == revision)
        model.cancelTextEditing()
        model.setStrokeColor(.white)
        model.endContinuousChange(group)
        #expect(model.session.undoCount == count + 1)
        model.undo()
        #expect(model.document == original)
        model.close()
        let closedStyle = model.style, closedRevision = model.session.revision
        #expect(!model.setTextBackgroundColor(.clear))
        #expect(!model.setTextBackgroundColor(nil))
        #expect(model.style == closedStyle && model.session.revision == closedRevision)
    }

    @Test("Layout-failed background admission preserves style, history and the prior adjustment")
    func backgroundLayoutRefusal() throws {
        var session = EditorFixtures.session()
        let annotation = Annotation(
            kind: .text(
                .init(
                    origin: Point(x: .greatestFiniteMagnitude, y: 20), string: "Box", fontSize: 24,
                    maxWidth: .greatestFiniteMagnitude, appearance: .boxed)), style: .default)
        try session.perform("Fixture") { $0.annotations = [annotation] }
        let h = EditorHarness(session: session)
        defer { h.model.close() }
        let model = h.model
        model.select(.annotation(annotation.id))
        let original = model.document, count = model.session.undoCount
        let group = model.beginContinuousChange()
        model.setStrokeColor(.yellow)
        let before = model.document, style = model.style, revision = model.session.revision
        #expect(!model.setTextBackgroundColor(.clear))
        #expect(!model.setTextBackgroundColor(nil))
        #expect(model.notice == .previewFailed)
        #expect(model.document == before && model.style == style)
        #expect(model.session.revision == revision)
        model.setStrokeColor(.white)
        model.endContinuousChange(group)
        #expect(model.session.undoCount == count + 1)
        model.undo()
        #expect(model.document == original)
    }

    @Test(
        "Native editing snapshots full style for creation, reopen, confirm, cancel and duplication",
        arguments: TextAppearance.allCases)
    func immutableEditingStyle(appearance: TextAppearance) throws {
        let h = EditorHarness()
        defer { h.model.close() }
        let model = h.model
        #expect(model.setTextAppearance(appearance))
        model.setStrokeColor(.yellow)
        model.setFillColor(.red)
        model.setLineWidth(12)
        model.setOpacity(0.4)
        #expect(model.setTextBackgroundColor(.clear))
        let expected = Annotation.Style(
            stroke: .yellow, fill: appearance.isBoxed ? .clear : .red, lineWidth: 12, opacity: 0.4)
        model.selectTool(.text)
        h.click(20, 30)
        #expect(model.textEditing?.annotationStyle == expected)
        #expect(model.textEditing?.color == .yellow)
        #expect(model.textEditing?.appearance == appearance)
        model.setOpacity(0.8)
        model.setLineWidth(3)
        model.commitTextEditing("A\u{301}gua🙂 العربية")
        let original = try #require(model.document.annotations.first)
        #expect(original.style == expected)
        model.beginEditingText(original.id)
        #expect(model.textEditing?.annotationStyle == expected)
        model.cancelTextEditing()
        #expect(model.document.annotations.first == original)
        model.beginEditingText(original.id)
        model.commitTextEditing("Confirmed🙂")
        model.duplicateSelection()
        let copied = try #require(model.document.annotations.last)
        #expect(copied.style == expected)
        guard case .text(let text) = copied.kind else { Issue.record("Expected text"); return }
        #expect(text.resolvedAppearance == appearance)
        #expect(text.string == "Confirmed🙂")
        model.undo()
        model.undo()
        #expect(model.document.annotations == [original])
        model.redo()
        model.redo()
        #expect(model.document.annotations.last == copied)
    }

    @Test("Background commands affect only selected boxed text and a separate future-text default")
    func backgroundSelectionAndUndo() throws {
        var session = EditorFixtures.session()
        let boxed = Annotation(
            kind: .text(.init(origin: Point(x: 20, y: 20), string: "Box", appearance: .boxed)), style: .default)
        let plain = Annotation(
            kind: .text(.init(origin: Point(x: 120, y: 20), string: "Plain")), style: .default)
        let shape = Annotation(kind: .rectangle(Rect(x: 20, y: 80, width: 40, height: 40)), style: .default)
        try session.perform("Fixture") { $0.annotations = [boxed, plain, shape] }
        let h = EditorHarness(session: session)
        defer { h.model.close() }
        let model = h.model
        model.setFillColor(.yellow)
        model.setSelection([.annotation(boxed.id), .annotation(plain.id), .annotation(shape.id)])
        let before = model.document, count = model.session.undoCount
        #expect(model.setTextBackgroundColor(.clear))
        #expect(model.document.annotations[0].style.fill == .clear)
        #expect(model.document.annotations[1] == plain)
        #expect(model.document.annotations[2] == shape)
        #expect(model.style.fill == .yellow)
        #expect(model.style.textBackgroundColor == .clear)
        #expect(model.session.undoCount == count + 1)
        let transparent = model.document
        #expect(model.setTextBackgroundColor(nil))
        #expect(model.document.annotations[0].style.fill == nil)
        #expect(model.style.textBackgroundColor == nil)
        #expect(model.session.undoCount == count + 2)
        model.undo()
        #expect(model.document == transparent)
        model.undo()
        #expect(model.document == before)
        model.redo()
        model.redo()
        #expect(model.document.annotations[0].style.fill == nil)
    }

    @Test(
        "Outlined selection contains sharp, fallback and emoji ink with zero and wide strokes",
        arguments: [0.0, 24, 80])
    func outlineInkBounds(lineWidth: Double) async throws {
        let store = ImageStore()
        let base = try ImageDecoder.canonicalize(
            try ChartFixture.solid(width: 500, height: 400, color: ChartFixture.Color(0, 0, 0, 0)))
        let asset = await store.insert(base, origin: .imported)
        var document = Document(asset: asset)
        let annotation = Annotation(
            kind: .text(
                .init(
                    origin: Point(x: 110, y: 90), string: "MWÁ fi\nالعربية🙂", fontSize: 48,
                    maxWidth: 220, appearance: .outlined)),
            style: Annotation.Style(stroke: .red, lineWidth: lineWidth))
        document.annotations = [annotation]
        let h = EditorHarness(session: DocumentSession(document: document))
        defer { h.model.close() }
        let frame = try #require(h.model.frame(of: .annotation(annotation.id)))
        let pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        for scale in [0.75, 2.0] {
            let snapshot = try await pipeline.snapshot(
                of: h.model.session, options: ExportOptions(scale: scale), date: Date(timeIntervalSince1970: 0))
            let output = try ContainerInspector.decodePixels(snapshot.bytes)
            var painted = 0, outside = 0, colorEmoji = 0
            for y in 0..<output.height {
                for x in 0..<output.width {
                    let pixel = output.pixel(x: x, y: y)
                    guard pixel.a > 0 else { continue }
                    painted += 1
                    let px = (Double(x) + 0.5) / scale, py = (Double(y) + 0.5) / scale
                    if px < frame.minX || px > frame.maxX || py < frame.minY || py > frame.maxY { outside += 1 }
                    if pixel.r > 100 && pixel.g > 80 && pixel.b < 70 { colorEmoji += 1 }
                }
            }
            #expect(painted > 400)
            #expect(outside == 0)
            #expect(colorEmoji > 10)
        }
    }
}
