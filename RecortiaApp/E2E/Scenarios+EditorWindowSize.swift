#if DEBUG
    import AppKit
    import Domain
    import Features

    /// The editor opens at one consistent size whatever was captured (owner report 2026-10-16:
    /// "after screenshoting something, the window always appears in different width / sizes").
    /// The harness parks its editors at a fixed snapshot size, so each check builds a probe
    /// controller with the app's own initializer and reads the size it chose.
    @MainActor
    enum EditorWindowSizeScenarios {
        static func consistentSize(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let smallSize = try await probeSize(
                harness, capturing: CGRect(x: 200, y: 160, width: 240, height: 120), "small capture", context)
            let largeSize = try await probeSize(
                harness, capturing: CGRect(x: 120, y: 100, width: 1200, height: 760), "large capture", context)
            context.check(
                "a small and a large capture open editors of the same size", smallSize == largeSize,
                "small \(smallSize), large \(largeSize)")

            // The size the user leaves after resizing an editor is the next editor's size.
            defer { harness.settings.update { $0.editorContentSize = nil } }
            let resized = try await E2EActions.captureRegion(
                harness, CGRect(x: 300, y: 200, width: 400, height: 300), context)
            let window = try context.unwrap("resized editor window", resized.window)
            let chosen = NSSize(width: 1040, height: 640)
            window.setContentSize(chosen)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            window.close()
            let next = try await probeSize(
                harness, capturing: CGRect(x: 80, y: 60, width: 900, height: 600), "next capture", context)
            context.check(
                "the next editor opens at the size the user resized the last one to", next == chosen,
                "chosen \(chosen), next \(next)")
            context.check(
                "the chosen size is stored as a setting",
                harness.settings.preferences.editorContentSize == Size(width: 1040, height: 640),
                "\(String(describing: harness.settings.preferences.editorContentSize))")
        }

        /// Captures `rect`, then opens a probe editor for that capture with the production
        /// initializer and returns the content size it chose before anything resized it.
        private static func probeSize(
            _ harness: E2EHarness, capturing rect: CGRect, _ label: String, _ context: ScenarioContext
        ) async throws -> NSSize {
            let captured = try await E2EActions.captureRegion(harness, rect, context)
            let probe = EditorWindowController(
                model: EditorModel(session: captured.model.session, environment: captured.model.environment))
            let window = try context.unwrap("\(label) probe window", probe.window)
            let size = window.contentRect(forFrameRect: window.frame).size
            window.close()
            captured.window?.close()
            return size
        }
    }
#endif
