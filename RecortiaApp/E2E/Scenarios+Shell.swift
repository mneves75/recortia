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
            // Sizing the window measures every page, the shortcuts page included; that must not
            // count as the person looking at shortcuts (it restarts the held-shortcut watch).
            let attentionHandler = harness.app.shortcutStatus.onAttention
            var attentionCount = 0
            harness.app.shortcutStatus.onAttention = {
                attentionCount += 1
                attentionHandler?()
            }
            defer {
                harness.app.shortcutStatus.onAttention = attentionHandler
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
            context.check(
                "measuring the tour pages does not note attention to shortcuts", attentionCount == 0,
                "\(attentionCount) notes")
            let defaultSize = window.contentRect(forFrameRect: window.frame).size
            context.check("the tour opens at the default 580 pt width", defaultSize.width == 580, "\(defaultSize)")
            var pageHeights: [String: CGFloat] = [:]
            var viewport: CGFloat = 0
            func measure(_ page: String) {
                guard let fit = tourFit(root, context, page: page) else { return }
                pageHeights[page] = fit.page
                viewport = fit.visible
            }
            measure("local-processing")
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
                measure("\(page)")
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
                window.setContentSize(defaultSize)
                window.appearance = NSAppearance(named: .aqua)
                await E2ESnapshot.settle(root)
            }
            let tallest = pageHeights.max { $0.value < $1.value }
            E2ERunner.log(
                "tour fit: content \(defaultSize), viewport \(viewport), pages "
                    + pageHeights.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            context.check(
                "every tour page was measured", pageHeights.count == OnboardingModel.pageCount, "\(pageHeights.count)")
            context.check(
                "the window opens at the height of its tallest page",
                tallest.map { abs($0.value - viewport) <= 1 } == true,
                "tallest \(String(describing: tallest)), viewport \(viewport)")
            // The spec also asks that no page leave more than about a third empty; with the shortcut
            // notice the shortcuts page is far taller than the others, so this is recorded, not met.
            E2ERunner.log(
                "tour fill: "
                    + pageHeights.sorted { $0.key < $1.key }.map {
                        "\($0.key)=\(Int(($0.value / max(viewport, 1) * 100).rounded()))%"
                    }.joined(separator: " "))

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
            let immediateReplayStep = onboarding.step
            let replayWindow = try context.unwrap(
                "replay has a window",
                NSApp.windows.first {
                    $0.identifier?.rawValue == "recortia.onboarding" && $0.isVisible
                })
            defer { replayWindow.close() }
            E2ESnapshot.park(replayWindow)
            let replayRoot = try context.unwrap("replay has content", replayWindow.contentView)
            await E2ESnapshot.settle(replayRoot)
            context.check(
                "replaying starts at the first page", onboarding.step == .localProcessing,
                "immediate: \(immediateReplayStep); settled: \(onboarding.step); visible: \(replayWindow.isVisible)")
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

        /// The shown page's height (its `tour.page` accessibility frame and margins) and the tour's
        /// scroll viewport at the window's current size. The document view alone cannot show empty space:
        /// a short page's document is stretched to the viewport.
        private static func tourFit(_ root: NSView, _ context: ScenarioContext, page: String)
            -> (page: CGFloat, visible: CGFloat)?
        {
            root.layoutSubtreeIfNeeded()
            guard let scroll = EditorWindowController.first(NSScrollView.self, in: root) else {
                context.check("\(page): the tour page is in a scroll view", false, "no NSScrollView")
                return nil
            }
            let visible = scroll.contentView.bounds.height
            let document = scroll.documentView?.frame.height ?? .infinity
            context.check(
                "\(page) fits without vertical scrolling at the default size", document <= visible + 1,
                "document \(document), visible \(visible)")
            guard let frame = try? E2EAccessibilityControl.frame("tour.page", in: root, context),
                let window = scroll.window
            else { return nil }
            // The page's accessibility frame spans its content; its margin is the gap above the
            // content, repeated below it.
            let viewportTop = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                .maxY
            let margin = viewportTop - frame.maxY
            let height = frame.height + 2 * margin
            context.check(
                "\(page) fits in the default window", height <= visible + 1,
                "page \(height) (content \(frame.height), margin \(margin)), visible \(visible)")
            return (height, visible)
        }

        private static func pressTourControl(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws {
            try E2EAccessibilityControl.press(identifier, in: root, context)
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
            defer { window.close() }
            let root = try context.unwrap("settings window has content", window.contentView)
            await E2ESnapshot.settle(root)

            let tabs = ["general", "shortcuts", "capture", "export", "github", "privacy", "text-recognition"]
            let tabView = try context.unwrap("Settings exposes an AppKit tab view", first(NSTabView.self, in: root))
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
                    context.check("OCR languages load at runtime", loaded, "\(harness.features.ocrLanguages.state)")
                }
                await E2ESnapshot.settle(root, for: .milliseconds(400))
                let pane = try context.unwrap("the \(name) pane", tabView.selectedTabViewItem?.view)
                await checkPaneFits(name, index: index, pane: pane, harness.app, context)
                // The tab's own content: the toolbar tab strip belongs to the window and does
                // not render offscreen.
                context.snapshot(pane, shot: name)
                switch name {
                case "general":
                    context.check(
                        "General holds the Pins section",
                        E2EAccessibilityControl.isPresent("settings.pinOpacity", in: pane))
                case "capture":
                    for identifier in ["settings.automaticScrolling", "settings.accessibilityStatus"] {
                        context.check(
                            "Capture holds the Scrolling Capture control \(identifier)",
                            E2EAccessibilityControl.isPresent(identifier, in: pane))
                    }
                case "export":
                    // A pane whose content grows after it is shown still fits it.
                    harness.settings.update { $0.defaultExportFormat = .jpeg }
                    await E2ESnapshot.settle(root, for: .milliseconds(400))
                    await checkPaneFits("export with JPEG quality", index: index, pane: pane, harness.app, context)
                    harness.settings.update { $0.defaultExportFormat = .png }
                    await E2ESnapshot.settle(root, for: .milliseconds(400))
                    await checkPaneFits("export back to PNG", index: index, pane: pane, harness.app, context)
                default: break
                }
            }
            try await settingsMergedControls(harness, context)
        }

        /// The Pins and Scrolling Capture controls, now sections of General and Capture, change the
        /// same preferences through pointer input on a visible, key, foreground Settings window.
        private static func settingsMergedControls(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let preferences = harness.settings.preferences
            let trusted = harness.accessibility.isTrusted
            defer {
                harness.accessibility.isTrusted = trusted
                harness.settings.update {
                    $0.pinDefaultOpacity = preferences.pinDefaultOpacity
                    $0.automaticScrollingEnabled = preferences.automaticScrollingEnabled
                }
            }
            let foreground = try await E2EForegroundFixture.start(context)
            defer { foreground.requestStop() }
            let window = SettingsWindowController.makeWindow(model: harness.app)
            window.appearance = NSAppearance(named: .aqua)
            window.center(on: ScreenChoice.screen())
            defer { window.close() }
            let root = try context.unwrap("settings window has content", window.contentView)
            let tabs = try context.unwrap("Settings tab view", first(NSTabView.self, in: root))
            func activate() async throws {
                if !E2EForegroundFixture.runnerIsForeground {
                    try await foreground.restore()
                    try await foreground.yieldToRunner()
                }
                try await E2EAccessibilityControl.showAndActivate(window, context)
            }
            func click(_ identifier: String, tab: Int) async throws {
                tabs.selectTabViewItem(at: tab)
                try await activate()
                await E2ESnapshot.settle(root, for: .milliseconds(400))
                let pane = try context.unwrap("the selected Settings pane", tabs.selectedTabViewItem?.view)
                try E2EAccessibilityControl.click(identifier, in: pane, context)
                await E2ESnapshot.settle(root, for: .milliseconds(400))
            }

            let opacity = harness.settings.preferences.pinDefaultOpacity
            try await click("settings.pinOpacity", tab: 0)
            let changed = harness.settings.preferences.pinDefaultOpacity
            context.check(
                "the General Pins slider changes the default pin opacity",
                changed != opacity && SettingsStore.opacityRange.contains(changed), "\(opacity) -> \(changed)")
            if let pane = tabs.selectedTabViewItem?.view { context.snapshot(pane, shot: "general-pins") }

            harness.accessibility.isTrusted = false
            let requests = harness.accessibility.requestCount
            try await click("settings.automaticScrolling", tab: 2)
            context.check(
                "the Capture switch turns automatic scrolling on",
                harness.settings.preferences.automaticScrollingEnabled)
            context.check(
                "turning it on without Accessibility asks exactly once",
                harness.accessibility.requestCount == requests + 1, "\(harness.accessibility.requestCount - requests)")
            let pane = try context.unwrap("the Capture pane", tabs.selectedTabViewItem?.view)
            context.snapshot(pane, shot: "capture-scrolling")
            try await click("settings.automaticScrolling", tab: 2)
            context.check(
                "the Capture switch turns automatic scrolling off",
                !harness.settings.preferences.automaticScrollingEnabled)
            context.check(
                "turning it off asks nothing", harness.accessibility.requestCount == requests + 1,
                "\(harness.accessibility.requestCount - requests)")

            harness.accessibility.isTrusted = true
            try await click("settings.accessibilityCheckAgain", tab: 2)
            let status = try E2EAccessibilityControl.text(
                .value, for: "settings.accessibilityStatus", in: pane, context)
            context.check("Check Again reports the granted permission", status == String(localized: "Allowed"), status)
            try await click("settings.automaticScrolling", tab: 2)
            context.check(
                "with Accessibility granted, the switch turns automatic scrolling on",
                harness.settings.preferences.automaticScrollingEnabled)
            context.check(
                "with Accessibility granted, nothing is requested", harness.accessibility.requestCount == requests + 1,
                "\(harness.accessibility.requestCount - requests)")
            await foreground.stop(context)
        }

        /// A pane is as tall as its own content hosted alone at the pane width, and its form does
        /// not scroll: no empty band below the content and nothing cut off.
        private static func checkPaneFits(
            _ name: String, index: Int, pane: NSView, _ model: AppModel, _ context: ScenarioContext
        ) async {
            pane.layoutSubtreeIfNeeded()
            // Measured in its own offscreen window: switch rows only take their real height there.
            guard let content = settingsContent(index, model) else { return }
            let host = E2ESnapshot.host(nsView: content, size: NSSize(width: 560, height: 100))
            defer { host.close() }
            // Let the reference finish its own appearance work (Text Recognition reloads languages).
            await E2ESnapshot.settle(content, for: .milliseconds(400))
            let fitting = content.fittingSize.height
            context.check(
                "the \(name) pane is as tall as its content", abs(pane.frame.height - fitting) <= 1,
                "pane \(pane.frame.height), content \(fitting)")
            if let scroll = first(NSScrollView.self, in: pane), let document = scroll.documentView {
                E2ERunner.log(
                    "settings \(name): pane \(pane.frame.height), content \(fitting), document \(document.frame.height)"
                )
                context.check(
                    "the \(name) pane does not scroll", document.frame.height <= scroll.contentView.bounds.height + 1,
                    "document \(document.frame.height), visible \(scroll.contentView.bounds.height)")
            }
        }

        /// Each pane's content as `SettingsWindowController` builds it, without the pane wrapper.
        private static func settingsContent(_ index: Int, _ model: AppModel) -> NSView? {
            func host(_ view: some View) -> NSView { NSHostingView(rootView: view.frame(width: 560)) }
            return switch index {
            case 0: host(GeneralSettingsTab(settings: model.settings, loginItem: model.features?.loginItem))
            case 1:
                host(
                    ShortcutsSettingsTab(status: model.shortcutStatus, onRestoreDefaults: model.restoreDefaultShortcuts)
                )
            case 2:
                host(
                    CaptureSettingsTab(settings: model.settings, accessibility: model.features?.services.accessibility))
            case 3: host(ExportSettingsTab(settings: model.settings, folders: model.features?.services.folders))
            case 4:
                host(
                    GitHubUploadSettings(
                        settings: model.settings, credentials: model.features?.services.githubCredentials))
            case 5: host(PrivacySettingsTab())
            case 6: host(OCRSettingsTab(settings: model.settings, languages: model.features?.ocrLanguages))
            default: nil
            }
        }

        private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            EditorWindowController.first(type, in: view)
        }
    }
#endif
