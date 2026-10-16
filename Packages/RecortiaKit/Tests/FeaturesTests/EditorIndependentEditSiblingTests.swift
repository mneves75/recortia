import Domain
import Foundation
import Testing

@testable import Features

/// Sibling paths of the full-source review's history and lifecycle invariants (B-1, B-5/Spec 1,
/// A-2, B-3): an independently committed edit owns its undo step and survives the gesture it
/// interrupted; closing an editor ends only its own export work.
@MainActor
private final class SiblingUpload: GitHubUploadService {
    let gate = Pending<Void>()
    let url = URL(fileURLWithPath: "/tmp/recortia-tests/sibling-upload.png")
    private(set) var requests: [DocumentID] = []
    private(set) var writes: [DocumentID] = []
    private(set) var observedCancellation = false

    func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, intent: UUID,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        requests.append(snapshot.documentID)
        await gate.wait()
        observedCancellation = Task.isCancelled
        if observedCancellation { throw .canceled }
        guard isCurrent() else { throw .staleDocument }
        writes.append(snapshot.documentID)
        return url
    }
}

@Suite("Independent edits and editor close: sibling paths (B-1, B-5, A-2, B-3)")
@MainActor
struct EditorIndependentEditSiblingTests {
    private static func suspendedImport(_ h: EditorHarness, _ name: String) -> (Pending<Void>, URL) {
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/\(name).png")
        let read = Pending<Void>()
        h.input.files[url] = .success(Data([1]))
        h.input.pendingRead = read
        return (read, url)
    }

    // MARK: B-1 siblings

    @Test("An import completing while a placed step is dragged keeps both, as separate undo steps")
    func importDuringStepPlacement() async throws {
        let h = EditorHarness()
        defer { h.model.close() }
        let m = h.model
        let original = m.document
        let (read, url) = Self.suspendedImport(h, "step-import")
        let task = Task { await m.addImageLayer(from: .file(url)) }
        await waitFor("import suspended") { read.waiterCount == 1 }
        m.selectTool(.step)
        m.pointerDown(at: Point(x: 100, y: 100))
        m.pointerDragged(to: Point(x: 140, y: 120))
        let placed = m.document
        #expect(placed.annotations.count == 1)
        read.resolve(())
        #expect(await task.value)
        let imported = m.document
        #expect(imported.layers.count == 2)
        #expect(imported.annotations == placed.annotations)
        m.pointerDragged(to: Point(x: 200, y: 200))
        m.pointerUp(at: Point(x: 210, y: 210))
        #expect(m.document == imported, "a drag event after the import must not rebuild from the pre-import snapshot")
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.document == placed)
        m.undo()
        #expect(m.document == original)
        #expect(h.assets.released.isEmpty, "redo still reaches the imported pixels")
    }

    @Test("An import completing during a shape drag lands first; the shape then commits as its own step")
    func importDuringCreation() async throws {
        let h = EditorHarness()
        defer { h.model.close() }
        let m = h.model
        let original = m.document
        let (read, url) = Self.suspendedImport(h, "creation-import")
        let task = Task { await m.addImageLayer(from: .file(url)) }
        await waitFor("import suspended") { read.waiterCount == 1 }
        m.selectTool(.rectangle)
        m.pointerDown(at: Point(x: 50, y: 50))
        m.pointerDragged(to: Point(x: 100, y: 90))
        #expect(m.document == original, "a creation drag is only a draft until release")
        read.resolve(())
        #expect(await task.value)
        let imported = m.document
        #expect(imported.layers.count == 2)
        m.pointerDragged(to: Point(x: 150, y: 120))
        m.pointerUp(at: Point(x: 150, y: 120))
        #expect(m.document.layers == imported.layers)
        #expect(m.document.annotations.count == 1, "the interrupted creation gesture must still commit its shape")
        #expect(m.session.undoCount == 2)
        m.undo()
        #expect(m.document == imported)
        m.undo()
        #expect(m.document == original)
    }

    // MARK: B-5 / Spec 1 siblings

    @Test(
        "A command during an open colour adjustment gets its own undo step",
        arguments: [
            "nudge", "delete", "duplicate", "arrange", "crop", "resetCrop", "renumberSteps", "compare", "sideBySide",
            "fitCanvas", "expandCanvas", "align",
        ])
    func commandDuringAdjustment(action: String) throws {
        var document = EditorFixtures.session().document
        let below = Annotation(kind: .rectangle(Rect(x: 20, y: 20, width: 50, height: 40)), style: .default)
        let above = Annotation(kind: .rectangle(Rect(x: 120, y: 20, width: 50, height: 40)), style: .default)
        document.annotations += [above, below]
        switch action {
        case "resetCrop": document.crop = Rect(x: 10, y: 10, width: 200, height: 150)
        case "renumberSteps":
            document.annotations.append(
                Annotation(kind: .step(center: Point(x: 200, y: 100), number: 7), style: .default))
        case "compare", "sideBySide":
            document.layers.append(ImageLayer(assetID: try #require(document.layers.first?.assetID)))
        case "fitCanvas": document.layers[0].placement.translation = Point(x: -20, y: -10)
        default: break
        }
        let h = EditorHarness(session: DocumentSession(document: document))
        defer { h.model.close() }
        let m = h.model
        // The colour panel's coalescer keeps this group open for 700 ms after its last change
        // (EditorInspectorView ChangeCoalescer); a Select-tool click does not end it.
        m.select(.annotation(above.id))
        m.beginContinuousChange()
        m.setStrokeColor(.yellow)
        let adjusted = m.document
        #expect(adjusted != document)
        switch action {
        case "nudge": m.nudgeSelection(dx: 1, dy: 0)
        case "delete": m.deleteSelection()
        case "duplicate": m.duplicateSelection()
        case "arrange": m.reorderSelection(.front)
        case "crop": m.setCrop(Rect(x: 10, y: 10, width: 200, height: 150))
        case "resetCrop": m.setCrop(nil)
        case "renumberSteps": m.renumberSteps()
        case "compare": m.toggleTransparencyComparison()
        case "sideBySide": m.arrangeSideBySide()
        case "fitCanvas": m.fitCanvasToContent()
        case "expandCanvas": m.expandCanvas(top: 40, left: 40, bottom: 40, right: 40)
        case "align": m.align(.left)
        default: Issue.record("Unknown command: \(action)")
        }
        #expect(m.document != adjusted, "the command must be a real change")
        let commanded = m.document
        m.endContinuousChange()
        #expect(m.session.undoCount == 2, "\(action) joined the colour adjustment's undo step")
        m.undo()
        #expect(m.document == adjusted)
        m.undo()
        #expect(m.document == document)
        m.redo()
        m.redo()
        #expect(m.document == commanded)
    }

    // MARK: A-2 sibling

    @Test("Nudging or dragging a mask onto unmappable geometry is refused with history unchanged")
    func movingMaskOntoOverflowingGeometry() throws {
        var document = EditorFixtures.session().document
        document.canvasSize.width = 1e304
        document.layers[0].placement.scale = 1e-5
        document.layers[0].placement.translation = Point(x: 20, y: 20)
        let rect = Rect<DocumentSpace>(x: 0, y: 0, width: 1e304, height: 40)
        let moved = rect.offsetBy(dx: 1, dy: 0)
        let inverse = try document.layers[0].sourceToDocument(assetSize: PixelSize(width: 400, height: 300)).inverted()
        #expect(inverse.isFinite)
        #expect(inverse.apply(moved).width.isInfinite)
        let assetID = try #require(document.layers.first?.assetID)
        let mask = SecureMask(
            outputRect: rect, sourceRegions: [assetID: [PixelRect(x: 0, y: 0, width: 400, height: 300)]], fill: .black)
        document.masks.append(mask)
        let h = EditorHarness(session: DocumentSession(document: document))
        h.renderer.baseImage = makeImage(width: 1, height: 1)
        defer { h.model.close() }
        let m = h.model
        m.setPadding(1)
        m.undo()
        let before = m.document
        let identity = m.session.requestIdentity()
        let redo = m.session.redoLabel
        m.select(.mask(mask.id))
        m.nudgeSelection(dx: 1, dy: 0)
        #expect(m.notice == .redactionRefused)
        m.pointerDown(at: Point(x: 50, y: 20))
        m.pointerDragged(to: Point(x: 60, y: 20))
        m.pointerUp(at: Point(x: 60, y: 20))
        #expect(m.document == before)
        #expect(m.document.masks.first?.sourceRegions == mask.sourceRegions)
        #expect(m.session.revision == identity.revision)
        #expect(m.session.privacyEpoch == identity.privacyEpoch)
        #expect(m.session.undoCount == 0)
        #expect(m.session.redoLabel == redo && m.session.canRedo)
    }

    // MARK: B-3 siblings

    @Test("Close during the automatic batch's upload keeps the finished copy and save and cancels the upload")
    func closeDuringAutomaticUpload() async {
        let upload = SiblingUpload()
        let h = EditorHarness(upload: upload)
        defer { h.model.close() }
        let destination = GitHubDestination(owner: "synthetic", repository: "private-fixtures")
        h.settings.update {
            $0.githubUpload = GitHubUploadPreferences(destination: destination, automatic: true)
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        h.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/sibling-folder", isDirectory: true)
        let task = Task {
            await h.export.runAutomaticExports(
                for: h.model.session, currentSession: { h.model.isClosed ? nil : h.model.session })
        }
        await waitFor("batch upload suspended") { upload.gate.waiterCount == 1 }
        #expect(h.clipboard.writes.count == 1)
        #expect(h.files.uniqueSaves.count == 1)
        h.model.close()
        upload.gate.resolve(())
        let outcomes = await task.value
        #expect(outcomes.count == 3)
        let copiedAndSaved = outcomes.prefix(2).allSatisfy(\.didWrite)
        #expect(copiedAndSaved)
        #expect(outcomes.last == .canceled)
        #expect(upload.observedCancellation)
        #expect(upload.writes.isEmpty)
        #expect(h.clipboard.writes.count == 1 && h.files.uniqueSaves.count == 1)
        #expect(!h.export.isBusy)
    }

    @Test("Close while a drag offer waits revokes it; closing another document leaves it", arguments: [false, true])
    func closeDuringDragOffer(otherDocument: Bool) async {
        let h = EditorHarness()
        let other = EditorModel(session: EditorFixtures.session(), environment: h.model.environment)
        defer { h.model.close(); other.close() }
        let pending = Pending<DragDeliveryOutcome>()
        h.drag.pending = pending
        let task = Task { await h.model.export(.drag) }
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        (otherDocument ? other : h.model).close()
        #expect(h.drag.leases.first?.isRevoked == !otherDocument)
        if otherDocument { pending.resolve(.delivered) }
        let outcome = await task.value
        #expect(outcome == (otherDocument ? .dragged : .canceled))
        #expect(h.drag.writtenSnapshots.count == (otherDocument ? 1 : 0))
        #expect(!h.export.isBusy)
    }
}
