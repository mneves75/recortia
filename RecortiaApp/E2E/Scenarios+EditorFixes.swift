#if DEBUG
    import AppKit
    import Domain
    import Features
    import Foundation
    import Imaging
    import MacPlatform
    import RecortiaFixtures

    /// Regressions for the editor review fixes: notices (r4 P2), GitHub destination credentials
    /// (r3 F11), stale save-folder bookmarks (r3 F12), and drops that outlive the drag
    /// pasteboard (r4 P3).
    @MainActor
    enum EditorFixScenarios {
        // MARK: Notices

        static func notices(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await harness.openImported(harness.desktop, name: "notices.png")
            let model = controller.model
            let root = try context.unwrap("editor content", controller.contentRoot)
            let delay = Duration.milliseconds(250)
            var announcements: [String] = []
            let previousDelay = EditorNoticePresentation.autoDismissDelay
            let previousAnnounce = EditorNoticePresentation.announce
            EditorNoticePresentation.autoDismissDelay = delay
            EditorNoticePresentation.announce = { announcements.append($0) }
            defer {
                EditorNoticePresentation.autoDismissDelay = previousDelay
                EditorNoticePresentation.announce = previousAnnounce
            }
            let linkURL = try context.unwrap(
                "fixture URL", URL(string: "https://github.com/fixture/private-captures/blob/main/screenshots/a.png"))

            // A success-only notice is announced and still dismisses itself.
            model.reportAutomaticExport(.copied)
            let copied = EditorStrings.message(.exported(.copied))
            context.check(
                "a success notice is announced", await E2EWait.until { announcements.contains(copied) },
                "announced: \(announcements)")
            context.check(
                "a success notice dismisses itself after the delay", await E2EWait.until { model.notice == nil })

            // Failures stay until the person dismisses them, and say so to VoiceOver.
            let failures: [(String, ExportOutcome)] = [
                ("failed export", .failed(.diskFull)),
                ("upload completion unknown", .failed(.upload(.completionUnknown))),
            ]
            for (name, outcome) in failures {
                announcements.removeAll()
                model.reportAutomaticExport(outcome)
                let text = EditorStrings.message(.exported(outcome))
                context.check(
                    "\(name): announced", await E2EWait.until { announcements.contains(text) },
                    "announced: \(announcements)")
                try? await Task.sleep(for: delay * 6)
                context.check("\(name): stays past the delay", model.notice == .exported(outcome))
                if name == "failed export" {
                    await E2ESnapshot.settle(root)
                    context.snapshot(root, shot: "failure-notice")
                }
                model.dismissNotice()
                context.check("\(name): dismissing clears the notice", model.notice == nil)
            }

            // A real failure path (not a synthetic report) behaves the same way.
            announcements.removeAll()
            let missing = harness.output.workDirectory.appending(path: "no-such-image.png")
            let added = await model.addImageLayer(from: .file(missing))
            let importText = EditorStrings.message(.importFailed(.unreadable))
            context.check(
                "a failed layer import posts a failure", !added && model.notice == .importFailed(.unreadable),
                "\(String(describing: model.notice))")
            context.check(
                "a failed layer import is announced", await E2EWait.until { announcements.contains(importText) },
                "announced: \(announcements)")
            try? await Task.sleep(for: delay * 6)
            context.check("a failed layer import stays past the delay", model.notice == .importFailed(.unreadable))
            model.dismissNotice()

            // A notice that carries the uploaded-URL link stays so the link remains usable.
            announcements.removeAll()
            model.reportAutomaticExport(.uploaded(linkURL))
            let uploaded = EditorStrings.message(.exported(.uploaded(linkURL)))
            context.check(
                "uploaded: announced", await E2EWait.until { announcements.contains(uploaded) },
                "announced: \(announcements)")
            try? await Task.sleep(for: delay * 6)
            context.check(
                "uploaded: stays so the GitHub link stays usable", model.notice == .exported(.uploaded(linkURL)))
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "uploaded-link")

            // A newer notice replaces a sticky one and is announced in turn.
            announcements.removeAll()
            model.reportAutomaticExport(.copied)
            context.check(
                "a newer success notice replaces the sticky one and is announced",
                await E2EWait.until { announcements.contains(copied) })
            context.check(
                "the replacing success notice dismisses itself", await E2EWait.until { model.notice == nil })
        }

        // MARK: GitHub destination credentials

        /// Records every Keychain call a Settings save makes, in order, without a real Keychain.
        @MainActor
        final class RecordingCredentials: GitHubCredentialService {
            private(set) var tokens: [String: String] = [:]
            private(set) var calls: [String] = []
            var failNextStore = false
            var failNextRemove = false

            func store(_ token: String, for destination: GitHubDestination) throws(GitHubUploadFailure) {
                let account = GitHubTokenStore.account(for: destination)
                calls.append("store \(account)")
                if failNextStore {
                    failNextStore = false
                    throw .credentialsUnavailable
                }
                tokens[account] = token
            }

            func remove(for destination: GitHubDestination) throws(GitHubUploadFailure) {
                let account = GitHubTokenStore.account(for: destination)
                calls.append("remove \(account)")
                if failNextRemove {
                    failNextRemove = false
                    throw .credentialsUnavailable
                }
                tokens[account] = nil
            }
        }

        static func githubDestination(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let settings = harness.settings
            let credentials = RecordingCredentials()
            let first = GitHubDestination(owner: "fixture", repository: "private-one")
            let second = GitHubDestination(owner: "fixture", repository: "private-two")
            func save(_ token: String, _ destination: GitHubDestination) -> GitHubDestinationSaver.Result {
                GitHubDestinationSaver.save(
                    token: token, destination: destination, settings: settings, credentials: credentials)
            }

            context.check(
                "the first save succeeds, trimming a pasted token", save("  ghp_one\n", first) == .saved)
            context.check(
                "the stored token has no surrounding whitespace",
                credentials.tokens[GitHubTokenStore.account(for: first)] == "ghp_one",
                "stored: \(credentials.tokens)")
            context.check(
                "the first destination is saved", settings.preferences.githubUpload?.destination == first)
            context.check("the first save removes nothing", !credentials.calls.contains { $0.hasPrefix("remove") })

            context.check("changing the destination succeeds", save("ghp_two", second) == .saved)
            context.check(
                "the new destination is saved with automatic upload off",
                settings.preferences.githubUpload == GitHubUploadPreferences(destination: second))
            context.check(
                "the previous destination's token is removed after the new one is stored",
                credentials.calls.suffix(2) == ["store fixture/private-two", "remove fixture/private-one"],
                "calls: \(credentials.calls)")
            context.check(
                "only the new destination keeps a token",
                credentials.tokens == [GitHubTokenStore.account(for: second): "ghp_two"],
                "stored: \(credentials.tokens)")

            // The same Keychain item under another spelling is not a change: removing it would
            // delete the token that was just stored.
            let respelled = GitHubDestination(owner: "Fixture", repository: "Private-Two")
            let callsBefore = credentials.calls.count
            context.check("re-saving with other letter case succeeds", save("ghp_three", respelled) == .saved)
            context.check(
                "other letter case removes nothing",
                !credentials.calls.dropFirst(callsBefore).contains { $0.hasPrefix("remove") },
                "calls: \(credentials.calls)")
            context.check(
                "the token for the respelled destination survives",
                credentials.tokens[GitHubTokenStore.account(for: second)] == "ghp_three")

            // A failed store leaves the saved destination and its token alone.
            credentials.failNextStore = true
            let before = credentials.calls.count
            let failed = save("ghp_four", first)
            context.check("a failed store reports the failure", failed == .failed(.credentialsUnavailable), "\(failed)")
            context.check(
                "a failed store keeps the saved destination",
                settings.preferences.githubUpload?.destination == respelled)
            context.check(
                "a failed store removes nothing",
                !credentials.calls.dropFirst(before).contains { $0.hasPrefix("remove") })

            // A failed removal still saves the destination and says the old token remains.
            credentials.failNextRemove = true
            let stale = save("ghp_five", first)
            context.check(
                "a failed removal is reported", stale == .savedWithStaleCredential(.credentialsUnavailable), "\(stale)")
            context.check(
                "a failed removal still saves the destination", settings.preferences.githubUpload?.destination == first)

            // A token that is only whitespace never reaches the Keychain.
            let calls = credentials.calls.count
            context.check(
                "a whitespace-only token is a missing credential", save(" \n\t", second) == .failed(.missingCredential))
            context.check("a whitespace-only token makes no Keychain call", credentials.calls.count == calls)
        }

        // MARK: Stale save-folder bookmarks

        static func staleFolderBookmark(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let fileManager = FileManager.default
            let run = UUID().uuidString.prefix(8)
            let original = harness.output.workDirectory.appending(
                path: "folder-\(run)-before", directoryHint: .isDirectory)
            let renamed = harness.output.workDirectory.appending(
                path: "folder-\(run)-after", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: original, withIntermediateDirectories: true)
            let bookmark = try original.bookmarkData()
            try fileManager.moveItem(at: original, to: renamed)

            // Premise: macOS finds the renamed folder but reports the bookmark stale.
            var isStale = false
            let resolved = try URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            try context.require("the renamed folder's bookmark is stale", isStale)
            try context.require(
                "the stale bookmark still finds the renamed folder",
                resolved.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path, resolved.path)

            // A resolver with no settings: it must accept the folder and offer a renewed bookmark.
            var renewals: [(stale: Data, fresh: Data)] = []
            let folders = LiveSaveFolders { renewals.append(($0, $1)) }
            let url = folders.resolveFolder(bookmark: bookmark)
            context.check(
                "a stale bookmark resolves to the renamed folder",
                url?.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path,
                url?.path ?? "nil")
            context.check("the stale bookmark is offered for renewal", await E2EWait.until { renewals.count == 1 })
            if let fresh = renewals.first?.fresh {
                var freshIsStale = true
                let again = try? URL(
                    resolvingBookmarkData: fresh, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                    bookmarkDataIsStale: &freshIsStale)
                context.check(
                    "the renewed bookmark resolves and is no longer stale",
                    !freshIsStale && again?.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
                var quiet = 0
                let second = LiveSaveFolders { _, _ in quiet += 1 }
                context.check("a current bookmark resolves", second.resolveFolder(bookmark: fresh) != nil)
                try? await Task.sleep(for: .milliseconds(100))
                context.check("a current bookmark is not renewed", quiet == 0)
            }

            // The app's own resolver renews the stored preference.
            harness.settings.update { $0.preferredSaveFolderBookmark = bookmark }
            let live = harness.services.folders.resolveFolder(bookmark: bookmark)
            context.check("the app resolver accepts the stale bookmark", live != nil)
            context.check(
                "the app resolver renews the stored bookmark",
                await E2EWait.until { harness.settings.preferences.preferredSaveFolderBookmark != bookmark })

            // Saving to the preferred folder works through the stale bookmark.
            harness.settings.update { $0.preferredSaveFolderBookmark = bookmark }
            let controller = try await harness.openImported(harness.desktop, name: "stale-folder.png")
            let outcome = await controller.model.export(.saveToPreferredFolder)
            if case .saved(let saved) = outcome {
                context.check(
                    "Save to Preferred Folder writes into the renamed folder",
                    saved.deletingLastPathComponent().resolvingSymlinksInPath().path
                        == renamed.resolvingSymlinksInPath().path && fileManager.fileExists(atPath: saved.path),
                    saved.path)
            } else {
                context.check("Save to Preferred Folder succeeds through a stale bookmark", false, "\(outcome)")
            }

            // A folder that is gone is still unavailable and is never renewed.
            let gone = harness.output.workDirectory.appending(path: "folder-\(run)-gone", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: gone, withIntermediateDirectories: true)
            let goneBookmark = try gone.bookmarkData()
            try fileManager.removeItem(at: gone)
            renewals.removeAll()
            context.check("a deleted folder is unavailable", folders.resolveFolder(bookmark: goneBookmark) == nil)
            try? await Task.sleep(for: .milliseconds(100))
            context.check("a deleted folder is not renewed", renewals.isEmpty)
        }

        // MARK: Drops that outlive the drag pasteboard

        /// A drop is performed once; the drag pasteboard may change or clear as soon as
        /// `performDragOperation` returns, so the import must already hold what it needs.
        static func dropOutlivesPasteboard(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await harness.openImported(harness.desktop, name: "drop-base.png")
            let model = controller.model
            let canvas = try context.unwrap("real editor canvas", controller.canvasView)
            let png = try E2EDrawing.png(harness.desktop)
            let fileURL = harness.output.workDirectory.appending(path: "drop-file.png")
            try png.write(to: fileURL, options: .atomic)

            // A dropped file: its URL is captured while the drop is performed.
            let fileBoard = NSPasteboard.withUniqueName()
            defer { fileBoard.releaseGlobally() }
            try context.require(
                "a file URL is placed on the private drag pasteboard", fileBoard.writeObjects([fileURL as NSURL]))
            let fileDrag = SyntheticCanvasDrag(pasteboard: fileBoard, window: controller.window)
            let layersBefore = model.document.layers.count
            context.check("the file drop is accepted", canvas.performDragOperation(fileDrag))
            fileBoard.clearContents()
            fileBoard.setString("cleared", forType: .string)
            context.check(
                "a file drop still adds a layer after the pasteboard is cleared",
                await E2EWait.until { model.document.layers.count == layersBefore + 1 },
                "layers: \(model.document.layers.count), notice: \(String(describing: model.notice))")

            // Dropped image bytes: read while the drop is performed, only once admission is possible.
            let provider = SyntheticDropDataProvider(png: png)
            let dataBoard = NSPasteboard.withUniqueName()
            defer { dataBoard.releaseGlobally() }
            let item = NSPasteboardItem()
            try context.require("PNG data is promised", item.setDataProvider(provider, forTypes: [.png]))
            try context.require("the PNG promise is placed on the drag pasteboard", dataBoard.writeObjects([item]))
            let dataDrag = SyntheticCanvasDrag(pasteboard: dataBoard, window: controller.window)
            context.check("hover accepts PNG data", canvas.draggingEntered(dataDrag) == .copy)
            context.check("hover requests no bytes", provider.dataRequests == 0)
            let before = model.document.layers.count
            context.check("the data drop is accepted", canvas.performDragOperation(dataDrag))
            dataBoard.clearContents()
            dataBoard.setString("cleared", forType: .string)
            context.check(
                "a data drop still adds a layer after the pasteboard is cleared",
                await E2EWait.until { model.document.layers.count == before + 1 },
                "layers: \(model.document.layers.count), notice: \(String(describing: model.notice))")
            context.check(
                "the data was requested once", provider.dataRequests == 1, "requests: \(provider.dataRequests)")

            // While another import holds the slot, a drop reads nothing and reports busy.
            let busyProvider = SyntheticDropDataProvider(png: png)
            let busyBoard = NSPasteboard.withUniqueName()
            defer { busyBoard.releaseGlobally() }
            let busyItem = NSPasteboardItem()
            try context.require("busy PNG data is promised", busyItem.setDataProvider(busyProvider, forTypes: [.png]))
            try context.require("the busy promise is placed", busyBoard.writeObjects([busyItem]))
            let input = harness.importInput
            input.holdNextRead = true
            defer { input.release() }
            let holder = Task { await model.addImageLayer(from: .file(fileURL)) }
            try context.require("another import holds the slot", await E2EWait.until { input.isWaiting })
            let serial = model.noticeSerial
            _ = canvas.performDragOperation(SyntheticCanvasDrag(pasteboard: busyBoard, window: controller.window))
            busyBoard.clearContents()
            context.check(
                "a busy drop reports busy",
                await E2EWait.until { model.noticeSerial > serial && model.notice == .importFailed(.busy) })
            context.check(
                "a busy drop requests no bytes", busyProvider.dataRequests == 0,
                "requests: \(busyProvider.dataRequests)")
            input.release()
            _ = await holder.value
        }
    }
#endif
