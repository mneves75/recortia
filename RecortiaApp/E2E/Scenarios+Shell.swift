#if DEBUG
    import AppKit
    import Domain
    import Features
    import SwiftUI

    /// App shell: first launch, the menu-bar menu, and Settings (FR-01, FR-14).
    @MainActor
    enum ShellScenarios {
        static func onboarding(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let onboarding = harness.app.onboarding
            context.check("fresh settings present onboarding", onboarding.shouldPresent)
            context.check(
                "starts on the local-processing step", onboarding.step == .localProcessing, "\(onboarding.step)")
            let view = OnboardingView(onboarding: onboarding, shortcutStatus: harness.app.shortcutStatus, onClose: {})
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            E2ESnapshot.park(window)
            defer { window.close() }
            let root = try context.unwrap("onboarding window has content", window.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "local-processing")

            onboarding.next()
            context.check("Continue moves to shortcuts", onboarding.step == .shortcuts, "\(onboarding.step)")
            context.check("Back is available on the shortcuts step", onboarding.canGoBack)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "shortcuts")

            onboarding.finish()
            context.check("Done completes onboarding", harness.settings.preferences.hasCompletedOnboarding)
            context.check("onboarding is not shown again", !onboarding.shouldPresent)
            context.check(
                "onboarding requested no Screen Recording permission", harness.permission.requestCount == 0,
                "requests: \(harness.permission.requestCount)")
        }

        static func menu(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            let expected: [AppCommand: Bool] = [
                .captureRegion: true, .captureDisplay: true, .captureWindow: true, .captureWithDelay: true,
                .repeatLastRegion: false, .scrollingCapture: true, .captureText: true, .captureMenu: true,
                .openImage: true,
                .pasteImage: true, .bringPinsForward: false, .closeAllPins: false, .settings: true, .about: true,
                .quit: true,
            ]
            for command in AppCommand.allCases {
                let enabled = app.isEnabled(command)
                context.check(
                    "\(command.rawValue) is \(expected[command] == true ? "enabled" : "disabled")",
                    enabled == expected[command], "isEnabled == \(enabled)")
            }
            let titles = AppCommand.allCases.map(\.title)
            context.check(
                "every command has a distinct localized title", Set(titles).count == titles.count,
                titles.joined(separator: " | "))

            let menu = VStack(alignment: .leading, spacing: 2) {
                MenuContent(model: app)
            }
            .buttonStyle(.plain)
            .padding(10)
            .frame(width: 300, alignment: .leading)
            let window = E2ESnapshot.host(menu)
            defer { window.close() }
            let root = try context.unwrap("menu content hosted", window.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root)
        }

        /// Quit asks before discarding edits that were never exported (FR-04). Window close already
        /// asks; termination never calls `windowShouldClose`, so it needs its own check.
        static func quitConfirmation(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            harness.quit.answers = []
            context.check("with no editor, Quit proceeds", app.shouldTerminate())
            context.check("with no editor, Quit asks nothing", harness.quit.questions.isEmpty)

            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check("an unedited capture does not block Quit", app.shouldTerminate())
            context.check("an unedited capture asks nothing", harness.quit.questions.isEmpty)

            E2EActions.drag(controller.model, .arrow, from: E2EActions.point(100, 700), to: E2EActions.point(500, 420))
            try context.require("the edit makes the document dirty", controller.model.isDirty)
            harness.quit.answers = [false]
            context.check("declining keeps Recortia running", !app.shouldTerminate())
            context.check(
                "Quit asks once about one edited image", harness.quit.questions == [1], "\(harness.quit.questions)")
            context.check("declining keeps the edits", controller.model.isDirty && !controller.model.isClosed)
            harness.quit.answers = [true]
            context.check("confirming lets Recortia quit", app.shouldTerminate())

            harness.quit.questions = []
            let copied = await E2EActions.export(controller, .copy)
            try context.require("Copy succeeds", copied == .copied, "\(copied)")
            context.check("exported edits do not block Quit", app.shouldTerminate())
            context.check("exported edits ask nothing", harness.quit.questions.isEmpty)
        }

        static func settings(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let preferences = harness.settings.preferences
            context.check("automatic copy is off by default", !preferences.autoCopy)
            context.check("automatic save is off by default", !preferences.autoSave)
            context.check("automatic upload is off by default", preferences.githubUpload?.automatic != true)
            context.check("update checks are off by default", !preferences.updateChecksEnabled)
            context.check("automatic scrolling is off by default", !preferences.automaticScrollingEnabled)
            context.check("export defaults to PNG at 100%", preferences.exportOptions == ExportOptions())

            let window = SettingsWindowController.makeWindow(model: harness.app)
            window.appearance = NSAppearance(named: .aqua)
            E2ESnapshot.park(window)
            window.setContentSize(NSSize(width: 560, height: 540))
            defer { window.close() }
            let root = try context.unwrap("settings window has content", window.contentView)
            await E2ESnapshot.settle(root)

            let tabs = [
                "general", "shortcuts", "capture", "export", "github", "privacy", "text-recognition", "pins",
                "scrolling",
            ]
            if let tabView = EditorWindowController.first(NSTabView.self, in: root) {
                context.check(
                    "Settings has one tab per area", tabView.numberOfTabViewItems == tabs.count,
                    "\(tabView.numberOfTabViewItems) tabs")
                for (index, name) in tabs.enumerated() where index < tabView.numberOfTabViewItems {
                    tabView.selectTabViewItem(at: index)
                    if name == "text-recognition" {
                        let loaded = await E2EWait.until {
                            if case .loaded = harness.features.ocrLanguages.state { return true }
                            return false
                        }
                        context.check(
                            "OCR languages load at runtime", loaded, "\(harness.features.ocrLanguages.state)")
                    }
                    await E2ESnapshot.settle(root, for: .milliseconds(400))
                    // The tab's own content: the toolbar tab strip belongs to the window and does
                    // not render offscreen.
                    context.snapshot(tabView.selectedTabViewItem?.view ?? root, shot: name)
                }
            } else {
                context.check("Settings exposes an AppKit tab view", false, "no NSTabView in the hosted hierarchy")
            }
        }
    }
#endif
