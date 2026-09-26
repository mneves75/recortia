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

    init() {
        coordinator = ExportCoordinator(
            exporter: exporter, clipboard: clipboard, files: files, drag: drag, folders: folders, clock: clock,
            settings: settings)
    }

    func export(_ action: ExportAction) async -> ExportOutcome {
        await coordinator.export(action, session: session, currentSession: { [unowned self] in self.session })
    }
}

@Suite("ExportCoordinator (FR-07, EXP-02)")
@MainActor
struct ExportCoordinatorTests {
    let destination = URL(fileURLWithPath: "/tmp/recortia-tests/never-written.png")

    @Test("Copy reports success only after the clipboard write")
    func copySucceeds() async {
        let h = ExportHarness()
        let outcome = await h.export(.copy)
        #expect(outcome == .copied)
        #expect(h.clipboard.writes.count == 1)
        #expect(h.coordinator.state == .succeeded(canceledAfterCommit: false))
    }

    @Test(
        "Pipeline failures never touch a sink",
        arguments: [ExportFailure.renderFailed, .encodeFailed, .budgetExceeded])
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

    @Test("Save passes the user's overwrite confirmation through")
    func saveToURL() async {
        let h = ExportHarness()
        #expect(await h.export(.save(to: destination, overwriteConfirmed: true)) == .saved(destination))
        #expect(h.files.saves.first?.overwrite == true)
    }

    @Test("Cancel before commit leaves the clipboard untouched")
    func cancelBeforeCommit() async {
        let h = ExportHarness()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let outcome = h.export(.copy)
        await waitFor("snapshotting") { pending.waiterCount == 1 }
        h.coordinator.cancel()
        pending.resolve(.success(()))
        #expect(await outcome == .canceled)
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.coordinator.state == .canceled)
    }

    @Test("Cancel during the file commit reports that the save already completed")
    func cancelAfterCommit() async {
        let h = ExportHarness()
        let pending = Pending<Void>()
        h.files.pending = pending
        async let outcome = h.export(.save(to: destination, overwriteConfirmed: false))
        await waitFor("committing") { pending.waiterCount == 1 }
        #expect(h.coordinator.state == .committing)
        h.coordinator.cancel()
        pending.resolve(())
        #expect(await outcome == .alreadyCompleted(.saved(destination)))
        #expect(h.coordinator.state == .succeeded(canceledAfterCommit: true))
        #expect(h.files.saves.count == 1)
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

    @Test("Only one export runs at a time")
    func oneExportAtATime() async {
        let h = ExportHarness()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let first = h.export(.copy)
        await waitFor("busy") { pending.waiterCount == 1 }
        #expect(h.coordinator.isBusy)
        #expect(await h.export(.copy) == .rejectedBusy)
        pending.resolve(.success(()))
        #expect(await first == .copied)
        #expect(h.clipboard.writes.count == 1)
    }

    @Test("Automatic copy and save do nothing while the preferences are off (default)")
    func automaticExportsOffByDefault() async {
        let h = ExportHarness()
        let outcomes = await h.coordinator.runAutomaticExports(for: h.session, currentSession: { h.session })
        #expect(outcomes.isEmpty)
        #expect(h.exporter.snapshotCount == 0)
        #expect(h.clipboard.writes.isEmpty)
    }

    @Test("Automatic copy and save run only when enabled; save needs an authorized folder")
    func automaticExportsWhenEnabled() async {
        let h = ExportHarness()
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
        }
        var outcomes = await h.coordinator.runAutomaticExports(for: h.session, currentSession: { h.session })
        #expect(outcomes == [.copied, .failed(.accessDenied)])

        let folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder", isDirectory: true)
        h.folders.folder = folder
        h.settings.update { $0.preferredSaveFolderBookmark = Data([1, 2, 3]) }
        outcomes = await h.coordinator.runAutomaticExports(for: h.session, currentSession: { h.session })
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
}
