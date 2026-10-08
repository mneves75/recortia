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

        func makeSnapshot(
            ofPinned image: CGImage, exportID: DocumentID, privacyEpoch: UInt64, options: ExportOptions, date: Date
        ) async throws(ExportServiceError) -> ShareSnapshot {
            try await exporter.makeSnapshot(
                ofPinned: image, exportID: exportID, privacyEpoch: privacyEpoch, options: options, date: date)
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
        var holdBeforeCommit = false
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
            if holdBeforeCommit {
                holdBeforeCommit = false
                await withCheckedContinuation { waiter = $0 }
            }
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
            let messagesBefore = harness.messages.values.count
            let busyEditor = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check(
                "busy automatic export shows a failure in the new capture's editor",
                await E2EWait.until { busyEditor.model.notice == .exported(.failed(.busy)) },
                "\(String(describing: busyEditor.model.notice))")
            context.check(
                "an automatic-export failure with an editor open raises no modal alert",
                harness.messages.values.count == messagesBefore, "\(harness.messages.values)")
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

            for change in ["opt-out", "destination", "reset", "unrelated"] {
                harness.github.holdBeforeCommit = true
                let before = harness.github.snapshots.count
                _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
                try context.require(
                    "\(change): upload waits before the write", await E2EWait.until { harness.github.isWaiting })
                switch change {
                case "opt-out": harness.settings.update { $0.githubUpload?.automatic = false }
                case "destination":
                    harness.settings.update {
                        $0.githubUpload?.destination = GitHubDestination(owner: "fixture", repository: "other-private")
                    }
                case "reset": harness.settings.resetToDefaults()
                default: harness.settings.update { $0.jpegQuality = 0.75 }
                }
                harness.settings.update {
                    $0.githubUpload = GitHubUploadPreferences(destination: destination, automatic: true)
                }
                harness.github.release()
                try context.require(
                    "\(change): pending upload finishes", await E2EWait.until { !harness.features.export.isBusy })
                context.check(
                    "\(change): re-enabled consent cannot revive an old upload; unrelated settings are allowed",
                    harness.github.snapshots.count == before + (change == "unrelated" ? 1 : 0))
            }
            for copying in [false, true] {
                harness.settings.update { $0.autoCopy = copying }
                harness.exportGate.holdNextSnapshot = true
                let before = harness.github.snapshots.count
                _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
                try context.require(
                    "copy=\(copying): rendering waits before upload",
                    await E2EWait.until { harness.exportGate.isWaiting })
                harness.settings.update { $0.githubUpload?.automatic = false }
                harness.settings.update { $0.githubUpload?.automatic = true }
                harness.exportGate.release()
                try context.require(
                    "copy=\(copying): automatic batch finishes",
                    await E2EWait.until { !harness.features.export.isBusy })
                context.check(
                    "copy=\(copying): revocation during an earlier batch step prevents upload",
                    harness.github.snapshots.count == before)
            }
            harness.settings.update { $0.autoCopy = false }
            harness.settings.update { $0.githubUpload?.automatic = false }
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check("upload opt-out prevents additional sends", harness.github.snapshots.count == uploads + 3)
        }

        /// A batch's failures are never hidden behind another notice in the editor's single slot.
        static func feedbackRouting(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let url = try context.unwrap(
                "fixture URL", URL(string: "https://github.com/fixture/private/blob/main/a.png"))
            let uploaded = ExportOutcome.uploaded(url)
            func shown(_ route: (editorNotices: [ExportOutcome], alerts: [ExportFailure])) -> [String] {
                // The editor keeps only its last notice; every alert is shown.
                (route.editorNotices.last.map { ["\($0)"] } ?? []) + route.alerts.map { "alert \($0)" }
            }
            let single = AppModel.routeAutomaticExport([.failed(.diskFull)], editorOpen: true)
            context.check(
                "a lone failure becomes the editor notice",
                single.editorNotices == [.failed(.diskFull)] && single.alerts.isEmpty,
                "\(single)")
            let mixed = AppModel.routeAutomaticExport([.copied, .failed(.diskFull), uploaded], editorOpen: true)
            context.check(
                "a failure beside an upload is still shown", shown(mixed).contains { $0.contains("diskFull") },
                "\(shown(mixed))")
            context.check(
                "the upload link is still shown", shown(mixed).contains { $0.contains("uploaded") }, "\(shown(mixed))")
            let double = AppModel.routeAutomaticExport(
                [.failed(.diskFull), .failed(.clipboardFailed)], editorOpen: true)
            context.check(
                "two failures are both shown",
                shown(double).contains { $0.contains("diskFull") }
                    && shown(double).contains { $0.contains("clipboardFailed") },
                "\(shown(double))")
            let closed = AppModel.routeAutomaticExport([.failed(.diskFull)], editorOpen: false)
            context.check("without an editor a failure is an alert", closed.alerts == [.diskFull], "\(closed)")
        }
    }
#endif
