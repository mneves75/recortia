#if DEBUG
    import AppKit
    import Domain
    import Features
    import Foundation

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
    }
#endif
