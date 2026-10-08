import CoreGraphics
import Domain
import Foundation
import Testing

@testable import Features

// Independent review of FR-09 / PIN-02 / ADR-007, written from the requirements, not from the
// implementation. Failure modes: a real redaction in the editor leaving a pin's drag deliverable;
// a pin outliving its source editor being unexportable; a revoked or canceled pin export leaving
// the shared coordinator busy; pins from one document sharing an export identity; a pin export
// racing an editor export; a long-waiting pin drag silently starving automatic exports.
@Suite("Review: pin export through the real editor and shared coordinator (PIN-02)")
@MainActor
struct PinsExportReviewTests {
    private func pinnedFromEditor(_ h: EditorHarness) async throws -> PinID {
        await h.model.pin()
        return try #require(h.pins.pins.last?.id)
    }

    @Test("A real redaction in the editor revokes a waiting pin drag and the receiver gets no file")
    func editorRedactionRevokesPinDrag() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.pins.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }

        h.model.selectTool(.redact)
        h.drag((100, 100), (150, 150))

        #expect(h.pins.pins.isEmpty, "the pin of the old epoch is closed")
        #expect(h.drag.leases.first?.isRevoked == true)
        #expect(await outcome == .failed(.staleDocument))
        #expect(h.drag.writtenSnapshots.isEmpty)
        #expect(h.clipboard.writes.isEmpty)
    }

    @Test("Undoing a redaction also revokes a waiting pin drag")
    func undoRedactionRevokesPinDrag() async throws {
        let h = EditorHarness()
        h.model.selectTool(.redact)
        h.drag((100, 100), (150, 150))
        let id = try await pinnedFromEditor(h)
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.pins.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.model.undo()
        #expect(h.drag.leases.first?.isRevoked == true)
        #expect(await outcome == .failed(.staleDocument))
        #expect(h.drag.writtenSnapshots.isEmpty)
    }

    @Test("A pin outlives its source editor and can still be copied (FR-09)")
    func pinSurvivesEditorClose() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        h.model.close()
        #expect(h.pins.pin(for: id) != nil)
        #expect(await h.pins.export(.copy, id) == .copied)
        #expect(h.clipboard.writes.count == 1)
    }

    @Test("Closing the source editor does not revoke the pin's own waiting drag")
    func editorCloseLeavesPinDragAlone() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        let pending = Pending<DragDeliveryOutcome>()
        h.drag.pending = pending
        async let outcome = h.pins.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.model.close()
        #expect(h.drag.leases.first?.isRevoked == false)
        pending.resolve(.delivered)
        #expect(await outcome == .dragged)
    }

    @Test("A non-privacy annotation edit leaves the frozen pin and its drag alone")
    func annotationEditLeavesPinAlone() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        let pending = Pending<DragDeliveryOutcome>()
        h.drag.pending = pending
        async let outcome = h.pins.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.model.selectTool(.arrow)
        h.drag((10, 10), (100, 100))
        #expect(h.drag.leases.first?.isRevoked == false)
        #expect(h.pins.pin(for: id) != nil)
        pending.resolve(.delivered)
        #expect(await outcome == .dragged)
    }

    @Test("Each pin has its own export identity, distinct from its source document")
    func exportIdentitiesAreDistinct() async throws {
        let h = EditorHarness()
        let a = try await pinnedFromEditor(h)
        let b = try await pinnedFromEditor(h)
        let pinA = try #require(h.pins.pin(for: a)), pinB = try #require(h.pins.pin(for: b))
        let idA = try #require(pinA.exportID), idB = try #require(pinB.exportID)
        #expect(idA != idB)
        #expect(idA != h.model.document.id && idB != h.model.document.id, "must not alias the editor's document")
        #expect(await h.pins.export(.copy, a) == .copied)
        #expect(await h.pins.export(.copy, b) == .copied)
        #expect(h.clipboard.writes.map(\.documentID) == [idA, idB])
        #expect(h.clipboard.writes.map(\.privacyEpoch) == [pinA.privacyEpoch, pinB.privacyEpoch])
    }

    @Test("A canceled pin drag leaves the coordinator free and the pin exportable")
    func cancelDuringPinDrag() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.pins.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.export.cancel()
        #expect(await outcome == .canceled)
        #expect(h.drag.writtenSnapshots.isEmpty)
        #expect(!h.export.isBusy)
        h.drag.pending = nil
        #expect(await h.pins.export(.copy, id) == .copied)
    }

    @Test("A revoked pin drag leaves the coordinator free for the next export")
    func revocationReleasesCoordinator() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.pins.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.pins.close(id)
        #expect(await outcome == .failed(.staleDocument))
        #expect(!h.export.isBusy)
        h.drag.pending = nil
        #expect(await h.model.export(.copy) == .copied, "the editor can export again at once")
    }

    @Test("A pin export while the editor exports is rejected as busy and touches no sink")
    func pinRejectedWhileEditorExports() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let editorOutcome = h.model.export(.copy)
        await waitFor("editor encoding") { pending.waiterCount == 1 }
        #expect(await h.pins.export(.copy, id) == .rejectedBusy)
        #expect(h.exporter.pinnedRequests.isEmpty)
        pending.resolve(.success(()))
        #expect(await editorOutcome == .copied)
        #expect(h.clipboard.writes.count == 1, "only the editor's copy")
    }

    @Test("An editor export while a pin export encodes is rejected as busy")
    func editorRejectedWhilePinExports() async throws {
        let h = EditorHarness()
        let id = try await pinnedFromEditor(h)
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let pinOutcome = h.pins.export(.copy, id)
        await waitFor("pin encoding") { pending.waiterCount == 1 }
        #expect(await h.model.export(.copy) == .rejectedBusy)
        pending.resolve(.success(()))
        #expect(await pinOutcome == .copied)
    }

    @Test("A pin export never marks the editor's document saved")
    func pinExportDoesNotMarkEditorSaved() async throws {
        let h = EditorHarness()
        h.model.selectTool(.arrow)
        h.drag((10, 10), (100, 100))
        let id = try await pinnedFromEditor(h)
        let before = h.model.session.isDirty
        #expect(before)
        #expect(await h.pins.export(.copy, id) == .copied)
        #expect(h.model.session.isDirty, "copying a pin is not the editor's export")
    }

    // Characterization, not a requirement: the coordinator has one operation slot, so a pin's
    // drag chip left waiting makes automatic exports of a later capture skip with `.busy`.
    @Test("Characterization: a waiting pin drag makes an automatic export skip as busy")
    func waitingPinDragStarvesAutomaticExport() async throws {
        let h = EditorHarness()
        h.settings.update { $0.autoCopy = true }
        let id = try await pinnedFromEditor(h)
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.pins.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        let session = EditorFixtures.session()
        let automatic = await h.export.runAutomaticExports(for: session, currentSession: { session })
        #expect(automatic == [.failed(.busy)])
        #expect(h.clipboard.writes.isEmpty)
        h.pins.close(id)
        _ = await outcome
    }
}
