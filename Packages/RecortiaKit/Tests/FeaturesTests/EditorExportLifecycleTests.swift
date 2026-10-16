import Domain
import Foundation
import Testing

@testable import Features

@MainActor
private final class LifecycleUpload: GitHubUploadService {
    enum Suspension { case none, beforeCommit, afterCommit }
    var suspension = Suspension.beforeCommit
    let gate = Pending<Void>()
    let url = URL(fileURLWithPath: "/tmp/recortia-tests/synthetic-upload.png")
    private(set) var requests: [DocumentID] = []
    private(set) var writes: [DocumentID] = []
    private(set) var observedCancellation = false

    func upload(
        _ snapshot: ShareSnapshot, to destination: GitHubDestination, intent: UUID,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async throws(GitHubUploadFailure) -> URL {
        requests.append(snapshot.documentID)
        if suspension == .beforeCommit {
            await gate.wait()
            observedCancellation = Task.isCancelled
            if observedCancellation { throw .canceled }
        }
        guard isCurrent() else { throw .staleDocument }
        writes.append(snapshot.documentID)
        if suspension == .afterCommit {
            await gate.wait()
            observedCancellation = Task.isCancelled
            // The synthetic remote write already succeeded; cancellation cannot retract it.
        }
        return url
    }
}

@Suite("Closing an editor cancels only its document exports (FR-07, NET-01)")
@MainActor
struct EditorExportLifecycleTests {
    private let destination = GitHubDestination(owner: "synthetic", repository: "private-fixtures")

    private func configureUpload(_ h: EditorHarness) {
        h.settings.update { $0.githubUpload = GitHubUploadPreferences(destination: destination, automatic: true) }
    }

    @Test("Close cancels a suspended snapshot; closing another document does not", arguments: [false, true])
    func closeDuringSnapshot(otherDocument: Bool) async {
        let h = EditorHarness()
        let other = EditorModel(session: EditorFixtures.session(), environment: h.model.environment)
        defer { h.model.close(); other.close() }
        let gate = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = gate
        let task = Task { await h.model.export(.copy) }
        await waitFor("snapshot suspended") { gate.waiterCount == 1 }
        (otherDocument ? other : h.model).close()
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        h.exporter.pending = nil
        gate.resolve(.success(()))
        #expect(await task.value == (otherDocument ? .copied : .canceled))
        #expect(h.exporter.snapshotCancellationCount == (otherDocument ? 0 : 1))
        #expect(h.clipboard.writes.count == (otherDocument ? 1 : 0))
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(!h.export.isBusy)
    }

    @Test("Close cancels a suspended upload; closing another document does not", arguments: [false, true])
    func closeDuringUpload(otherDocument: Bool) async {
        let upload = LifecycleUpload()
        let h = EditorHarness(upload: upload)
        let other = EditorModel(session: EditorFixtures.session(), environment: h.model.environment)
        defer { h.model.close(); other.close() }
        configureUpload(h)
        let task = Task {
            await h.export.export(
                .upload(to: destination, intent: UUID()), session: h.model.session,
                currentSession: { h.model.isClosed ? nil : h.model.session })
        }
        await waitFor("upload suspended") { upload.gate.waiterCount == 1 }
        (otherDocument ? other : h.model).close()
        #expect(upload.writes.isEmpty)
        upload.gate.resolve(())
        #expect(await task.value == (otherDocument ? .uploaded(upload.url) : .canceled))
        #expect(upload.observedCancellation == !otherDocument)
        #expect(upload.writes.count == (otherDocument ? 1 : 0))
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(!h.export.isBusy)
    }

    @Test("Close cancels the automatic batch before subsequent snapshots or sinks", arguments: [false, true])
    func closeDuringAutomaticBatch(otherDocument: Bool) async {
        let upload = LifecycleUpload()
        upload.suspension = .none
        let h = EditorHarness(upload: upload)
        let other = EditorModel(session: EditorFixtures.session(), environment: h.model.environment)
        defer { h.model.close(); other.close() }
        configureUpload(h)
        h.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        h.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/synthetic-folder", isDirectory: true)
        let gate = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = gate
        let task = Task {
            await h.export.runAutomaticExports(
                for: h.model.session, currentSession: { h.model.isClosed ? nil : h.model.session })
        }
        await waitFor("batch snapshot suspended") { gate.waiterCount == 1 }
        (otherDocument ? other : h.model).close()
        #expect(h.clipboard.writes.isEmpty && h.files.uniqueSaves.isEmpty && upload.writes.isEmpty)
        h.exporter.pending = nil
        gate.resolve(.success(()))
        let outcomes = await task.value
        if otherDocument {
            #expect(outcomes.count == 3 && outcomes.allSatisfy(\.didWrite))
        } else {
            #expect(outcomes == [.canceled])
        }
        #expect(h.exporter.snapshotCount == (otherDocument ? 3 : 1))
        #expect(h.exporter.snapshotCancellationCount == (otherDocument ? 0 : 1))
        #expect(h.clipboard.writes.count == (otherDocument ? 1 : 0))
        #expect(h.files.uniqueSaves.count == (otherDocument ? 1 : 0))
        #expect(h.files.saves.isEmpty)
        #expect(upload.requests.count == (otherDocument ? 1 : 0))
        #expect(upload.writes.count == (otherDocument ? 1 : 0))
        #expect(!h.export.isBusy)
    }

    @Test("Close during an admitted file commit reports the completed write truthfully")
    func closeDuringFileCommit() async {
        let h = EditorHarness()
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/never-written.png")
        let gate = Pending<Void>()
        h.files.pending = gate
        let task = Task { await h.model.export(.save(url, overwriteConfirmed: false)) }
        await waitFor("file commit in progress") { gate.waiterCount == 1 }
        #expect(h.export.state == .committing)
        h.model.close()
        gate.resolve(())
        #expect(await task.value == .alreadyCompleted(.saved(url)))
        #expect(h.files.saves.count == 1)
        #expect(h.clipboard.writes.isEmpty)
        #expect(!h.export.isBusy)
    }

    @Test("Close after an upload committed reports that it already completed")
    func closeDuringUploadCompletion() async {
        let upload = LifecycleUpload()
        upload.suspension = .afterCommit
        let h = EditorHarness(upload: upload)
        configureUpload(h)
        let task = Task {
            await h.export.export(
                .upload(to: destination, intent: UUID()), session: h.model.session,
                currentSession: { h.model.isClosed ? nil : h.model.session })
        }
        await waitFor("upload already committed") { upload.gate.waiterCount == 1 }
        #expect(upload.writes == [h.model.document.id])
        h.model.close()
        upload.gate.resolve(())
        #expect(await task.value == .alreadyCompleted(.uploaded(upload.url)))
        #expect(upload.observedCancellation)
        #expect(upload.writes.count == 1)
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(!h.export.isBusy)
    }
}
