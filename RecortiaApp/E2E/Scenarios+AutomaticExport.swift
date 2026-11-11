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
        private(set) var snapshotCount = 0

        init(exporter: any ExportService) { self.exporter = exporter }

        func makeSnapshot(of session: DocumentSession, options: ExportOptions, date: Date)
            async throws(ExportServiceError) -> ShareSnapshot
        {
            snapshotCount += 1
            if holdNextSnapshot {
                holdNextSnapshot = false
                await withCheckedContinuation { waiter = $0 }
            }
            return try await exporter.makeSnapshot(of: session, options: options, date: date)
        }

        func makeSnapshot(
            ofPinned image: CGImage, exportID: DocumentID, privacyEpoch: UInt64, options: ExportOptions, date: Date
        ) async throws(ExportServiceError) -> ShareSnapshot {
            snapshotCount += 1
            return try await exporter.makeSnapshot(
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
                await E2EWait.until { busyEditor.model.notice == .automaticExportFailed(.busy) },
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

            // The batch is decided when the capture completes: a main-actor job queued right after
            // `handleCapture` returns (here, turning automatic save on) must not join this capture.
            // The folder is authorized again: the reset above cleared it, which would hide a save.
            harness.settings.update {
                $0.preferredSaveFolderBookmark = bookmark; $0.autoCopy = true; $0.autoSave = false
            }
            let wired = harness.features.capture.onCaptured
            harness.features.capture.onCaptured = { [weak app = harness.app, settings = harness.settings] completion in
                app?.handleCapture(completion)
                settings.update { $0.autoSave = true }
            }
            defer { harness.features.capture.onCaptured = wired }
            let copies = harness.clipboard.writeCount
            let renders = harness.exportGate.snapshotCount
            let savedBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            try context.require(
                "frozen batch: the automatic copy chosen at capture runs",
                await E2EWait.until { harness.clipboard.writeCount == copies + 1 && !harness.features.export.isBusy })
            let savedAfter = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            context.check(
                "frozen batch: automatic save turned on right after the capture does not save it",
                savedAfter == savedBefore, "\(savedAfter)")
            context.check(
                "frozen batch: only the copy rendered", harness.exportGate.snapshotCount == renders + 1,
                "\(harness.exportGate.snapshotCount - renders) renders")
            harness.settings.update {
                $0.autoCopy = false; $0.autoSave = false
            }
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

            // The pipeline is the one admission point for export options: refused options reach
            // the coordinator through the live exporter as the encode failure it always reported.
            let exporter = LiveExporter(store: ImageStore())
            let pixel = try E2EDrawing.image(size: CGSize(width: 4, height: 4), scale: 1) { rect in
                NSColor.gray.setFill()
                rect.fill()
            }
            let refused: [(String, ExportOptions)] = [
                ("scale", ExportOptions(format: .png, scale: 2)),
                ("quality", ExportOptions(format: .jpeg(quality: .nan), scale: 1)),
            ]
            for (label, options) in refused {
                var failure: ExportFailure?
                do {
                    _ = try await exporter.makeSnapshot(
                        ofPinned: pixel, exportID: DocumentID(), privacyEpoch: 0, options: options, date: Date())
                } catch {
                    failure = error.failure
                }
                context.check(
                    "invalid \(label) options are refused as an encode failure", failure == .encodeFailed,
                    "\(String(describing: failure))")
            }
            context.check(
                "every refused-options reason maps to the encode failure",
                [ExportOptionsError.invalidScale, .invalidQuality, .translucentJPEGBackground].allSatisfy {
                    LiveExporter.failure(for: .invalidOptions($0)) == .encodeFailed
                })

            // An alert reports one failed step of a batch whose other steps may have written: its
            // title must not say that nothing was exported (copy succeeds, save fails).
            let denials: Set<String> = ["Nothing was exported", "Nada foi exportado"]
            let failures: [ExportFailure] = [
                .busy, .renderFailed, .encodeFailed, .budgetExceeded, .clipboardFailed, .accessDenied,
                .destinationExists, .diskFull, .volumeUnavailable, .staleDocument, .system(code: 5),
                .upload(.missingCredential),
            ]
            let titles = failures.map { "\($0): \(UserMessage.export($0).title)" }
            let denying = zip(failures, titles).filter { denials.contains(UserMessage.export($0.0).title) }
            context.check(
                "no automatic-export alert title denies the batch's earlier writes", denying.isEmpty,
                denying.map(\.1).joined(separator: "; "))
            let unknown = UserMessage.export(.upload(.completionUnknown)).title
            let checkGitHub = String(localized: "Check the GitHub upload")
            context.check(
                "an upload whose completion is unknown still asks to check GitHub", unknown == checkGitHub, unknown)

            // The editor route (R-2): a batch with one failure shows it as the editor notice, and
            // that notice must not deny the batch's earlier writes either. It says what the alert says.
            let editor = try await harness.openImported(harness.desktop, name: "feedback-routing.png")
            defer { editor.window?.close() }
            let editorDenials = denials.union(["Nothing was saved", "Nada foi salvo"])
            var denied: [String] = [], unlike: [String] = []
            for failure in failures + [.upload(.completionUnknown)] {
                editor.model.reportAutomaticExport(.failed(failure))
                let text = editor.model.notice.map(EditorStrings.message) ?? ""
                if editorDenials.contains(where: { text.contains($0) }) { denied.append("\(failure): \(text)") }
                if !text.hasPrefix(UserMessage.export(failure).title) { unlike.append("\(failure): \(text)") }
                editor.model.dismissNotice()
            }
            context.check(
                "no automatic-export editor notice denies the batch's earlier writes", denied.isEmpty,
                denied.joined(separator: "; "))
            context.check(
                "an automatic-export editor notice starts with the alert's title", unlike.isEmpty,
                unlike.joined(separator: "; "))
            // A manual export is one write: when it fails, saying nothing was saved is true and stays.
            let manual = EditorStrings.message(.exported(.failed(.diskFull)))
            context.check(
                "a failed manual save still says nothing was saved",
                manual == String(localized: "Nothing was saved: the disk is full.", table: "Editor"), manual)
        }
    }
#endif
