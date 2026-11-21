#if DEBUG
    import AppKit
    import Domain
    import Features

    /// B-10 through the real Settings › Privacy controls: the diagnostics file is written only while
    /// the switch is on, holds only allowlisted typed lines after a synthetic capture, recognition and
    /// export, keeps its file when the switch goes off, and Delete removes it. The file lives in this
    /// run's work directory, never in `~/Library/Logs`, and Show in Finder is never pressed.
    @MainActor
    enum DiagnosticsScenarios {
        /// Text drawn in the synthetic notes window; none of it may reach the file.
        static let planted = [
            SyntheticDesktop.secretText, "sk-live", "API key", "Quarterly", "Relatório", "trimestral", "Notes",
        ]

        static func file(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let diagnostics = try context.unwrap("the harness has a diagnostics recorder", harness.features.diagnostics)
            let log = diagnostics.log
            try context.require(
                "the diagnostics file is in this run's folder, not ~/Library/Logs",
                log.directory.standardizedFileURL.path.hasPrefix(harness.output.workDirectory.standardizedFileURL.path),
                log.directory.path)
            diagnostics.setOn(false)
            await diagnostics.delete()
            defer { diagnostics.setOn(false) }

            let offCapture = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            _ = await E2EActions.export(offCapture, .copy)
            await diagnostics.flush()
            context.check(
                "with the switch off a capture and an export write nothing", !(await diagnostics.fileExists()))

            let foreground = try await E2EForegroundFixture.start(context)
            defer { foreground.requestStop() }
            let window = SettingsWindowController.makeWindow(model: harness.app)
            window.appearance = NSAppearance(named: .aqua)
            defer { window.close() }
            let root = try context.unwrap("settings window has content", window.contentView)
            let tabs = try context.unwrap("Settings tab view", EditorWindowController.first(NSTabView.self, in: root))
            tabs.selectTabViewItem(at: 5)
            let pane = try context.unwrap("the Privacy pane", tabs.selectedTabViewItem?.view)
            window.setContentSize(NSSize(width: 560, height: pane.fittingSize.height))
            window.center(on: ScreenChoice.screen())
            func activate() async throws {
                if !E2EForegroundFixture.runnerIsForeground {
                    try await foreground.restore()
                    try await foreground.yieldToRunner()
                }
                try await E2EAccessibilityControl.showAndActivate(window, context)
            }
            func press(_ identifier: String) async throws {
                try await activate()
                try E2EAccessibilityControl.click(identifier, in: pane, context)
                await E2ESnapshot.settle(root)
            }
            // Settings writes and deletes from its own tasks: wait on the disk, then let the pane
            // read the new state.
            func fileOnDisk() -> Bool {
                [log.fileURL, log.previousFileURL].contains { FileManager.default.fileExists(atPath: $0.path) }
            }
            func settle(untilFileExists expected: Bool) async -> Bool {
                let reached = await E2EWait.until { fileOnDisk() == expected }
                await E2ESnapshot.settle(root, for: .milliseconds(300))
                return reached
            }
            try await activate()
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "the switch is off and Show in Finder and Delete are unavailable without a file",
                !harness.settings.preferences.writesDiagnosticsFile
                    && (try? E2EAccessibilityControl.isEnabled("settings.diagnostics.show", in: pane, context)) == false
                    && (try? E2EAccessibilityControl.isEnabled("settings.diagnostics.delete", in: pane, context))
                        == false
            )

            try await press("settings.diagnostics")
            context.check("the switch turns diagnostics on", harness.settings.preferences.writesDiagnosticsFile)
            context.check("turning it on starts the file", await settle(untilFileExists: true))
            context.check(
                "with a file, Show in Finder and Delete become available",
                (try? E2EAccessibilityControl.isEnabled("settings.diagnostics.show", in: pane, context)) == true
                    && (try? E2EAccessibilityControl.isEnabled("settings.diagnostics.delete", in: pane, context))
                        == true
            )
            context.snapshot(pane, shot: "privacy-diagnostics")

            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            await controller.model.recognizeText()
            let recognized = controller.model.recognizedText(mode: .raw) ?? ""
            let readBack = planted.filter { recognized.contains($0) }
            context.check(
                "recognition read planted text from the capture, so its absence below means something",
                !readBack.isEmpty, recognized)
            let copied = await E2EActions.export(controller, .copy)
            context.check("the copy succeeds", copied == .copied, "\(copied)")
            try await activate()

            await diagnostics.flush()
            let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
            let shape =
                #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z [a-z_]+(\.[a-z_]+)+( [a-z_]+=(-?[0-9]+(\.[0-9]+)*|[a-z_]+))*$"#
            let names = lines.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
            context.check(
                "every line is time, an allowlisted event name and typed values",
                lines.allSatisfy { $0.range(of: shape, options: .regularExpression) != nil }
                    && names.count == lines.count && Set(names).isSubset(of: DiagnosticEvent.names),
                lines.joined(separator: " | "))
            for expected in ["diagnostics.turned_on", "capture.started", "capture.finished", "ocr.finished"] {
                context.check("the file records \(expected)", names.contains(expected), names.joined(separator: ","))
            }
            context.check(
                "the copy is recorded as a finished clipboard export",
                lines.contains { $0.contains(" export.finished sink=clipboard format=png ") },
                lines.joined(separator: " | "))
            let text = lines.joined(separator: "\n")
            for secret in planted + [harness.output.workDirectory.path, "/"] {
                context.check("the file never contains \(secret.debugDescription)", !text.contains(secret))
            }

            try await press("settings.diagnostics")
            context.check("the switch turns diagnostics off", !harness.settings.preferences.writesDiagnosticsFile)
            let afterOff = try String(contentsOf: log.fileURL, encoding: .utf8)
            _ = await E2EActions.export(controller, .copy)
            await diagnostics.flush()
            context.check("turning it off keeps the file", await settle(untilFileExists: true))
            context.check(
                "with the switch off nothing more is written",
                (try? String(contentsOf: log.fileURL, encoding: .utf8)) == afterOff)

            try await press("settings.diagnostics.delete")
            context.check("Delete removes the file", await settle(untilFileExists: false))
            context.check(
                "no diagnostics file is left in the folder",
                ((try? FileManager.default.contentsOfDirectory(atPath: log.directory.path)) ?? []).isEmpty)
            context.check(
                "without a file, Delete is unavailable again",
                (try? E2EAccessibilityControl.isEnabled("settings.diagnostics.delete", in: pane, context)) == false)
            await foreground.stop(context)
        }
    }
#endif
