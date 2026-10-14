#if DEBUG
    import AppKit
    import Domain
    import Features
    import KeyboardShortcuts
    import SwiftUI

    /// App shell: first launch, the menu-bar menu, and Settings (FR-01, FR-14).
    @MainActor
    enum ShellScenarios {
        static func onboarding(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let onboarding = harness.app.onboarding
            context.check("fresh settings present onboarding", onboarding.shouldPresent)
            context.check(
                "starts on the local-processing step", onboarding.step == .localProcessing, "\(onboarding.step)")
            let preferences = harness.settings.preferences
            let clipboardChanges = harness.clipboard.pasteboard.changeCount
            let textClipboardChanges = harness.textPasteboard.changeCount
            let originalShortcuts = ShortcutBinding.all.map { KeyboardShortcuts.getShortcut(for: $0.name) }
            let permissionGranted = harness.permission.isGranted
            let accessibilityTrusted = harness.accessibility.isTrusted
            harness.permission.isGranted = false
            harness.accessibility.isTrusted = false
            KeyboardShortcuts.setShortcut(.init(.f12, modifiers: [.control, .option]), for: .captureText)
            let shortcuts = ShortcutBinding.all.map { KeyboardShortcuts.getShortcut(for: $0.name) }
            defer {
                harness.permission.isGranted = permissionGranted
                harness.accessibility.isTrusted = accessibilityTrusted
                for (binding, shortcut) in zip(ShortcutBinding.all, originalShortcuts) {
                    KeyboardShortcuts.setShortcut(shortcut, for: binding.name)
                }
            }
            harness.app.perform(.featureTour)
            let window = try context.unwrap(
                "the tour command shows the real onboarding window",
                NSApp.windows.first { $0.identifier?.rawValue == "recortia.onboarding" && $0.isVisible })
            context.check("onboarding follows the active Space", window.collectionBehavior.contains(.moveToActiveSpace))
            context.check("onboarding supports fullscreen", window.collectionBehavior.contains(.fullScreenAuxiliary))
            E2ESnapshot.park(window)
            defer { window.close() }
            let root = try context.unwrap("onboarding window has content", window.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "local-processing")

            try pressTourControl("tour.next", in: root, context)
            await E2ESnapshot.settle(root)
            context.check("the unfinished tour progresses before closing", onboarding.step == .capture)
            window.close()
            context.check("closing an unfinished tour preserves first-run status", onboarding.shouldPresent)
            harness.app.perform(.featureTour)
            context.check("reopening an unfinished tour starts at the first page", onboarding.step == .localProcessing)
            await E2ESnapshot.settle(root)

            let pages: [OnboardingModel.Step] = [.capture, .editing, .recognition, .composition, .sharing, .shortcuts]
            for page in pages {
                try pressTourControl("tour.next", in: root, context)
                await E2ESnapshot.settle(root)
                context.check("Continue reaches \(page)", onboarding.step == page, "\(onboarding.step)")
                context.check(
                    "completion is not written at \(page)", !harness.settings.preferences.hasCompletedOnboarding)
                context.check("Back is available at \(page)", onboarding.canGoBack)
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "\(page)")
                window.setContentSize(NSSize(width: 540, height: 480))
                window.appearance = NSAppearance(named: .darkAqua)
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "\(page)-compact-dark")
                try pressTourControl("tour.back", in: root, context)
                await E2ESnapshot.settle(root)
                try pressTourControl("tour.next", in: root, context)
                await E2ESnapshot.settle(root)
                context.check("Back and Continue return to \(page)", onboarding.step == page)
                window.setContentSize(NSSize(width: 580, height: 640))
                window.appearance = NSAppearance(named: .aqua)
                await E2ESnapshot.settle(root)
            }

            harness.app.perform(.featureTour)
            context.check("repeating the command preserves the open page", onboarding.step == .shortcuts)
            context.check(
                "the tour owns one visible window",
                NSApp.windows.filter {
                    $0.identifier?.rawValue == "recortia.onboarding" && $0.isVisible
                }.count == 1)

            try pressTourControl("tour.done", in: root, context)
            context.check("Done completes onboarding", harness.settings.preferences.hasCompletedOnboarding)
            context.check("Done closes the tour window", !window.isVisible)
            context.check("onboarding is not shown again", !onboarding.shouldPresent)
            harness.settings.update {
                $0.autoCopy = true
                $0.autoSave = true
                $0.githubUpload = GitHubUploadPreferences(
                    destination: GitHubDestination(owner: "fixture", repository: "private-captures"), automatic: true)
            }
            let replayPreferences = harness.settings.preferences
            let consentID = harness.settings.githubUploadConsentID
            harness.app.perform(.featureTour)
            let replayWindow = try context.unwrap(
                "replay has a window",
                NSApp.windows.first {
                    $0.identifier?.rawValue == "recortia.onboarding" && $0.isVisible
                })
            defer { replayWindow.close() }
            E2ESnapshot.park(replayWindow)
            let replayRoot = try context.unwrap("replay has content", replayWindow.contentView)
            await E2ESnapshot.settle(replayRoot)
            context.check("replaying starts at the first page", onboarding.step == .localProcessing)
            context.check("replaying preserves completion", !onboarding.shouldPresent)
            try pressTourControl("tour.skip", in: replayRoot, context)
            context.check("Skip closes the replay window", !replayWindow.isVisible)
            context.check(
                "replay preserves export preferences and upload consent",
                harness.settings.preferences == replayPreferences)
            context.check(
                "replay preserves the original upload consent identity",
                harness.settings.githubUploadConsentID == consentID)
            context.check(
                "the tour preserves shortcut assignments",
                ShortcutBinding.all.map {
                    KeyboardShortcuts.getShortcut(for: $0.name)
                } == shortcuts)
            context.check(
                "the tour does not copy an image", harness.clipboard.pasteboard.changeCount == clipboardChanges)
            context.check("the tour does not start scrolling", harness.scrollFrames.startCount == 0)
            context.check("the tour does not upload", harness.github.snapshots.isEmpty)
            context.check("the tour does not capture", harness.capture.captures.isEmpty)
            context.check("the tour does not export any snapshot", harness.exportGate.snapshotCount == 0)
            context.check("the tour does not drag a file", harness.drag.deliveredFiles.isEmpty)
            context.check("the tour does not copy text", harness.textPasteboard.changeCount == textClipboardChanges)
            context.check("the tour does not request Accessibility", harness.accessibility.requestCount == 0)
            context.check(
                "onboarding requested no Screen Recording permission", harness.permission.requestCount == 0,
                "requests: \(harness.permission.requestCount)")
            var completedPreferences = preferences
            completedPreferences.hasCompletedOnboarding = true
            harness.settings.update { $0 = completedPreferences }
        }

        private static func pressTourControl(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws {
            let control = try context.unwrap("\(identifier) is accessible", tourControl(identifier, in: root))
            if let modern = control as? any NSAccessibilityProtocol {
                try context.require("\(identifier) responds to Press", modern.accessibilityPerformPress())
            } else {
                let window = try context.unwrap("tour control has a window", root.window)
                try context.require(
                    "tour control exposes its frame", control.responds(to: NSSelectorFromString("accessibilityFrame")))
                let value = try context.unwrap(
                    "tour control frame", control.value(forKey: "accessibilityFrame") as? NSValue)
                let frame = value.rectValue
                try context.require("tour control frame is nonempty", frame.width > 0 && frame.height > 0)
                let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try context.unwrap(
                        "tour mouse event",
                        NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    )
                    window.sendEvent(event)
                }
            }
        }

        private static func tourControl(_ identifier: String, in element: Any) -> NSObject? {
            guard let object = element as? NSObject else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                object.value(forKey: "accessibilityIdentifier") as? String == identifier
            {
                return object
            }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                let children = object.value(forKey: "accessibilityChildren") as? [Any]
            {
                for child in children {
                    if let control = tourControl(identifier, in: child) { return control }
                }
            }
            if let view = element as? NSView {
                for child in view.subviews {
                    if let control = tourControl(identifier, in: child) { return control }
                }
            }
            return nil
        }

        static func menu(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            let expected: [AppCommand: Bool] = [
                .captureRegion: true, .captureDisplay: true, .captureWindow: true, .captureWithDelay: true,
                .repeatLastRegion: false, .scrollingCapture: true, .captureText: true, .captureMenu: true,
                .openImage: true,
                .pasteImage: true, .bringPinsForward: false, .closeAllPins: false, .settings: true, .about: true,
                .featureTour: true, .quit: true,
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
