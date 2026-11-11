import Domain
import Foundation
import MacPlatform
import Testing

@testable import Features

// Failure modes (EXP-02): render/encode failure, clipboard failure, denied folder, collision,
// disk full, unplugged volume, canceled drag, cancellation before and after commit, a snapshot
// that no longer matches the live document, and auto-export when the preference is off or no
// folder is authorized. None may produce a false success or touch a sink before commit.
@MainActor
final class ExportHarness {
    let exporter = FakeExportService()
    let clipboard = FakeClipboard()
    let files = FakeFileSink()
    let drag = FakeDragSink()
    let folders = FakeSaveFolders()
    let clock = ManualClock()
    let settings = SettingsStore(storage: MemoryPreferenceStorage())
    let coordinator: ExportCoordinator
    var session = TestFixtures.session()

    init(upload: (any GitHubUploadService)? = nil) {
        coordinator = ExportCoordinator(
            exporter: exporter, clipboard: clipboard, files: files, drag: drag, folders: folders, clock: clock,
            settings: settings, upload: upload)
    }

    func export(_ action: ExportAction) async -> ExportOutcome {
        await coordinator.export(action, session: session, currentSession: { [unowned self] in self.session })
    }
}

/// Counts upload requests; succeeds only while the coordinator's live check still allows it.
@MainActor
private final class RecordingUpload: GitHubUploadService {
    private(set) var requests = 0

    func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, intent: UUID,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        requests += 1
        guard isCurrent() else { throw .canceled }
        return URL(fileURLWithPath: "/tmp/recortia-tests/never-uploaded.png")
    }
}

@Suite("ExportCoordinator (FR-07, EXP-02)")
@MainActor
struct ExportCoordinatorTests {
    let destination = URL(fileURLWithPath: "/tmp/recortia-tests/never-written.png")

    @Test(
        "Pipeline failures never touch a sink",
        arguments: [ExportFailure.budgetExceeded])
    func pipelineFailure(failure: ExportFailure) async {
        let h = ExportHarness()
        h.exporter.failure = failure
        #expect(await h.export(.copy) == .failed(failure))
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.coordinator.state == .failed(failure))
    }

    @Test(
        "Sink errors map to typed export failures without a success report",
        arguments: [
            (SinkError.accessDenied, ExportFailure.accessDenied),
            (.destinationExists, .destinationExists),
            (.diskFull, .diskFull),
            (.volumeUnavailable, .volumeUnavailable),
            (.writeFailed(code: 5), .system(code: 5)),
        ])
    func fileSinkErrors(error: SinkError, expected: ExportFailure) async {
        let h = ExportHarness()
        h.files.error = error
        #expect(await h.export(.save(to: destination, overwriteConfirmed: false)) == .failed(expected))
        #expect(h.coordinator.state == .failed(expected))
    }

    @Test("A clipboard failure is reported as such")
    func clipboardFailure() async {
        let h = ExportHarness()
        h.clipboard.error = .clipboardWriteFailed
        #expect(await h.export(.copy) == .failed(.clipboardFailed))
    }

    @Test("A snapshot of an outdated revision or privacy epoch is rejected")
    func staleSnapshotRejected() async throws {
        let h = ExportHarness()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let outcome = h.export(.copy)
        await waitFor("snapshotting") { pending.waiterCount == 1 }
        // The user adds a secure mask while the export is rendering: the privacy epoch moves.
        try h.session.addSecureMask(covering: Rect(x: 0, y: 0, width: 4, height: 4))
        pending.resolve(.success(()))
        #expect(await outcome == .failed(.staleDocument))
        #expect(h.clipboard.writes.isEmpty)
    }

    @Test("A closed document rejects its in-flight export")
    func closedDocumentRejected() async {
        let h = ExportHarness()
        let outcome = await h.coordinator.export(.copy, session: h.session, currentSession: { nil })
        #expect(outcome == .failed(.staleDocument))
        #expect(h.clipboard.writes.isEmpty)
    }

    @Test("Drag succeeds on delivery; a user-canceled drag is a cancellation")
    func dragOutcomes() async {
        let h = ExportHarness()
        #expect(await h.export(.drag) == .dragged)
        h.drag.outcome = .success(.canceledByUser)
        #expect(await h.export(.drag) == .canceled)
        h.drag.outcome = .failure(.writeFailed(code: 9))
        #expect(await h.export(.drag) == .failed(.system(code: 9)))
    }

    @Test("A delivery reported after the lease was revoked is not committed as a success")
    func deliveryAfterRevocationIsStale() async throws {
        let h = ExportHarness()
        let pending = Pending<DragDeliveryOutcome>()
        h.drag.pending = pending
        async let outcome = h.export(.drag)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.drag.leases.first?.revoke()
        pending.resolve(.delivered)
        #expect(await outcome == .failed(.staleDocument))
        #expect(h.drag.writtenSnapshots.isEmpty)
    }

    // Failure mode (spec review): the receiver already has the file, then an edit or Cancel
    // lands before the chip reports; the export must not be reported canceled or stale
    // (SPEC.md: cancellation after a commit reports that the action already completed).
    @Test("A drag whose file was written survives a later document change and reports success")
    func committedDragSurvivesDocumentChange() async throws {
        let h = ExportHarness()
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.export(.drag)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        let lease = try #require(h.drag.leases.first)
        #expect(lease.whileValid { true } == true, "the receiver's write commits the lease")
        h.coordinator.invalidatePendingDrag(documentID: h.session.document.id)
        #expect(!lease.isRevoked, "a committed lease cannot be revoked")
        #expect(await outcome == .dragged)
    }

    @Test("Cancel after the drag's file was written reports that it already completed")
    func cancelAfterCommittedDrag() async throws {
        let h = ExportHarness()
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.export(.drag)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        _ = h.drag.leases.first?.whileValid { true }
        h.coordinator.cancel()
        #expect(await outcome == .alreadyCompleted(.dragged))
    }

    // Failure mode (security run-2): a chip closed or delivered left its lease valid, so a file
    // promise already handed to a receiver could write the old snapshot after a later redaction.
    @Test(
        "An offer that ends without a write revokes its lease",
        arguments: [
            DragDeliveryOutcome.canceledByUser, .delivered,
        ])
    func endedOfferRevokesLease(outcome: DragDeliveryOutcome) async throws {
        let h = ExportHarness()
        let pending = Pending<DragDeliveryOutcome>()
        h.drag.pending = pending
        h.drag.commitOnDelivery = false  // a receiver that never asked for the file
        async let result = h.export(.drag)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        pending.resolve(outcome)
        _ = await result
        #expect(h.drag.leases.first?.isRevoked == true, "an outstanding promise could still write")
    }

    @Test("Automatic copy and save do nothing while the preferences are off (default)")
    func automaticExportsOffByDefault() async {
        let h = ExportHarness()
        let outcomes = await h.coordinator.runAutomaticExports(
            h.coordinator.automaticExportPlan(), for: h.session, currentSession: { h.session })
        #expect(outcomes.isEmpty)
        #expect(h.exporter.snapshotCount == 0)
        #expect(h.clipboard.writes.isEmpty)
    }

    @Test("Automatic copy and save run only when enabled; save needs an authorized folder")
    func automaticExportsWhenEnabled() async {
        let h = ExportHarness()
        // A chosen folder that no longer resolves fails the save; it never falls back elsewhere.
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1, 2, 3])
        }
        var outcomes = await h.coordinator.runAutomaticExports(
            h.coordinator.automaticExportPlan(), for: h.session, currentSession: { h.session })
        #expect(outcomes == [.copied, .failed(.accessDenied)])
        #expect(h.files.uniqueSaves.isEmpty && h.files.saves.isEmpty)

        let folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder", isDirectory: true)
        h.folders.folder = folder
        outcomes = await h.coordinator.runAutomaticExports(
            h.coordinator.automaticExportPlan(), for: h.session, currentSession: { h.session })
        #expect(outcomes.count == 2)
        #expect(h.files.uniqueSaves.map(\.folder) == [folder])
    }

    @Test("Saves use the preferred format; Copy always publishes PNG only")
    func exportOptionsFromPreferences() async {
        let h = ExportHarness()
        h.settings.update {
            $0.defaultExportFormat = .jpeg
            $0.jpegQuality = 0.5
        }
        _ = await h.export(.save(to: destination, overwriteConfirmed: false))
        #expect(h.files.saves.first?.snapshot.format == .jpeg(quality: 0.5))
        _ = await h.export(.copy)
        #expect(h.clipboard.writes.first?.format == .png)
    }

    @Test("Canceling automatic copy cancels the whole batch before save")
    func cancelAutomaticBatch() async {
        let h = ExportHarness()
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        h.folders.folder = destination.deletingLastPathComponent()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        let plan = h.coordinator.automaticExportPlan()
        let running = Task {
            await h.coordinator.runAutomaticExports(plan, for: h.session, currentSession: { h.session })
        }
        await waitFor("automatic copy rendering") { pending.waiterCount == 1 }
        h.coordinator.cancel()
        // Subsequent snapshots must not wait here: that would hide a canceled-batch regression.
        h.exporter.pending = nil
        pending.resolve(.success(()))
        #expect(await running.value == [.canceled])
        #expect(h.exporter.snapshotCount == 1)
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.files.uniqueSaves.isEmpty)
    }

    @Test("Turning automatic copy or save off, or changing the save folder, during the render stops that write")
    func automaticExportsRecheckPreferences() async {
        let h = ExportHarness()
        h.settings.update { $0.autoCopy = true }
        let copyRender = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = copyRender
        let plan = h.coordinator.automaticExportPlan()
        let copyRun = Task {
            await h.coordinator.runAutomaticExports(plan, for: h.session, currentSession: { h.session })
        }
        await waitFor("automatic copy rendering") { copyRender.waiterCount == 1 }
        h.settings.update { $0.autoCopy = false }
        copyRender.resolve(.success(()))
        #expect(await copyRun.value == [.canceled])
        #expect(h.clipboard.writes.isEmpty)

        h.settings.update {
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        let folder = destination.deletingLastPathComponent()
        h.folders.folder = folder
        func saveWhileRendering(_ change: () -> Void) async -> [ExportOutcome] {
            let render = Pending<Result<Void, ExportServiceError>>()
            h.exporter.pending = render
            let plan = h.coordinator.automaticExportPlan()
            let run = Task {
                await h.coordinator.runAutomaticExports(plan, for: h.session, currentSession: { h.session })
            }
            await waitFor("automatic save rendering") { render.waiterCount == 1 }
            change()
            render.resolve(.success(()))
            return await run.value
        }
        // The folder moved: its renewed bookmark still resolves to the authorized folder.
        _ = await saveWhileRendering { h.settings.update { $0.preferredSaveFolderBookmark = Data([2]) } }
        #expect(h.files.uniqueSaves.map(\.folder) == [folder])
        // The user chose another folder: the pending save does not go to the old one.
        let outcomes = await saveWhileRendering {
            h.settings.update { $0.preferredSaveFolderBookmark = Data([3]) }
            h.folders.folder = folder.appendingPathComponent("other", isDirectory: true)
        }
        #expect(outcomes == [.canceled])
        #expect(h.files.uniqueSaves.count == 1)
        // The user turned automatic saving off: the pending save does not happen.
        let offOutcomes = await saveWhileRendering { h.settings.update { $0.autoSave = false } }
        #expect(offOutcomes == [.canceled])
        #expect(h.files.uniqueSaves.count == 1)
    }

    /// Runs an automatic batch whose copy step waits at the render, applies `change` there, and
    /// lets the batch finish without any later step waiting.
    private func batchChangingDuringCopy(_ h: ExportHarness, _ change: () -> Void) async -> [ExportOutcome] {
        let copyRender = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = copyRender
        let plan = h.coordinator.automaticExportPlan()
        let run = Task { await h.coordinator.runAutomaticExports(plan, for: h.session, currentSession: { h.session }) }
        await waitFor("automatic copy rendering") { copyRender.waiterCount == 1 }
        change()
        h.exporter.pending = nil
        copyRender.resolve(.success(()))
        return await run.value
    }

    @Test("Turning automatic save or upload on while the copy renders applies to the next capture only")
    func automaticBatchFreezesItsActions() async {
        let upload = RecordingUpload()
        let h = ExportHarness(upload: upload)
        let folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder-a", isDirectory: true)
        h.folders.folder = folder
        h.settings.update {
            $0.autoCopy = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        let outcomes = await batchChangingDuringCopy(h) {
            h.settings.update {
                $0.autoSave = true
                $0.githubUpload = GitHubUploadPreferences(
                    destination: GitHubDestination(owner: "synthetic", repository: "private-fixtures"),
                    automatic: true)
            }
        }
        #expect(outcomes == [.copied])
        #expect(h.files.uniqueSaves.isEmpty && h.files.saves.isEmpty, "a capture taken with saving off was saved")
        #expect(upload.requests == 0, "a capture taken with upload off was sent")
    }

    @Test("Changing the save folder while the copy renders never saves this capture to the new folder")
    func automaticBatchFreezesItsFolder() async {
        let h = ExportHarness()
        let folderA = URL(fileURLWithPath: "/tmp/recortia-tests/folder-a", isDirectory: true)
        let folderB = URL(fileURLWithPath: "/tmp/recortia-tests/folder-b", isDirectory: true)
        h.folders.folder = folderA
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        let outcomes = await batchChangingDuringCopy(h) {
            h.settings.update { $0.preferredSaveFolderBookmark = Data([2]) }
            h.folders.folder = folderB
        }
        #expect(!h.files.uniqueSaves.contains { $0.folder == folderB }, "saved to a folder chosen after the capture")
        // Folder A is no longer the chosen folder, so it is not allowed either.
        #expect(h.files.uniqueSaves.isEmpty)
        #expect(outcomes == [.copied])
    }

    @Test("Turning automatic save off while the copy renders still writes nothing")
    func automaticBatchStillStopsARevokedSave() async {
        let h = ExportHarness()
        h.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder-a", isDirectory: true)
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        let outcomes = await batchChangingDuringCopy(h) { h.settings.update { $0.autoSave = false } }
        #expect(outcomes == [.copied])
        #expect(h.exporter.snapshotCount == 1, "a save turned off before its step still rendered")
        #expect(h.files.uniqueSaves.isEmpty && h.files.saves.isEmpty)
    }

    @Test("Turning automatic upload off, or changing its repository, while the copy renders sends nothing")
    func automaticBatchStillStopsARevokedUpload() async {
        let destination = GitHubDestination(owner: "synthetic", repository: "private-fixtures")
        let changes: [(String, (inout Preferences) -> Void)] = [
            ("off", { $0.githubUpload?.automatic = false }),
            (
                "other repository",
                { $0.githubUpload?.destination = GitHubDestination(owner: "synthetic", repository: "other") }
            ),
        ]
        for (label, change) in changes {
            let upload = RecordingUpload()
            let h = ExportHarness(upload: upload)
            h.settings.update {
                $0.autoCopy = true
                $0.githubUpload = GitHubUploadPreferences(destination: destination, automatic: true)
            }
            let outcomes = await batchChangingDuringCopy(h) { h.settings.update(change) }
            #expect(outcomes == [.copied], "\(label)")
            #expect(upload.requests == 0, "\(label): the upload was requested")
            #expect(h.exporter.snapshotCount == 1, "\(label): a revoked upload still rendered")
        }
    }

    /// Decides the batch from the settings, as `AppModel` does when the capture completes, then
    /// applies `change` (a main-actor job queued before the batch's task runs) and runs it.
    private func batchChangedBeforeItStarts(_ h: ExportHarness, _ change: () -> Void) async -> [ExportOutcome] {
        let plan = h.coordinator.automaticExportPlan()
        change()
        return await h.coordinator.runAutomaticExports(plan, for: h.session, currentSession: { h.session })
    }

    @Test("Automatic save turned on, with a folder chosen, after the capture writes no file for it")
    func batchDecidedAtCaptureIgnoresALaterSave() async {
        let h = ExportHarness()
        h.settings.update { $0.autoCopy = true }
        let outcomes = await batchChangedBeforeItStarts(h) {
            h.settings.update {
                $0.autoSave = true
                $0.preferredSaveFolderBookmark = Data([1])
            }
            h.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder-a", isDirectory: true)
        }
        #expect(outcomes == [.copied])
        #expect(h.files.uniqueSaves.isEmpty && h.files.saves.isEmpty, "a capture taken with saving off was saved")
        #expect(h.exporter.snapshotCount == 1)
    }

    @Test("A folder chosen after the capture never receives it; the capture's folder only while still allowed")
    func batchDecidedAtCaptureKeepsItsFolder() async {
        let folderA = URL(fileURLWithPath: "/tmp/recortia-tests/folder-a", isDirectory: true)
        let folderB = URL(fileURLWithPath: "/tmp/recortia-tests/folder-b", isDirectory: true)
        func harness() -> ExportHarness {
            let h = ExportHarness()
            h.folders.folder = folderA
            h.settings.update {
                $0.autoSave = true
                $0.preferredSaveFolderBookmark = Data([1])
            }
            return h
        }
        let changed = harness()
        let outcomes = await batchChangedBeforeItStarts(changed) {
            changed.settings.update { $0.preferredSaveFolderBookmark = Data([2]) }
            changed.folders.folder = folderB
        }
        #expect(!changed.files.uniqueSaves.contains { $0.folder == folderB }, "saved to a folder chosen later")
        #expect(changed.files.uniqueSaves.isEmpty, "folder A is no longer chosen, so it is not allowed")
        #expect(outcomes.isEmpty)
        // The folder moved: its renewed bookmark still resolves to A, which stays allowed.
        let moved = harness()
        _ = await batchChangedBeforeItStarts(moved) {
            moved.settings.update { $0.preferredSaveFolderBookmark = Data([2]) }
        }
        #expect(moved.files.uniqueSaves.map(\.folder) == [folderA])
    }

    @Test("Automatic upload turned on after the capture sends nothing for it")
    func batchDecidedAtCaptureIgnoresALaterUpload() async {
        let upload = RecordingUpload()
        let h = ExportHarness(upload: upload)
        h.settings.update { $0.autoCopy = true }
        let outcomes = await batchChangedBeforeItStarts(h) {
            h.settings.update {
                $0.githubUpload = GitHubUploadPreferences(
                    destination: GitHubDestination(owner: "synthetic", repository: "private-fixtures"),
                    automatic: true)
            }
        }
        #expect(outcomes == [.copied])
        #expect(upload.requests == 0, "a capture taken with upload off was sent")
    }

    @Test("Automatic save turned off after the capture still writes nothing")
    func batchDecidedAtCaptureStillStopsARevokedSave() async {
        let h = ExportHarness()
        h.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder-a", isDirectory: true)
        h.settings.update {
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        let outcomes = await batchChangedBeforeItStarts(h) { h.settings.update { $0.autoSave = false } }
        #expect(outcomes.isEmpty)
        #expect(h.exporter.snapshotCount == 0, "a save turned off before its step still rendered")
        #expect(h.files.uniqueSaves.isEmpty && h.files.saves.isEmpty)
    }

}
