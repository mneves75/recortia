#if DEBUG
    import AppKit
    import Domain
    import Features
    import Foundation
    import MacPlatform

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
    }
#endif
