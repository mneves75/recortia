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

    @Test("Save replaces an existing file only after the panel confirmed it")
    func saveOverwriteFollowsConfirmation() async {
        let h = EditorHarness()
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-written.png")
        h.files.existing = [url]
        #expect(
            await h.model.export(.save(url, format: .fixed(.png), replacing: nil)) == .failed(.destinationExists(url)))
        #expect(await h.model.export(.save(url, format: .fixed(.png), replacing: url)) == .saved(url))
        #expect(h.files.saves.map(\.overwrite) == [true])
    }

    @Test("Save writes the format its sheet named even when the preference changes while it is open")
    func saveKeepsTheSheetFormat() async {
        let h = EditorHarness()
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-written.png")
        h.settings.update { $0.defaultExportFormat = .jpeg }
        _ = await h.model.export(.save(url, format: .fixed(.png), replacing: nil))
        _ = await h.model.export(.save(url, format: .fixed(.png), replacing: url))
        #expect(h.files.saves.map(\.snapshot.format) == [.png, .png], "a .png name receives PNG bytes")
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

    @Test("Redacting while a drag is offered revokes it: the pre-redaction pixels are never written (RED-03)")
    func redactionRevokesPendingDrag() async throws {
        let h = EditorHarness()
        let pending = Pending<DragDeliveryOutcome>()
        h.drag.pending = pending
        let export = Task { await h.model.export(.drag) }
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        let lease = try #require(h.drag.leases.first)
        h.model.selectTool(.redact)
        h.drag((10, 10), (40, 30))
        #expect(!h.model.document.masks.isEmpty)
        #expect(lease.isRevoked)
        #expect(h.drag.dismissCount == 1)
        _ = await export.value
        #expect(h.drag.writtenSnapshots.isEmpty)
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

    @Test("Pin failures are reported")
    func pinFailure() async {
        let h = EditorHarness()
        await h.settle()
        h.renderer.fails = true
        await h.model.pin()
        #expect(h.model.notice == .pinFailed(.renderFailed))
    }

    // Failure mode (Codex review): an undone image whose redo step is discarded stayed in the
    // image store until the editor closed (up to ~160 MB per 40 MP import).
    @Test("An added image whose history became unreachable is released while the editor stays open")
    func unreachableAssetReleased() async throws {
        let h = EditorHarness()
        let base = Set(h.model.document.assets.keys)
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-read.png")
        h.input.files[url] = .success(Data([1]))
        #expect(await h.model.addImageLayer(from: .file(url)))
        let added = Set(h.model.document.assets.keys).subtracting(base)
        h.model.undo()
        #expect(h.assets.released.isEmpty, "still reachable through redo")
        let layer = try #require(h.model.document.layers.first?.id)
        h.model.setLayerOpacity(0.5, for: layer)  // an unrelated edit discards the redo step
        #expect(Set(h.assets.released) == added)
        #expect(h.model.canRedo == false)
    }

    @Test("Deleted image pixels are released only after their undo history is evicted")
    func deletedAssetReleasedAfterHistoryEviction() async throws {
        let h = EditorHarness(session: EditorFixtures.session(undoLimit: 1))
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-read.png")
        h.input.files[url] = .success(Data([1]))
        #expect(await h.model.addImageLayer(from: .file(url)))
        let layer = try #require(h.model.document.layers.last)
        h.model.select(.layer(layer.id))
        h.model.deleteSelection()
        #expect(h.model.document.assets[layer.assetID] == nil)
        #expect(h.assets.released.isEmpty, "deletion can still be undone")
        h.model.undo()
        #expect(h.model.document.layers.contains { $0.id == layer.id })
        h.model.redo()
        #expect(h.assets.released.isEmpty, "undo history still owns the deleted pixels")
        h.model.setResizeScale(0.5)
        #expect(h.assets.released == [layer.assetID])
    }

    @Test("Finalizing gestures and continuous changes releases assets evicted from history")
    func groupFinalizationReleasesEvictedAsset() async throws {
        for useGesture in [false, true] {
            let h = EditorHarness(session: EditorFixtures.session(undoLimit: 1))
            let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-read.png")
            h.input.files[url] = .success(Data([1]))
            #expect(await h.model.addImageLayer(from: .file(url)))
            let deleted = try #require(h.model.document.layers.last)
            h.model.select(.layer(deleted.id))
            h.model.deleteSelection()
            #expect(h.assets.released.isEmpty)
            if useGesture {
                h.model.selectTool(.select)
                h.model.pointerDown(at: Point(x: 100, y: 80))
                h.model.pointerDragged(to: Point(x: 110, y: 90))
                #expect(h.model.session.isGrouping)
                #expect(h.assets.released.isEmpty)
                h.model.pointerUp(at: Point(x: 110, y: 90))
            } else {
                h.model.beginContinuousChange()
                h.model.setResizeScale(0.5)
                #expect(h.assets.released.isEmpty)
                h.model.endContinuousChange()
            }
            #expect(h.assets.released == [deleted.assetID])
        }
    }

    @Test("Deleting one duplicate keeps the shared asset until its last layer and history are gone")
    func deletingDuplicateRetainsSharedAsset() throws {
        let h = EditorHarness(session: EditorFixtures.session(undoLimit: 1))
        let layer = try #require(h.model.document.layers.first)
        h.model.select(.layer(layer.id))
        h.model.duplicateSelection()
        h.model.deleteSelection()
        #expect(h.model.document.assets[layer.assetID] != nil)
        h.model.setResizeScale(0.5)
        #expect(h.assets.released.isEmpty)
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

    @Test("Canceling a task waiting for the export slot or auto-redaction unblocks promptly", .timeLimit(.minutes(1)))
    func taskCancellationUnblocksEditorWaiters() async {
        // 1. Waiting in waitForExportSlot while another export occupies the shared coordinator.
        let h = EditorHarness()
        defer { h.model.close() }
        h.settings.update { $0.autoCopy = true }
        let gate = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = gate
        let holder = Task { await h.model.export(.copy) }
        await waitFor("first export holds slot") { gate.waiterCount == 1 && h.export.isBusy }

        let plan = h.export.automaticExportPlan()
        let waiting = Task { await h.model.runAutomaticExports(plan) }
        await waitFor("batch queued on export slot") { h.model.exportSlotWaiters.count == 1 }
        waiting.cancel()
        #expect(await waiting.value == [.canceled])
        #expect(h.model.exportSlotWaiters.count == 0)

        h.exporter.pending = nil
        gate.resolve(.success(()))
        _ = await holder.value

        // 2. Waiting in autoRedactionSettled while masking is pending.
        h.sensitiveText.pending = Pending<Void>()
        let masked = EditorModel(
            session: EditorFixtures.session(), environment: h.model.environment, autoRedacts: true)
        defer { masked.close() }
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        let maskedBatch = Task { await masked.runAutomaticExports(plan) }
        await waitFor("batch waiting for masking") { masked.autoRedactionWaiters.count == 1 }
        maskedBatch.cancel()
        #expect(await maskedBatch.value == [.canceled])
        #expect(masked.autoRedactionWaiters.count == 0)
    }

    @Test(
        "Releasing an editor without close() cancels tasks and unblocks waiting continuations",
        .timeLimit(.minutes(1)))
    func deinitUnblocksWaiters() async {
        let h = EditorHarness()
        defer { h.model.close() }
        h.sensitiveText.pending = Pending<Void>()
        weak var released: EditorModel?
        let redactionWaiter: Task<DocumentSession?, Never>
        let slotWaiter: Task<Void, Never>
        do {
            let model = EditorModel(
                session: EditorFixtures.session(), environment: h.model.environment, autoRedacts: true)
            released = model
            let autoWaiters = model.autoRedactionWaiters
            let exportWaiters = model.exportSlotWaiters
            redactionWaiter = Task { await autoWaiters.wait(cancelledValue: nil) }
            slotWaiter = Task { await exportWaiters.wait(cancelledValue: ()) }
            await waitFor("waiters registered") { autoWaiters.count == 1 && exportWaiters.count == 1 }
        }
        await waitFor("editor deallocated") { released == nil }
        #expect(await redactionWaiter.value == nil)
        await slotWaiter.value
        h.sensitiveText.pending?.resolve(())
        await drain()
        #expect(h.sensitiveText.observedCancellation)
    }
}
