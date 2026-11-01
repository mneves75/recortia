#if DEBUG
    import AppKit
    import Domain
    import Features

    /// FR-01: "Keep running in the menu bar" in Settings › General. On (the default), closing the
    /// last window leaves Recortia in the menu bar; off, closing the person's last window requests
    /// normal termination, after any export in progress. In this process termination is recorded;
    /// `LastWindowProbe` proves real process exit in child processes.
    @MainActor
    enum LastWindowScenarios {
        static func quitAfterLastWindow(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let presence = AppPresence.shared
            let terminations = harness.terminations
            harness.reset()
            var start = terminations.count
            func requests() -> Int { terminations.count - start }
            func settled() async { try? await Task.sleep(for: .milliseconds(400)) }
            func shown() -> NSWindow {
                let window = PresenceScenarios.plainWindow()
                PresenceScenarios.show(window, presence)
                return window
            }

            let settings = SettingsWindowController.makeWindow(model: harness.app)
            settings.appearance = NSAppearance(named: .aqua)
            settings.setContentSize(NSSize(width: 560, height: 540))
            settings.center(on: ScreenChoice.screen())
            defer { settings.close() }
            let root = try context.unwrap("settings window has content", settings.contentView)
            let tabs = try context.unwrap("Settings tab view", EditorWindowController.first(NSTabView.self, in: root))
            tabs.selectTabViewItem(at: 0)
            try await E2EAccessibilityControl.showAndActivate(settings, context)
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "keeping Recortia in the menu bar is on by default", harness.settings.preferences.keepsRunningInMenuBar)
            context.snapshot(tabs.selectedTabViewItem?.view ?? root, shot: "general")

            settings.close()
            await settled()
            context.check("with the preference on, closing the last window does not quit", requests() == 0)
            context.check(
                "and Recortia stays in the menu bar as an accessory app",
                await E2EWait.until(timeout: .seconds(3)) { NSApp.activationPolicy() == .accessory },
                PresenceScenarios.policy())

            try await E2EAccessibilityControl.showAndActivate(settings, context)
            try E2EAccessibilityControl.press("settings.keepRunningInMenuBar", in: root, context)
            await E2ESnapshot.settle(root)
            context.check(
                "the General switch turns the preference off", !harness.settings.preferences.keepsRunningInMenuBar)
            context.check("Quit stays available with the preference off", harness.app.isEnabled(.quit))

            settings.close()
            try context.require(
                "closing the last General window requests termination",
                await E2EWait.until(timeout: .seconds(3)) { requests() == 1 }, "\(requests()) requests")
            await settled()
            try context.require("closing General requests termination exactly once", requests() == 1, "\(requests())")
            try context.require("the Settings fixture is closed before the zero-window matrix", !settings.isVisible)
            // The real General close above has its own outcome; the existing matrix starts at zero.
            start = terminations.count
            presence.setNeedsRefresh()
            await settled()
            context.check("without a closed window (as at launch) nothing quits", requests() == 0)

            let controller = try await harness.openImported(harness.desktop, name: "last-window.png")
            let editor = try context.unwrap("the editor has a window", controller.window)
            editor.ignoresMouseEvents = true
            PresenceScenarios.show(editor, presence)
            editor.close()
            context.check(
                "closing the last editor requests termination",
                await E2EWait.until(timeout: .seconds(3)) { requests() == 1 }, "\(requests()) requests")
            await settled()
            context.check("exactly once", requests() == 1, "\(requests()) requests")

            let first = shown()
            let second = shown()
            first.close()
            await settled()
            context.check("closing one of two windows does not quit", requests() == 1)
            second.close()
            let replacement = shown()
            await settled()
            context.check("a window replacing the last one in the same turn does not quit", requests() == 1)

            let minimized = try await harness.openImported(harness.desktop, name: "last-window-minimized.png")
            let minimizedWindow = try context.unwrap("the second editor has a window", minimized.window)
            minimizedWindow.ignoresMouseEvents = true
            PresenceScenarios.show(minimizedWindow, presence)
            minimizedWindow.miniaturize(nil)
            try context.require(
                "the editor minimizes",
                await E2EWait.until(timeout: .seconds(5)) { minimizedWindow.isMiniaturized })
            replacement.close()
            await settled()
            context.check("a minimized window keeps Recortia running", requests() == 1)
            minimizedWindow.close()
            context.check(
                "closing the minimized last window quits",
                await E2EWait.until(timeout: .seconds(3)) { requests() == 2 }, "\(requests()) requests")

            shown().close()
            harness.app.perform(.captureRegion)
            await settled()
            context.check("a capture started right after the last close keeps Recortia running", requests() == 2)
            harness.features.capture.cancel()
            await settled()
            context.check("cancelling that capture does not quit", requests() == 2, "\(requests()) requests")

            try await checkUnsavedEdits(harness, context, requests)
            try await checkExportWait(harness, context, requests, shown)

            harness.settings.update { $0.keepsRunningInMenuBar = true }
            for kind in LastWindowProbe.Kind.allCases {
                await LastWindowProbe.check(kind, context)
            }
        }

        /// The editor's own discard question still guards the last close; Cancel never quits.
        private static func checkUnsavedEdits(
            _ harness: E2EHarness, _ context: ScenarioContext, _ requests: () -> Int
        ) async throws {
            let before = requests()
            let controller = try await harness.openImported(harness.desktop, name: "last-window-edited.png")
            let window = try context.unwrap("the edited editor has a window", controller.window)
            window.ignoresMouseEvents = true
            PresenceScenarios.show(window, AppPresence.shared)
            E2EActions.drag(controller.model, .arrow, from: E2EActions.point(100, 700), to: E2EActions.point(500, 420))
            try context.require("the edit makes the document dirty", controller.model.isDirty)
            for discard in [false, true] {
                window.performClose(nil)
                let sheet = try context.unwrap(
                    "closing an edited editor asks first",
                    await E2EWait.until(timeout: .seconds(5)) { window.attachedSheet != nil }
                        ? window.attachedSheet : nil)
                window.endSheet(sheet, returnCode: discard ? .alertFirstButtonReturn : .alertSecondButtonReturn)
                if discard {
                    context.check(
                        "Discard closes the last window and quits",
                        await E2EWait.until(timeout: .seconds(3)) { requests() == before + 1 }, "\(requests())")
                } else {
                    try? await Task.sleep(for: .milliseconds(400))
                    context.check(
                        "Cancel keeps the editor, its edits and Recortia",
                        window.isVisible && !controller.model.isClosed && controller.model.isDirty
                            && requests() == before)
                }
            }
        }

        /// Quitting waits for an automatic export that belongs to no window, reports its result,
        /// and gives up when the person turns the preference back on, opens a window or starts a
        /// capture meanwhile.
        private static func checkExportWait(
            _ harness: E2EHarness, _ context: ScenarioContext, _ requests: () -> Int, _ shown: () -> NSWindow
        ) async throws {
            let folder = harness.output.workDirectory.appending(path: "last-window-saves", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try folder.bookmarkData()
            func saved() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? -1 }
            let openDocument = harness.app.openDocument
            // No editor: the automatic save then belongs to no window and closing one cannot cancel it.
            harness.app.openDocument = { _ in nil }
            defer {
                harness.app.openDocument = openDocument
                harness.terminations.onRequest = nil
                harness.exportGate.release()
                harness.settings.update {
                    $0.autoCopy = false
                    $0.autoSave = false
                    $0.preferredSaveFolderBookmark = nil
                }
            }
            /// Closes the only window while a capture's automatic export waits at the pipeline.
            func closeDuringExport(_ label: String) async throws {
                let window = shown()
                harness.exportGate.holdNextSnapshot = true
                harness.app.perform(.captureRegion)
                try context.require(
                    "\(label): the capture is accepted",
                    harness.features.capture.commitRegion(
                        E2EActions.desktopRect(SyntheticDesktop.notesWindow), on: harness.capture.display))
                try context.require(
                    "\(label): the automatic export waits at the pipeline",
                    await E2EWait.until { harness.exportGate.isWaiting })
                try context.require(
                    "\(label): the capture restores the window", await E2EWait.until { window.isVisible })
                window.close()
                try? await Task.sleep(for: .milliseconds(400))
            }

            harness.settings.update {
                $0.preferredSaveFolderBookmark = bookmark
                $0.autoSave = true
                $0.keepsRunningInMenuBar = false
            }
            var savedAtRequest: Int?
            harness.terminations.onRequest = { savedAtRequest = saved() }
            let before = requests()
            try await closeDuringExport("save")
            context.check("an automatic save in progress delays quitting", requests() == before, "\(requests())")
            harness.exportGate.release()
            context.check(
                "quitting is requested once the save finished",
                await E2EWait.until(timeout: .seconds(10)) { requests() == before + 1 }, "\(requests())")
            context.check(
                "the file was written before termination was requested", savedAtRequest == 1,
                "\(String(describing: savedAtRequest))")

            for change in ["preference", "window"] {
                harness.settings.update { $0.keepsRunningInMenuBar = false }
                let count = requests()
                try await closeDuringExport(change)
                var opened: NSWindow?
                if change == "preference" {
                    harness.settings.update { $0.keepsRunningInMenuBar = true }
                } else {
                    opened = shown()
                }
                harness.exportGate.release()
                _ = await E2EWait.until { !harness.features.export.isBusy }
                try? await Task.sleep(for: .milliseconds(600))
                context.check(
                    "\(change) changed while waiting: Recortia keeps running", requests() == count, "\(requests())")
                harness.settings.update { $0.keepsRunningInMenuBar = true }
                opened?.close()
            }

            for sameTurn in [false, true] {
                let label = sameTurn ? "same-turn capture" : "late capture"
                harness.settings.update { $0.keepsRunningInMenuBar = false }
                let count = requests()
                try await closeDuringExport(label)
                try context.require(
                    "\(label): the last close is waiting for the unfinished export",
                    requests() == count && harness.exportGate.isWaiting && harness.features.export.isBusy
                        && !AppPresence.shared.hasUserWindow && !harness.features.capture.state.isActive)

                harness.app.perform(.captureRegion)
                try context.require("\(label): the new capture becomes active", harness.features.capture.state.isActive)
                if !sameTurn {
                    try? await Task.sleep(for: .milliseconds(400))
                    context.check("\(label): selecting does not quit", requests() == count, "\(requests())")
                }
                // In the fast case no suspension separates command acceptance from cancellation.
                harness.features.capture.cancel()
                try context.require("\(label): the new capture is cancelled", !harness.features.capture.state.isActive)
                try context.require("\(label): the old export is still held", harness.exportGate.isWaiting)
                try context.require(
                    "\(label): cancelling releases the capture hold without opening a window",
                    await E2EWait.until { !AppPresence.shared.hasUserWindow })
                harness.exportGate.release()
                try context.require(
                    "\(label): the old export finishes", await E2EWait.until { !harness.features.export.isBusy })
                try? await Task.sleep(for: .milliseconds(600))
                context.check(
                    "\(label): starting then cancelling a capture cancels pending autoquit",
                    requests() == count, "\(requests()) requests, expected \(count)")
            }

            // A failure is reported before quitting: copy waits, then the save finds no folder.
            harness.settings.update {
                $0.keepsRunningInMenuBar = false
                $0.autoCopy = true
                $0.preferredSaveFolderBookmark = Data([1, 2, 3])
                $0.autoSave = true
            }
            let messages = harness.messages.values.count
            var messagesAtRequest: Int?
            harness.terminations.onRequest = { messagesAtRequest = harness.messages.values.count }
            let count = requests()
            try await closeDuringExport("failure")
            harness.exportGate.release()
            context.check(
                "quitting follows a failed automatic save",
                await E2EWait.until(timeout: .seconds(10)) { requests() == count + 1 }, "\(requests())")
            context.check(
                "the failure was reported before termination was requested", messagesAtRequest == messages + 1,
                "\(String(describing: messagesAtRequest)) vs \(messages)")
            harness.settings.update { $0.keepsRunningInMenuBar = true }
        }
    }

    /// Child processes of this binary that run the real AppPresence → AppModel → `NSApp.terminate`
    /// path, so the parent can see an actual exit (status 0) or a process still running.
    @MainActor
    enum LastWindowProbe {
        enum Kind: String, CaseIterable {
            /// Preference off: a pin keeps the app alive; closing the pin, the last window, quits.
            case quits = "quit-after-last-window"
            /// Preference on: closing the last window leaves the process running.
            case keepsRunning = "keep-running-after-last-window"
            /// Preference off, launched without a window: nothing quits.
            case launch = "launch-without-window"
        }

        static let argument = "-RecortiaE2ELastWindowProbe"
        /// The child's own exit status when it is still running at the end of its script.
        static let stillRunning: Int32 = 10
        static let pinMarker = "still running after the window closed while a pin remains"

        static func check(_ kind: Kind, _ context: ScenarioContext) async {
            let logURL = context.output.workDirectory.appending(path: "probe-\(kind.rawValue).log")
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = [argument, kind.rawValue, "-AppleLanguages", "(\(context.output.language))"]
            do {
                FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
                let log = try FileHandle(forWritingTo: logURL)
                process.standardOutput = log
                process.standardError = log
                try process.run()
            } catch {
                context.check("\(kind.rawValue) probe starts", false, "\(error)")
                return
            }
            let finished = await E2EWait.until(timeout: .seconds(30), poll: .milliseconds(50)) { !process.isRunning }
            if !finished { process.terminate() }
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let expected = kind == .quits ? 0 : stillRunning
            let exited = finished && process.terminationReason == .exit
            context.check(
                "\(kind.rawValue): the child \(kind == .quits ? "quits through normal termination" : "keeps running")",
                exited && process.terminationStatus == expected && (kind != .quits || log.contains(pinMarker)),
                finished
                    ? "status \(process.terminationStatus), expected \(expected); log work/\(logURL.lastPathComponent)"
                    : "child timed out")
        }

        /// Child side: returns false when this process is not a last-window probe.
        static func runIfRequested(arguments: [String]) -> Bool {
            guard let index = arguments.firstIndex(of: argument) else { return false }
            guard index + 1 < arguments.count, let kind = Kind(rawValue: arguments[index + 1]) else {
                E2ERunner.log("unknown last-window probe; known: \(Kind.allCases.map(\.rawValue))")
                exit(2)
            }
            Task {
                do {
                    try await run(kind)
                } catch {
                    E2ERunner.log("last-window probe \(kind.rawValue) failed: \(error)")
                    exit(3)
                }
                E2ERunner.log("last-window probe \(kind.rawValue) is still running")
                exit(stillRunning)
            }
            return true
        }

        private static func run(_ kind: Kind) async throws {
            NSApp.appearance = NSAppearance(named: .aqua)
            let settings = SettingsStore.e2eInMemory()
            settings.update { $0.keepsRunningInMenuBar = kind == .keepsRunning }
            // Production defaults: termination is `NSApp.terminate(nil)`.
            let model = AppModel(settings: settings, services: nil, shortcutRegistry: KeyboardShortcutsRegistry())
            defer { withExtendedLifetime(model) {} }
            let presence = AppPresence.shared
            switch kind {
            case .launch:
                presence.setNeedsRefresh()
                try await Task.sleep(for: .seconds(2))
            case .keepsRunning:
                try closeSwitchableWindow()
                try await Task.sleep(for: .seconds(2))
            case .quits:
                let (pin, pins) = try E2EPanelProbe.makePinPanel()
                defer { withExtendedLifetime(pins) {} }
                E2ESnapshot.park(pin)
                pin.alphaValue = 0
                pin.ignoresMouseEvents = true
                presence.windowWillAppear()
                pin.orderFrontRegardless()
                guard AppPresence.isSwitchable(pin) else { throw E2EAbort("the pin is not a switchable window") }
                try closeSwitchableWindow()
                try await Task.sleep(for: .milliseconds(1_500))
                E2ERunner.log(pinMarker)
                pin.close()
                try await Task.sleep(for: .seconds(5))
            }
        }

        private static func closeSwitchableWindow() throws {
            let window = PresenceScenarios.plainWindow()
            PresenceScenarios.show(window, AppPresence.shared)
            guard AppPresence.isSwitchable(window) else { throw E2EAbort("the window is not switchable") }
            window.close()
        }
    }
#endif
