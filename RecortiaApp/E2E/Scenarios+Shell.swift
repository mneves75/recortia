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
            // Opening the tour shows its first page; only showing the shortcuts content counts as
            // the person looking at shortcuts (it restarts the held-shortcut watch).
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
                "opening the tour does not note attention to shortcuts", attentionCount == 0,
                "\(attentionCount) notes")
            let defaultSize = window.contentRect(forFrameRect: window.frame).size
            context.check(
                "the tour opens at the fixed default 580 × 615 pt", defaultSize == NSSize(width: 580, height: 615),
                "\(defaultSize)")
            context.check(
                "the tour keeps its 540 × 480 pt minimum", window.contentMinSize == NSSize(width: 540, height: 480),
                "\(window.contentMinSize)")
            context.check("the tour stays resizable", window.styleMask.contains(.resizable))
            var pageHeights: [String: CGFloat] = [:]
            var viewport: CGFloat = 0
            func measure(_ page: String) {
                guard let fit = tourFit(root, context, page: page) else { return }
                pageHeights[page] = fit.page
                viewport = fit.visible
            }
            measure("local-processing")
            context.snapshot(root, shot: "local-processing")
            await context.darkCompanion(root, in: window, shot: "local-processing", surface: "tour local-processing")

            try pressTourControl("tour.next", in: root, context)
            await E2ESnapshot.settle(root)
            context.check("the unfinished tour progresses before closing", onboarding.step == .capture)
            window.close()
            context.check("closing an unfinished tour preserves first-run status", onboarding.shouldPresent)
            harness.app.perform(.featureTour)
            context.check("reopening an unfinished tour starts at the first page", onboarding.step == .localProcessing)
            await E2ESnapshot.settle(root)

            // Five pages since T2: the recognition and composition lists merged into editing and sharing.
            let pages: [OnboardingModel.Step] = [.capture, .editing, .sharing, .shortcuts]
            context.check(
                "the tour has five pages", OnboardingModel.pageCount == 5, "\(OnboardingModel.pageCount) pages")
            for page in pages {
                try pressTourControl("tour.next", in: root, context)
                await E2ESnapshot.settle(root)
                context.check("Continue reaches \(page)", onboarding.step == page, "\(onboarding.step)")
                context.check(
                    "completion is not written at \(page)", !harness.settings.preferences.hasCompletedOnboarding)
                context.check("Back is available at \(page)", onboarding.canGoBack)
                await E2ESnapshot.settle(root)
                if page == .shortcuts {
                    // The tallest page is the shortcuts page while macOS holds the defaults.
                    context.check(
                        "the shortcuts page is measured while macOS holds the default shortcuts",
                        harness.app.shortcutStatus.isHoldingAny)
                }
                measure("\(page)")
                context.snapshot(root, shot: "\(page)")
                await context.darkCompanion(root, in: window, shot: "\(page)", surface: "tour \(page)")
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
            E2ERunner.log(
                "tour fit: content \(defaultSize), viewport \(viewport), pages "
                    + pageHeights.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            // Each page's own check (`tourFit`) asserts it fits the default window without scrolling.
            context.check(
                "every tour page was measured at the default size", pageHeights.count == OnboardingModel.pageCount,
                "\(pageHeights.count)")
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
                .pasteImage: true, .reopenClosedCapture: false, .bringPinsForward: false, .closeAllPins: false,
                .unlockAllPins: false,
                .settings: true, .about: true,
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
            await context.darkHosted(menu, light: root, shot: nil, surface: "menu")
        }

        /// Quit asks before discarding edits that were never exported (FR-04). Window close already
        /// asks; termination never calls `windowShouldClose`, so it needs its own check.
        static func quitConfirmation(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            harness.quit.answers = []
            harness.quit.questions = []  // earlier scenarios share the recorder
            context.check("with no editor, Quit proceeds", app.shouldTerminate())
            context.check("with no editor, Quit asks nothing", harness.quit.questions.isEmpty)

            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check("an unedited capture does not block Quit", app.shouldTerminate())
            context.check("an unedited capture asks nothing", harness.quit.questions.isEmpty)

            E2EActions.drag(controller.model, .arrow, from: E2EActions.point(100, 700), to: E2EActions.point(500, 420))
            try context.require("the edit makes the document dirty", controller.model.isDirty)
            // Quit while the close question is open still asks about the edits: the sheet keeps
            // the editor open, and only the person's answer to it closes the editor.
            let window = try context.unwrap("the edited editor has a window", controller.window)
            let alerts = harness.messages.alerts.count
            let closes = controller.windowShouldClose(window)
            let closeSheet = try context.unwrap(
                "closing the edited editor asks in a sheet on it",
                await E2EWait.until { window.attachedSheet != nil } ? window.attachedSheet : nil)
            context.check(
                "the close question is a sheet, not an alert",
                !closes && closeSheet.sheetParent === window && harness.messages.alerts.count == alerts
                    && harness.quit.questions.isEmpty)
            harness.quit.answers = [false]
            context.check("declining keeps Recortia running", !app.shouldTerminate())
            context.check(
                "Quit asks once about one edited image",
                harness.quit.questions == [QuitDiscards(editedImages: 1, scrollingReview: false)],
                "\(harness.quit.questions)")
            context.check("declining keeps the edits", controller.model.isDirty && !controller.model.isClosed)
            context.check("declining Quit leaves the close question open", window.attachedSheet === closeSheet)
            window.endSheet(closeSheet, returnCode: .alertSecondButtonReturn)
            context.check(
                "Cancel on the close question keeps the editor and its edits",
                await E2EWait.until { window.sheets.isEmpty } && controller.model.isDirty && !controller.model.isClosed)
            harness.quit.answers = [true]
            context.check("confirming lets Recortia quit", app.shouldTerminate())
            // R3-D17: quitting closes pins too, so the warning names only copy and save.
            let portuguese = context.output.language.hasPrefix("pt")
            for (count, expected) in [
                (
                    1,
                    portuguese
                        ? "Uma imagem aberta tem alterações que não foram copiadas nem salvas. Sair descarta essas alterações."
                        : "An open image has changes that were not copied or saved. Quitting discards them."
                ),
                (
                    2,
                    portuguese
                        ? "2 imagens abertas têm alterações que não foram copiadas nem salvas. Sair descarta essas alterações."
                        : "2 open images have changes that were not copied or saved. Quitting discards them."
                ),
            ] {
                let detail = MessagePresenter.discardOnQuitDetail(
                    QuitDiscards(editedImages: count, scrollingReview: false))
                context.check("the quit warning for \(count) says what is lost", detail == expected, detail)
            }

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
            try await checkLoginItemRefresh(context)

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
                await context.darkCompanion(
                    pane, in: window, shot: name, surface: "Settings \(name)", settle: .milliseconds(400))
                switch name {
                case "general":
                    context.check(
                        "General holds the Pins section",
                        E2EAccessibilityControl.isPresent("settings.pinOpacity", in: pane))
                    await checkZoomControls(index: index, pane: pane, in: window, root: root, harness, context)
                case "capture":
                    context.check(
                        "Capture holds the capture sound switch, off by default",
                        E2EAccessibilityControl.isPresent("settings.captureSound", in: pane)
                            && !harness.settings.preferences.playsCaptureSound)
                    context.check(
                        "Capture holds After a capture, on the editor by default",
                        E2EAccessibilityControl.isPresent("settings.afterCapture", in: pane)
                            && harness.settings.preferences.afterCapture == .openEditor)
                    for identifier in ["settings.automaticScrolling", "settings.accessibilityStatus"] {
                        context.check(
                            "Capture holds the Scrolling Capture control \(identifier)",
                            E2EAccessibilityControl.isPresent(identifier, in: pane))
                    }
                    await checkWindowBackground(index: index, pane: pane, in: window, root: root, harness, context)
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

        /// General's wheel zoom control, off by default; Reverse zoom direction appears only while
        /// wheel zoom is on, and the pane still fits its content.
        private static func checkZoomControls(
            index: Int, pane: NSView, in window: NSWindow, root: NSView, _ harness: E2EHarness,
            _ context: ScenarioContext
        ) async {
            let preferences = harness.settings.preferences
            context.check(
                "General holds the wheel zoom control, off by default",
                E2EAccessibilityControl.isPresent("settings.zoomsWithScrollWheel", in: pane)
                    && !preferences.zoomsWithScrollWheel)
            context.check(
                "Reverse zoom direction is hidden while wheel zoom is off",
                !E2EAccessibilityControl.isPresent("settings.reversesScrollWheelZoom", in: pane))
            harness.settings.update { $0.zoomsWithScrollWheel = true }
            defer {
                harness.settings.update { $0.zoomsWithScrollWheelChoice = preferences.zoomsWithScrollWheelChoice }
            }
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "Reverse zoom direction appears, off, once wheel zoom is on",
                E2EAccessibilityControl.isPresent("settings.reversesScrollWheelZoom", in: pane)
                    && !harness.settings.preferences.reversesScrollWheelZoom)
            await checkPaneFits("general with wheel zoom", index: index, pane: pane, harness.app, context)
            context.snapshot(pane, shot: "general-wheel-zoom")
            await context.darkCompanion(
                pane, in: window, shot: "general-wheel-zoom", surface: "Settings general with wheel zoom",
                settle: .milliseconds(400))
        }

        /// Capture's window background: Transparent by default with no colour well; Solid color
        /// shows the well, and the pane still fits its content.
        private static func checkWindowBackground(
            index: Int, pane: NSView, in window: NSWindow, root: NSView, _ harness: E2EHarness,
            _ context: ScenarioContext
        ) async {
            let choice = harness.settings.preferences.windowCaptureBackgroundChoice
            context.check(
                "Capture holds the window background control, Transparent by default",
                E2EAccessibilityControl.isPresent("settings.windowBackground", in: pane)
                    && harness.settings.preferences.windowCaptureBackground == .transparent
                    && !E2EAccessibilityControl.isPresent("settings.windowBackgroundColor", in: pane))
            harness.settings.update { $0.windowCaptureBackground = .solid(RGBA(r: 30, g: 120, b: 220)) }
            defer { harness.settings.update { $0.windowCaptureBackgroundChoice = choice } }
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "Solid color shows the background colour well",
                E2EAccessibilityControl.isPresent("settings.windowBackgroundColor", in: pane))
            await checkPaneFits("capture with a window background", index: index, pane: pane, harness.app, context)
            context.snapshot(pane, shot: "capture-window-background")
            await context.darkCompanion(
                pane, in: window, shot: "capture-window-background",
                surface: "Settings capture with a window background",
                settle: .milliseconds(400))
        }

        /// The Pins and Scrolling Capture controls, sections of General and Capture, change the
        /// same preferences through pointer input on a visible, key, foreground Settings window.
        private static func settingsMergedControls(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let preferences = harness.settings.preferences
            let trusted = harness.accessibility.isTrusted
            defer {
                harness.accessibility.isTrusted = trusted
                harness.settings.update {
                    $0.pinDefaultOpacity = preferences.pinDefaultOpacity
                    $0.automaticScrollingEnabled = preferences.automaticScrollingEnabled
                    $0.snapsToInterfaceElementsChoice = preferences.snapsToInterfaceElementsChoice
                    $0.filenameTemplateChoice = preferences.filenameTemplateChoice
                    $0.defaultExportFormat = preferences.defaultExportFormat
                    $0.automaticExportFormatChoice = preferences.automaticExportFormatChoice
                    $0.primaryRecognitionLanguage = preferences.primaryRecognitionLanguage
                    $0.showsMenuBarIconChoice = preferences.showsMenuBarIconChoice
                    $0.hasExplainedHiddenMenuBarIcon = preferences.hasExplainedHiddenMenuBarIcon
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

            // The menu-bar icon switch, on by default: the first time it is turned off, one message
            // says how to get back; turning it on, or off again, says nothing.
            context.check("the menu-bar icon shows by default", harness.settings.preferences.showsMenuBarIcon)
            let messages = harness.messages.values.count
            try await click("settings.showsMenuBarIcon", tab: 0)
            context.check(
                "the General switch hides the menu-bar icon", !harness.settings.preferences.showsMenuBarIcon)
            context.check(
                "hiding the icon the first time says how to get back",
                Array(harness.messages.values.dropFirst(messages)) == [.menuBarIconHidden],
                "\(harness.messages.values.dropFirst(messages).map(\.title))")
            context.check(
                "hiding the icon leaves keep running in the menu bar on",
                harness.settings.preferences.keepsRunningInMenuBar)
            try await click("settings.showsMenuBarIcon", tab: 0)
            context.check("the switch shows the icon again", harness.settings.preferences.showsMenuBarIcon)
            try await click("settings.showsMenuBarIcon", tab: 0)
            context.check(
                "hiding it again says nothing more",
                !harness.settings.preferences.showsMenuBarIcon && harness.messages.values.count == messages + 1,
                "\(harness.messages.values.count - messages) messages")

            harness.accessibility.isTrusted = false
            let snapRequests = harness.accessibility.requestCount
            try await click("settings.snapsToInterfaceElements", tab: 2)
            context.check(
                "the Capture switch turns snapping to interface elements on",
                harness.settings.preferences.snapsToInterfaceElements)
            context.check(
                "turning snapping on without Accessibility asks exactly once",
                harness.accessibility.requestCount == snapRequests + 1,
                "\(harness.accessibility.requestCount - snapRequests)")
            try await click("settings.snapsToInterfaceElements", tab: 2)
            context.check(
                "the Capture switch turns snapping to interface elements off",
                !harness.settings.preferences.snapsToInterfaceElements)
            context.check(
                "turning snapping off asks nothing", harness.accessibility.requestCount == snapRequests + 1,
                "\(harness.accessibility.requestCount - snapRequests)")

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
            try await filenameTemplateField(tabs: tabs, activate: activate, root: root, harness, context)
            try await exportFormatMenu(tabs: tabs, activate: activate, root: root, harness, context)
            try await primaryLanguageMenu(tabs: tabs, activate: activate, root: root, harness, context)
            await foreground.stop(context)
        }

        /// Settings › Text Recognition's primary language menu (FR-08): it offers Automatic and
        /// every language Vision reports, a chosen language is stored in full form and shown chosen
        /// when the menu reopens, and choosing Automatic clears it.
        private static func primaryLanguageMenu(
            tabs: NSTabView, activate: () async throws -> Void, root: NSView, _ harness: E2EHarness,
            _ context: ScenarioContext
        ) async throws {
            tabs.selectTabViewItem(at: 6)
            try await activate()
            let loaded = await E2EWait.until {
                if case .loaded = harness.features.ocrLanguages.state { return true }
                return false
            }
            try context.require("OCR languages load for the primary language menu", loaded)
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            guard case .loaded(let list) = harness.features.ocrLanguages.state else { return }
            let pane = try context.unwrap("the Text Recognition pane", tabs.selectedTabViewItem?.view)
            let names = list.map(OCRSettingsTab.name(of:))
            let automatic = String(localized: "Automatic")
            // A language whose name no other entry shares, so the menu item is unambiguous.
            let language = try context.unwrap(
                "a uniquely named recognition language",
                list.last { candidate in names.filter { $0 == OCRSettingsTab.name(of: candidate) }.count == 1 })
            let name = OCRSettingsTab.name(of: language)
            let offered = try await E2EAccessibilityControl.chooseFromMenu(
                name, opening: "settings.primaryRecognitionLanguage", in: pane, context)
            context.check(
                "the primary language menu offers Automatic and every supported language",
                offered.map(\.title) == [automatic] + names, "\(offered)")
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "choosing \(name) stores it as the primary language",
                harness.settings.preferences.primaryRecognitionLanguage == language.maximalIdentifier,
                "\(String(describing: harness.settings.preferences.primaryRecognitionLanguage))")
            context.snapshot(pane, shot: "text-recognition-primary")
            let reopened = try await E2EAccessibilityControl.chooseFromMenu(
                automatic, opening: "settings.primaryRecognitionLanguage", in: pane, context)
            context.check(
                "the reopened menu shows \(name) chosen", reopened.filter(\.checked).map(\.title) == [name],
                "\(reopened)")
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "choosing Automatic clears the primary language",
                harness.settings.preferences.primaryRecognitionLanguage == nil)
        }

        /// Settings › Export's format menu (FR-07): it offers PNG, JPEG and Automatic, choosing
        /// Automatic stores it and the reopened menu shows it chosen, and choosing PNG returns to
        /// the default export options.
        private static func exportFormatMenu(
            tabs: NSTabView, activate: () async throws -> Void, root: NSView, _ harness: E2EHarness,
            _ context: ScenarioContext
        ) async throws {
            tabs.selectTabViewItem(at: 3)
            try await activate()
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            let pane = try context.unwrap("the Export pane", tabs.selectedTabViewItem?.view)
            let titles = [
                String(localized: "PNG"), String(localized: "JPEG"), String(localized: "Automatic (PNG or JPEG)"),
            ]
            let offered = try await E2EAccessibilityControl.chooseFromMenu(
                titles[2], opening: "settings.exportFormat", in: pane, context)
            context.check(
                "the Export format menu offers PNG, JPEG and Automatic", offered.map(\.title) == titles, "\(offered)")
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "choosing Automatic stores it for saved files",
                harness.settings.preferences.exportFormat == .automatic
                    && harness.settings.preferences.exportOptions.formatChoice == .automatic,
                "\(harness.settings.preferences.exportFormat)")
            context.snapshot(pane, shot: "export-automatic")
            let reopened = try await E2EAccessibilityControl.chooseFromMenu(
                titles[0], opening: "settings.exportFormat", in: pane, context)
            context.check(
                "the reopened Export format menu shows Automatic chosen",
                reopened.filter(\.checked).map(\.title) == [titles[2]], "\(reopened)")
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "choosing PNG again returns to the default export options",
                harness.settings.preferences.exportOptions == ExportOptions(),
                "\(harness.settings.preferences.exportOptions)")
        }

        /// Settings › Export's file-name field (A-9), typed through its native field editor: an
        /// accepted template is stored and shown as an example; a refused one stores nothing and
        /// says why.
        private static func filenameTemplateField(
            tabs: NSTabView, activate: () async throws -> Void, root: NSView, _ harness: E2EHarness,
            _ context: ScenarioContext
        ) async throws {
            tabs.selectTabViewItem(at: 3)
            try await activate()
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            let pane = try context.unwrap("the Export pane", tabs.selectedTabViewItem?.view)
            try await E2EAccessibilityControl.enterNumber(
                "settings.filenameTemplate", text: "Captura {counter}", in: pane, context)
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "the file-name field stores an accepted template",
                harness.settings.preferences.filenameTemplateChoice?.text == "Captura {counter}",
                String(describing: harness.settings.preferences.filenameTemplateChoice?.text))
            let example = try E2EAccessibilityControl.text(
                .value, for: "settings.filenameTemplate.example", in: pane, context)
            context.check(
                "the example shows the template's name", example.contains("Captura 1.png"), example)
            context.snapshot(pane, shot: "export-filename")
            // Automatic decides after encoding, so the example names both extensions.
            let format = harness.settings.preferences.exportFormat
            harness.settings.update { $0.exportFormat = .automatic }
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            let automatic = try E2EAccessibilityControl.text(
                .value, for: "settings.filenameTemplate.example", in: pane, context)
            context.check(
                "under Automatic the example names .png and .jpg",
                automatic.contains("Captura 1.png") && automatic.contains(".jpg"), automatic)
            context.snapshot(pane, shot: "export-filename-automatic")
            harness.settings.update { $0.exportFormat = format }
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            try await activate()
            try await E2EAccessibilityControl.enterNumber(
                "settings.filenameTemplate", text: "../x", in: pane, context)
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "a refused template stores nothing, so files keep the default name",
                harness.settings.preferences.filenameTemplateChoice == nil
                    && harness.settings.preferences.filenameTemplate == .default)
            context.check(
                "the field says why the template was refused",
                E2EAccessibilityControl.isPresent("settings.filenameTemplate.message", in: pane))
            context.snapshot(pane, shot: "export-filename-refused")
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

        /// Stands in for the system's login item: a registration that needs approval throws until
        /// the scenario approves it. Never touches the real login items.
        @MainActor
        private final class PendingApprovalLoginItem: LoginItemService {
            var isEnabled = false
            func setEnabled(_ enabled: Bool) throws { throw CocoaError(.featureUnsupported) }
        }

        /// Review R2-D18: after approval in System Settings, returning to the still-open General
        /// pane must show the item enabled without the old warning.
        private static func checkLoginItemRefresh(_ context: ScenarioContext) async throws {
            let service = PendingApprovalLoginItem()
            let loginItem = LoginItemModel(service: service)
            let host = E2ESnapshot.host(
                GeneralSettingsTab(
                    settings: .e2eInMemory(), loginItem: loginItem, setShowsMenuBarIcon: { _ in }))
            defer { host.close() }
            let root = try context.unwrap("General pane hosted", host.contentView)
            loginItem.setEnabled(true)
            await E2ESnapshot.settle(root)
            try context.require(
                "a registration awaiting approval shows the warning",
                E2EAccessibilityControl.isPresent("settings.loginItem.warning", in: root))
            service.isEnabled = true  // approved in System Settings
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: host)
            await E2ESnapshot.settle(root)
            context.check(
                "returning to the open pane shows the approved item without the old warning",
                loginItem.isEnabled && !E2EAccessibilityControl.isPresent("settings.loginItem.warning", in: root))
        }

        /// Each pane's content as `SettingsWindowController` builds it, without the pane wrapper.
        private static func settingsContent(_ index: Int, _ model: AppModel) -> NSView? {
            func host(_ view: some View) -> NSView { NSHostingView(rootView: view.frame(width: 560)) }
            return switch index {
            case 0:
                host(
                    GeneralSettingsTab(
                        settings: model.settings, loginItem: model.features.loginItem,
                        setShowsMenuBarIcon: model.setShowsMenuBarIcon))
            case 1:
                host(
                    ShortcutsSettingsTab(status: model.shortcutStatus, onRestoreDefaults: model.restoreDefaultShortcuts)
                )
            case 2:
                host(
                    CaptureSettingsTab(settings: model.settings, accessibility: model.features.services.accessibility))
            case 3: host(ExportSettingsTab(settings: model.settings, folders: model.features.services.folders))
            case 4:
                host(
                    GitHubUploadSettings(
                        settings: model.settings, credentials: model.features.services.githubCredentials))
            case 5: host(PrivacySettingsTab(settings: model.settings, diagnostics: model.features.diagnostics))
            case 6: host(OCRSettingsTab(settings: model.settings, languages: model.features.ocrLanguages))
            default: nil
            }
        }

        private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            EditorWindowController.first(type, in: view)
        }
    }
#endif
