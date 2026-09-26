import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-07, FR-09, EXP-01): an editor export that bypasses the export pipeline or
// the coordinator's staleness check; "save to preferred folder" guessing a folder when none is
// authorized; a document marked exported although it changed during the export; an export or pin
// after the editor closed; pins that render anything but the sanitized document.
@Suite("Editor export actions (FR-07, FR-09)")
@MainActor
struct EditorExportTests {
    @Test("Copy goes through the export pipeline and clipboard sink, and clears the dirty state")
    func copy() async {
        let h = EditorHarness()
        h.model.selectTool(.arrow)
        h.drag((10, 10), (90, 90))
        #expect(h.model.isDirty)
        let outcome = await h.model.export(.copy)
        #expect(outcome == .copied)
        #expect(h.exporter.snapshotCount == 1)
        #expect(h.clipboard.writes.count == 1)
        #expect(h.clipboard.writes.first?.revision == h.model.session.revision)
        #expect(h.model.notice == .exported(.copied))
        #expect(!h.model.isDirty)
    }

    @Test("Save passes the panel's overwrite confirmation to the file sink")
    func save() async {
        let h = EditorHarness()
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-written.png")
        #expect(await h.model.export(.save(url, overwriteConfirmed: true)) == .saved(url))
        #expect(h.files.saves.count == 1)
        #expect(h.files.saves.first?.overwrite == true)
    }

    @Test("Save to the preferred folder needs an authorized folder")
    func preferredFolder() async {
        let h = EditorHarness()
        #expect(await h.model.export(.saveToPreferredFolder) == .failed(.accessDenied))
        #expect(h.model.notice == .noPreferredFolder)
        #expect(h.exporter.snapshotCount == 0)

        let folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder", isDirectory: true)
        h.settings.update { $0.preferredSaveFolderBookmark = Data([1]) }
        h.folders.folder = folder
        let outcome = await h.model.export(.saveToPreferredFolder)
        #expect(h.files.uniqueSaves.map(\.folder) == [folder])
        #expect(outcome.didWrite)
    }

    @Test("Drag-out delivers the sanitized snapshot; a canceled drag shows no notice")
    func drag() async {
        let h = EditorHarness()
        #expect(await h.model.export(.drag) == .dragged)
        #expect(h.drag.deliveries.count == 1)
        h.drag.outcome = .success(.canceledByUser)
        h.model.dismissNotice()
        #expect(await h.model.export(.drag) == .canceled)
        #expect(h.model.notice == nil)
    }

    @Test("An edit during the export keeps the document dirty")
    func editDuringExportStaysDirty() async {
        let h = EditorHarness()
        let gate = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = gate
        h.model.selectTool(.arrow)
        h.drag((10, 10), (90, 90))
        let task = Task { await h.model.export(.copy) }
        await waitFor("snapshotting") { gate.waiterCount == 1 }
        h.drag((20, 20), (80, 30))
        gate.resolve(.success(()))
        #expect(await task.value == .failed(.staleDocument))
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.model.isDirty)
    }

    @Test("Pin renders the sanitized document through the pins model")
    func pin() async {
        let h = EditorHarness()
        await h.model.pin()
        #expect(h.pins.pins.count == 1)
        #expect(h.pins.pins.first?.sourceDocumentID == h.model.document.id)
        #expect(h.renderer.fullRenders.count == 1)
        #expect(h.model.notice == .pinned)
    }

    @Test("Pin failures are reported")
    func pinFailure() async {
        let h = EditorHarness()
        await h.settle()
        h.renderer.fails = true
        await h.model.pin()
        #expect(h.model.notice == .pinFailed(.renderFailed))
    }

    @Test("After close, exports and pins do nothing")
    func closedEditorExportsNothing() async {
        let h = EditorHarness()
        h.model.close()
        #expect(await h.model.export(.copy) == .failed(.staleDocument))
        await h.model.pin()
        #expect(h.exporter.snapshotCount == 0)
        #expect(h.pins.pins.isEmpty)
    }

    @Test("Close releases every asset the editor added, including undone ones")
    func closeReleasesAddedAssets() async {
        let h = EditorHarness()
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-read.png")
        h.input.files[url] = .success(Data([1]))
        #expect(await h.model.addImageLayer(from: .file(url)))
        let ids = Set(h.model.document.assets.keys)
        h.model.undo()
        h.model.close()
        #expect(Set(h.assets.released) == ids)
        #expect(h.model.isClosed)
    }
}
