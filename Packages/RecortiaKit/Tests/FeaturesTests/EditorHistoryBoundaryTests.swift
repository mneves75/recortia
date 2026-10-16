import Domain
import Foundation
import Testing

@testable import Features

@Suite("Independent edits settle gesture and adjustment history")
@MainActor
struct EditorHistoryBoundaryTests {
    @Test("An import completing during move or resize preserves progress and separate undo", arguments: [false, true])
    func importDuringGesture(resize: Bool) async throws {
        let h = EditorHarness()
        defer { h.model.close() }
        let m = h.model
        let original = m.document
        let layer = try #require(original.layers.first)
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/history.png")
        let read = Pending<Void>()
        h.input.files[url] = .success(Data([1]))
        h.input.pendingRead = read
        let task = Task { await m.addImageLayer(from: .file(url)) }
        await waitFor("import suspended") { read.waiterCount == 1 }
        m.select(.layer(layer.id))
        m.pointerDown(at: resize ? Point(x: 400, y: 300) : Point(x: 200, y: 150))
        m.pointerDragged(to: resize ? Point(x: 600, y: 450) : Point(x: 220, y: 180))
        let progressed = m.document
        #expect(progressed != original)
        read.resolve(())
        #expect(await task.value)
        #expect(m.document.layers.count == 2)
        #expect(h.assets.released.isEmpty)
        let imported = m.document
        m.pointerDragged(to: Point(x: 700, y: 500))
        m.pointerUp(at: Point(x: 750, y: 550))
        #expect(m.document == imported)
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.document == progressed)
        m.undo()
        #expect(m.document == original)
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.files.saves.isEmpty)
    }

    @Test(
        "Committed text isolates history; canceled text preserves the color adjustment",
        arguments: ["replace", "delete", "cancel"])
    func textAfterAdjustment(action: String) throws {
        var document = EditorFixtures.session().document
        let text = Annotation(
            kind: .text(Annotation.TextContent(origin: Point(x: 20, y: 20), string: "Before", fontSize: 20)),
            style: .default)
        document.annotations.append(text)
        let h = EditorHarness(session: DocumentSession(document: document))
        defer { h.model.close() }
        let m = h.model
        m.select(.annotation(text.id))
        m.beginContinuousChange()
        m.setStrokeColor(.yellow)
        let adjusted = m.document
        m.beginEditingText(text.id)
        if action == "cancel" {
            m.cancelTextEditing()
            #expect(m.document == adjusted)
            #expect(m.session.isGrouping)
            #expect(m.session.undoCount == 0)
            m.setStrokeColor(.white)
            m.endContinuousChange()
            #expect(m.session.undoCount == 1)
            m.undo()
            #expect(m.document == document)
            return
        }
        m.commitTextEditing(action == "delete" ? "" : "After")
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.document == adjusted)
        m.undo()
        #expect(m.document == document)
    }

    @Test("A suspended import closes an adjustment before adding its own undo step")
    func importAfterAdjustment() async throws {
        var document = EditorFixtures.session().document
        let annotation = Annotation(kind: .rectangle(Rect(x: 20, y: 20, width: 50, height: 40)), style: .default)
        document.annotations.append(annotation)
        let h = EditorHarness(session: DocumentSession(document: document))
        defer { h.model.close() }
        let m = h.model
        m.select(.annotation(annotation.id))
        m.beginContinuousChange()
        m.setStrokeColor(.yellow)
        let adjusted = m.document
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/adjustment-import.png")
        let read = Pending<Void>()
        h.input.files[url] = .success(Data([1]))
        h.input.pendingRead = read
        let task = Task { await m.addImageLayer(from: .file(url)) }
        await waitFor("import suspended") { read.waiterCount == 1 }
        read.resolve(())
        #expect(await task.value)
        #expect(m.document.layers.count == 2)
        #expect(h.assets.released.isEmpty)
        m.endContinuousChange()
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.document == adjusted)
        m.undo()
        #expect(m.document == document)
        #expect(h.clipboard.writes.isEmpty && h.files.saves.isEmpty)
    }

    @Test(
        "New text commits own history while cancel and blank retain the adjustment",
        arguments: ["commit", "blank"])
    func newTextAfterAdjustment(action: String) throws {
        var document = EditorFixtures.session().document
        let annotation = Annotation(kind: .rectangle(Rect(x: 20, y: 20, width: 50, height: 40)), style: .default)
        document.annotations.append(annotation)
        let h = EditorHarness(session: DocumentSession(document: document))
        defer { h.model.close() }
        let m = h.model
        m.selectTool(.text)
        h.click(200, 150)
        #expect(try #require(m.textEditing).annotationID == nil)
        m.select(.annotation(annotation.id))
        m.beginContinuousChange()
        m.setStrokeColor(.yellow)
        let adjusted = m.document
        if action == "cancel" {
            m.cancelTextEditing()
        } else {
            m.commitTextEditing(action == "blank" ? " " : "New text")
        }
        if action != "commit" {
            #expect(m.session.isGrouping)
            #expect(m.document == adjusted)
            m.select(.annotation(annotation.id))
            m.setStrokeColor(.white)
        }
        m.endContinuousChange()
        #expect(m.session.undoCount == (action == "commit" ? 2 : 1))
        m.undo()
        #expect(m.document == (action == "commit" ? adjusted : document))
        if action == "commit" {
            m.undo()
            #expect(m.document == document)
        }
        #expect(h.clipboard.writes.isEmpty && h.files.saves.isEmpty)
    }

    @Test("No-op and refused edits leave transform gestures live", arguments: zip([false, true], [true, false]))
    func unsuccessfulEditDuringGesture(resize: Bool, refused: Bool) throws {
        let h = EditorHarness()
        defer { h.model.close() }
        let m = h.model
        let original = m.document
        m.select(.layer(try #require(original.layers.first?.id)))
        m.pointerDown(at: resize ? Point(x: 400, y: 300) : Point(x: 200, y: 150))
        m.pointerDragged(to: resize ? Point(x: 600, y: 450) : Point(x: 220, y: 180))
        let progressed = m.document
        let revision = m.session.revision
        if refused {
            #expect(
                !m.edit("Refused") { document in
                    document.layers[0].opacity = 0.5
                    throw DocumentError.invalidGeometry
                })
        } else {
            m.reorderSelection(.front)
        }
        #expect(m.document == progressed)
        #expect(m.session.revision == revision)
        #expect(m.session.undoCount == 0)
        #expect(m.session.isGrouping)
        m.pointerDragged(to: Point(x: 700, y: 500))
        #expect(m.document != progressed)
        #expect(m.document.layers.first?.opacity == original.layers.first?.opacity)
        m.pointerUp(at: Point(x: 700, y: 500))
        #expect(m.session.undoCount == 1)
        m.undo()
        #expect(m.document == original)
        #expect(h.clipboard.writes.isEmpty && h.files.saves.isEmpty)
    }
}
