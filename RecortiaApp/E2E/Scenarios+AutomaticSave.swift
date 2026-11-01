#if DEBUG
    import AppKit
    import Domain
    import Features

    /// FR-07 automatic save through the real Settings › Export controls: choosing, replacing,
    /// clearing and losing the folder, with a scripted folder panel and synthetic captures. Files
    /// are written only inside this run's work directory and read back as images.
    @MainActor
    enum AutomaticSaveScenarios {
        static func settings(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let fileManager = FileManager.default
            let work = harness.output.workDirectory.appending(
                path: "automatic-save-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            // A long folder name with non-ASCII characters, near the 255-byte file-name limit.
            let longName = String(String(repeating: "Capturas automáticas de tela ", count: 9).prefix(230))
            let first = work.appending(path: longName, directoryHint: .isDirectory)
            let second = work.appending(path: "second", directoryHint: .isDirectory)
            let lost = work.appending(path: "lost", directoryHint: .isDirectory)
            for folder in [first, second, lost] {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try context.require("the long folder name is near the limit", longName.utf8.count > 200)
            harness.settings.update {
                $0.preferredSaveFolderBookmark = nil
                $0.autoSave = false
                $0.defaultExportFormat = .png
            }

            // The owned host takes the foreground, then yields it, so the runner's own activation is
            // cooperative and deterministic whatever was frontmost before this scenario.
            let foreground = try await E2EForegroundFixture.start(context)
            defer { foreground.requestStop() }
            let window = SettingsWindowController.makeWindow(model: harness.app)
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 560, height: 540))
            window.center(on: ScreenChoice.screen())
            defer { window.close() }
            let root = try context.unwrap("settings window has content", window.contentView)
            let tabs = try context.unwrap("Settings tab view", EditorWindowController.first(NSTabView.self, in: root))
            tabs.selectTabViewItem(at: 3)
            let pane = try context.unwrap("the selected Settings pane", tabs.selectedTabViewItem?.view)
            // A runner that is active and frontmost keeps its focus; otherwise it reacquires it
            // through the host. Either way the same visible/key/active/frontmost requirement follows.
            func activate() async throws {
                if !E2EForegroundFixture.runnerIsForeground {
                    try await foreground.restore()
                    try await foreground.yieldToRunner()
                }
                try await E2EAccessibilityControl.showAndActivate(window, context)
            }
            try await activate()
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            func press(_ identifier: String) async throws {
                try await activate()
                try E2EAccessibilityControl.click(identifier, in: pane, context)
                await E2ESnapshot.settle(root)
            }
            let chooser = harness.folderChooser

            try await press("settings.autoSave")
            context.check("turning automatic save on without a folder asks for one", chooser.asked == 1)
            context.check(
                "cancelling the folder panel leaves automatic save off and no folder",
                !harness.settings.preferences.autoSave
                    && harness.settings.preferences.preferredSaveFolderBookmark == nil)

            let messages = harness.messages.values.count
            chooser.answers = [work.appending(path: "missing", directoryHint: .isDirectory)]
            try await press("settings.autoSave")
            context.check(
                "a folder whose access cannot be remembered is reported",
                harness.messages.values.count == messages + 1, "\(harness.messages.values.count - messages) messages")
            context.check(
                "and changes nothing",
                !harness.settings.preferences.autoSave
                    && harness.settings.preferences.preferredSaveFolderBookmark == nil)

            chooser.answers = [first]
            try await press("settings.autoSave")
            context.check("choosing a folder turns automatic save on", harness.settings.preferences.autoSave)
            context.check(
                "the chosen folder is remembered", savedFolder(harness) == canonical(first), savedFolder(harness))
            // Layout reads record their own failure and never stop the file checks below.
            if let name = try? E2EAccessibilityControl.text(.help, for: "settings.saveFolder.name", in: root, context) {
                context.check(
                    "the folder row keeps the whole long name", name == fileManager.displayName(atPath: first.path),
                    name)
            }
            if let button = try? E2EAccessibilityControl.frame("settings.saveFolder.choose", in: root, context) {
                let bounds = pane.window?.convertToScreen(pane.convert(pane.bounds, to: nil)) ?? .zero
                context.check(
                    "a long folder name does not push Choose… out of the pane",
                    bounds.insetBy(dx: -1, dy: -1).contains(button), "button \(button), pane \(bounds)")
            }
            context.snapshot(pane, shot: "export-long-folder")

            // A capture writes one decodable image into exactly that folder; existing files that
            // share its name are never replaced.
            let occupied = try occupyNextNames(in: first)
            let elsewhere = try images(in: work)
            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            let written = await E2EWait.until { (try? images(in: first).count) == occupied.count + 1 }
            try context.require("the capture is saved into the chosen folder", written)
            let saved = try images(in: first).filter { !occupied.keys.contains($0) }
            for file in saved {
                let data = try Data(contentsOf: first.appending(path: file))
                let image = try E2EActions.decode(data, "automatic save \(file)", context)
                context.check("the saved file is a capture-sized image", image.width > 100 && image.height > 100)
            }
            context.check(
                "files that share the generated name are not replaced",
                try occupied.allSatisfy { try Data(contentsOf: first.appending(path: $0.key)) == $0.value })
            context.check("nothing is written outside the chosen folder", try images(in: work) == elsewhere)
            await E2EActions.snapshotEditor(controller, context, shot: "saved")

            chooser.answers = [nil]
            try await press("settings.saveFolder.choose")
            context.check("cancelling Choose… keeps the folder", savedFolder(harness) == canonical(first))
            chooser.answers = [second]
            try await press("settings.saveFolder.choose")
            context.check(
                "Choose… replaces the folder", savedFolder(harness) == canonical(second), savedFolder(harness))
            context.check("replacing the folder keeps automatic save on", harness.settings.preferences.autoSave)
            let firstCount = try images(in: first).count
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check(
                "the next capture goes to the new folder",
                await E2EWait.until { (try? images(in: second).count) == 1 })
            context.check("the old folder gets nothing more", try images(in: first).count == firstCount)

            try await checkRevocationDuringRender(
                harness, context, work: work, first: first, second: second, firstCount: firstCount, press: press)

            try await press("settings.saveFolder.remove")
            context.check(
                "Remove forgets the folder and turns automatic save off together",
                !harness.settings.preferences.autoSave
                    && harness.settings.preferences.preferredSaveFolderBookmark == nil)
            context.check(
                "Remove disappears with the folder",
                !E2EAccessibilityControl.isPresent("settings.saveFolder.remove", in: root))
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            try? await Task.sleep(for: .milliseconds(500))
            context.check(
                "with automatic save off a capture writes nothing",
                try images(in: first).count == firstCount && images(in: second).count == 1)

            chooser.answers = [lost]
            try await press("settings.autoSave")
            try fileManager.removeItem(at: lost)
            let unavailable = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check(
                "a save to a folder that disappeared fails visibly",
                await E2EWait.until { unavailable.model.notice == .exported(.failed(.accessDenied)) },
                "\(String(describing: unavailable.model.notice))")
            context.check(
                "and is not written anywhere else",
                try images(in: first).count == firstCount && images(in: second).count == 1 && images(in: work).isEmpty)
            // The failed capture's editor is now in front; the person returns to Settings first.
            try await activate()
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "the unavailable folder stays remembered with automatic save on",
                harness.settings.preferences.autoSave && harness.settings.preferences.preferredSaveFolderBookmark != nil
            )
            context.check(
                "Settings says the folder is unavailable",
                E2EAccessibilityControl.isPresent("settings.saveFolder.unavailable", in: root))
            context.snapshot(pane, shot: "export-unavailable")

            try await press("settings.autoSave")
            context.check("automatic save turns off", !harness.settings.preferences.autoSave)
            let askedBefore = chooser.asked
            try await press("settings.autoSave")
            context.check(
                "turning it on again with the folder gone asks for a new one", chooser.asked == askedBefore + 1)
            context.check("cancelling keeps it off", !harness.settings.preferences.autoSave)
            harness.settings.clearAutomaticSaveFolder()
            await foreground.stop(context)
        }

        /// A capture's automatic save is held at the render, before the write-time recheck; the
        /// person then turns automatic save off, or chooses another folder, through the real
        /// Settings controls. Neither the old nor the new folder gets that capture. A fresh capture
        /// under the new consent then writes, and the earlier folder is chosen again, so the
        /// checks that follow see exactly the files they saw before.
        private static func checkRevocationDuringRender(
            _ harness: E2EHarness, _ context: ScenarioContext, work: URL, first: URL, second: URL, firstCount: Int,
            press: (String) async throws -> Void
        ) async throws {
            let gate = harness.exportGate
            let export = harness.features.export
            let chooser = harness.folderChooser
            let revoked = work.appending(path: "revoked", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: revoked, withIntermediateDirectories: false)
            let topLevel = try images(in: work)
            defer {
                gate.holdNextSnapshot = false
                gate.release()
            }
            /// Every folder this scenario writes to keeps the count it had before the held capture.
            func nothingWritten(_ label: String) throws {
                let previous = try images(in: second).count
                let chosen = try images(in: revoked).count
                context.check(
                    "\(label): the earlier folder gets nothing", try images(in: first).count == firstCount)
                context.check("\(label): the previous folder gets nothing", previous == 1, "\(previous) files")
                context.check("\(label): the newly chosen folder gets nothing", chosen == 0, "\(chosen) files")
                context.check("\(label): nothing is written elsewhere", try images(in: work) == topLevel)
            }
            /// Starts a capture whose automatic save waits at the render, before the write.
            func holdCapture(_ label: String, folder: URL) async throws -> Int {
                try context.require(
                    "\(label): no export is in flight before the held capture",
                    await E2EWait.until { !export.isBusy } && !gate.isWaiting && !gate.holdNextSnapshot)
                try context.require(
                    "\(label): only automatic save is on, into \(folder.lastPathComponent)",
                    harness.settings.preferences.autoSave && !harness.settings.preferences.autoCopy
                        && harness.settings.preferences.githubUpload == nil
                        && savedFolder(harness) == canonical(folder), savedFolder(harness))
                let renders = gate.snapshotCount
                gate.holdNextSnapshot = true
                _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
                try context.require(
                    "\(label): the capture's automatic save waits at the render, before the write",
                    await E2EWait.until { gate.isWaiting } && export.isBusy,
                    "waiting=\(gate.isWaiting), busy=\(export.isBusy)")
                return renders
            }
            /// Releases the held render and waits until that export has finished.
            func releaseAndFinish(_ label: String, renders: Int) async throws {
                gate.release()
                try context.require(
                    "\(label): the held export finishes", await E2EWait.until { !gate.isWaiting && !export.isBusy })
                try? await Task.sleep(for: .milliseconds(500))
                context.check(
                    "\(label): the capture rendered once, with no retry or fallback",
                    gate.snapshotCount == renders + 1, "\(gate.snapshotCount - renders) renders")
            }

            // pref-revoked no-write: automatic save turned off while the render is held.
            var label = "pref-revoked no-write"
            var messages = harness.messages.values.count
            var renders = try await holdCapture(label, folder: second)
            try await press("settings.autoSave")
            try context.require(
                "\(label): the switch turns automatic save off and keeps the folder",
                !harness.settings.preferences.autoSave && savedFolder(harness) == canonical(second),
                savedFolder(harness))
            try await releaseAndFinish(label, renders: renders)
            try nothingWritten(label)
            context.check(
                "\(label): no message reports the withdrawn save", harness.messages.values.count == messages,
                "\(harness.messages.values.count - messages) messages")

            let asked = chooser.asked
            try await press("settings.autoSave")
            try context.require(
                "automatic save turns back on with the remembered folder, without asking",
                harness.settings.preferences.autoSave && chooser.asked == asked
                    && savedFolder(harness) == canonical(second), savedFolder(harness))

            // folder-changed no-write: Choose… picks another folder while the render is held.
            label = "folder-changed no-write"
            messages = harness.messages.values.count
            renders = try await holdCapture(label, folder: second)
            chooser.answers = [revoked]
            try await press("settings.saveFolder.choose")
            try context.require(
                "\(label): Choose… replaces the folder and keeps automatic save on",
                chooser.asked == asked + 1 && harness.settings.preferences.autoSave
                    && savedFolder(harness) == canonical(revoked), savedFolder(harness))
            try await releaseAndFinish(label, renders: renders)
            try nothingWritten(label)
            context.check(
                "\(label): no message reports the withdrawn save", harness.messages.values.count == messages,
                "\(harness.messages.values.count - messages) messages")

            // positive fresh write: a new capture under the current consent saves into the new folder.
            label = "positive fresh write"
            try context.require(
                "\(label): no export is in flight before the capture",
                await E2EWait.until { !export.isBusy } && !gate.isWaiting && !gate.holdNextSnapshot)
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            try context.require(
                "\(label): the fresh capture is saved into the newly chosen folder",
                await E2EWait.until { (try? images(in: revoked).count) == 1 })
            for file in try images(in: revoked) {
                let image = try E2EActions.decode(
                    try Data(contentsOf: revoked.appending(path: file)), "\(label) \(file)", context)
                context.check(
                    "\(label): the file is a decodable capture-sized image",
                    image.width > 100 && image.height > 100)
            }
            context.check(
                "\(label): the earlier folders get nothing",
                try images(in: first).count == firstCount && images(in: second).count == 1
                    && images(in: work) == topLevel)

            // Back to the previous folder through Choose…, for the Remove and lost-folder checks.
            chooser.answers = [second]
            try await press("settings.saveFolder.choose")
            try context.require(
                "choosing the previous folder again restores it with automatic save on",
                await E2EWait.until { !export.isBusy } && harness.settings.preferences.autoSave
                    && savedFolder(harness) == canonical(second), savedFolder(harness))
        }

        private static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

        private static func savedFolder(_ harness: E2EHarness) -> String {
            guard let bookmark = harness.settings.preferences.preferredSaveFolderBookmark,
                let url = harness.services.folders.resolveFolder(bookmark: bookmark)
            else { return "none" }
            return canonical(url)
        }

        /// Image file names directly inside `folder`.
        private static func images(in folder: URL) throws -> Set<String> {
            Set(
                try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                    $0.hasSuffix(".png") || $0.hasSuffix(".jpg")
                })
        }

        /// Fills the names automatic saves would use for the next minute with unrelated bytes, so the
        /// next save must pick a new name.
        private static func occupyNextNames(in folder: URL) throws -> [String: Data] {
            var occupied: [String: Data] = [:]
            let now = Date()
            for second in 0..<60 {
                let name = ExportFilename.make(for: now.addingTimeInterval(Double(second)), format: .png)
                let data = Data("not a capture \(second)".utf8)
                try data.write(to: folder.appending(path: name), options: .withoutOverwriting)
                occupied[name] = data
            }
            return occupied
        }
    }
#endif
