#if DEBUG
    import AppKit
    import Domain
    import Features
    import Foundation
    import Imaging
    import MacPlatform

    @MainActor
    final class SyntheticExportGate: ExportService {
        private let exporter: any ExportService
        var holdNextSnapshot = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { waiter != nil }

        init(exporter: any ExportService) { self.exporter = exporter }

        func makeSnapshot(of session: DocumentSession, options: ExportOptions, date: Date)
            async throws(ExportServiceError) -> ShareSnapshot
        {
            if holdNextSnapshot {
                holdNextSnapshot = false
                await withCheckedContinuation { waiter = $0 }
            }
            return try await exporter.makeSnapshot(of: session, options: options, date: date)
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }
    }

    /// Records only synthetic sanitized snapshots. Never uses network or Keychain.
    @MainActor
    final class SyntheticGitHubUpload: GitHubUploadService, GitHubCredentialService {
        var snapshots: [ShareSnapshot] = []
        var hasCredential = false
        var holdAfterCommit = false
        private var waiter: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { waiter != nil }

        func release() { waiter?.resume(); waiter = nil }

        func store(_ token: String, for destination: GitHubDestination) throws(GitHubUploadFailure) {
            guard token == "synthetic-token", destination.isValid else { throw .missingCredential }
            hasCredential = true
        }

        func remove(for destination: GitHubDestination) throws(GitHubUploadFailure) { hasCredential = false }

        func upload(
            _ snapshot: ShareSnapshot, to destination: GitHubDestination, intent: UUID,
            isCurrent: @escaping @MainActor @Sendable () -> Bool
        ) async throws(GitHubUploadFailure) -> URL {
            guard hasCredential else { throw .missingCredential }
            guard isCurrent() else { throw .staleDocument }
            snapshots.append(snapshot)
            if holdAfterCommit {
                holdAfterCommit = false
                await withCheckedContinuation { waiter = $0 }
            }
            guard
                let url = URL(string: "https://github.com/fixture/private-captures/blob/main/screenshots/\(intent).png")
            else {
                throw .invalidResponse
            }
            return url
        }
    }

    @MainActor
    enum AutomaticExportScenarios {
        static func regression(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let folder = harness.output.workDirectory.appending(path: "automatic-saves", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try folder.bookmarkData()
            harness.settings.update {
                $0.preferredSaveFolderBookmark = bookmark; $0.autoCopy = true; $0.autoSave = true
            }
            let count = harness.clipboard.writeCount
            harness.exportGate.holdNextSnapshot = true
            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            let waiting = await E2EWait.until { harness.exportGate.isWaiting }
            try context.require("automatic copy waits at the real pipeline boundary", waiting)
            controller.model.cancelExport()
            harness.exportGate.release()
            let finished = await E2EWait.until { !harness.features.export.isBusy }
            context.check("cancel completes the automatic batch", finished)
            context.check("cancel leaves clipboard untouched", harness.clipboard.writeCount == count)
            context.check(
                "cancel prevents automatic save",
                try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

            harness.settings.update { $0.autoSave = false }
            harness.exportGate.holdNextSnapshot = true
            let running = Task { await controller.model.export(.copy) }
            try context.require("manual export is busy", await E2EWait.until { harness.exportGate.isWaiting })
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check(
                "busy automatic export produces a visible failure",
                await E2EWait.until { harness.messages.values.contains(.export(.busy)) })
            harness.exportGate.release()
            _ = await running.value
            harness.settings.update { $0.autoCopy = false }

            let destination = GitHubDestination(owner: "fixture", repository: "private-captures")
            try harness.github.store("synthetic-token", for: destination)
            harness.settings.update {
                $0.githubUpload = GitHubUploadPreferences(destination: destination, automatic: true)
            }
            let uploads = harness.github.snapshots.count
            let uploaded = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            try context.require(
                "capture reaches the GitHub sink", await E2EWait.until { harness.github.snapshots.count == uploads + 1 }
            )
            let snapshot = try context.unwrap("sanitized upload snapshot exists", harness.github.snapshots.last)
            let decoded = try E2EActions.decode(snapshot.bytes, "upload PNG", context)
            context.check("upload contains freshly encoded PNG", decoded.width > 0 && snapshot.format == .png)
            context.check(
                "upload carries the capture document identity", snapshot.documentID == uploaded.model.document.id)
            await E2EActions.snapshotEditor(uploaded, context, shot: "github-upload")

            harness.github.holdAfterCommit = true
            let canceled = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            try context.require(
                "upload has committed before cancellation", await E2EWait.until { harness.github.isWaiting })
            canceled.model.cancelExport()
            harness.github.release()
            try context.require(
                "confirmed upload remains visible after cancellation",
                await E2EWait.until {
                    if case .exported(.alreadyCompleted(.uploaded)) = canceled.model.notice { return true }
                    return false
                })
            await E2EActions.snapshotEditor(canceled, context, shot: "github-completed-after-cancel")
            harness.settings.update { $0.githubUpload?.automatic = false }
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check("upload opt-out prevents additional sends", harness.github.snapshots.count == uploads + 2)
        }
    }
#endif
