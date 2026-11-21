#if DEBUG
    import AppKit
    import Darwin
    import Domain
    import Features
    import MacPlatform

    /// A-13 step 2: capture windows built on demand ("current") against pre-built ones
    /// ("prebuilt"), in one run, samples interleaved so neither mode always goes first. The numbers
    /// are evidence for SPEC §10 and never fail the scenario; it fails only when a pre-built window
    /// breaks an invariant (presence, switchers, Space policy, quit, last window, pixels).
    ///
    /// Overlay: shortcut handler entry (`perform(.captureRegion)`) through the coordinator and
    /// `CaptureUIController` to the overlay panel's first drawn frame. "Cold" is a capture UI built
    /// for the sample (as at launch, after its pre-build in prebuilt mode); "warm" repeats a capture
    /// on one capture UI. Editor: a decoded document handed to `EditorWindowController` to its
    /// window's first frame, and to the canvas's first draw of the image; the capture itself is
    /// synthetic and excluded. Only the run's very first editor sample is process-cold.
    ///
    /// Windows are transparent and ignore the mouse, as in `window-latency`; a region overlay still
    /// becomes key for each sample, as in production, so run this on an idle console.
    @MainActor
    enum PrebuiltWindowScenarios {
        static let samples = 20

        enum Mode: String, CaseIterable {
            case current, prebuilt
            var prebuilds: Bool { self == .prebuilt }
        }

        static func latency(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            harness.reset()
            defer { harness.reset() }
            let displays = harness.capture.displays()
            try context.require(
                "the capture displays map to connected screens",
                !displays.isEmpty && displays.allSatisfy { $0.screen != nil })

            var footprints: [String: Double] = [:]
            try await checkSpares(harness, context, displays: displays, footprints: &footprints)
            try await checkReuse(harness, context, displays: displays)

            var series: [String: [Double]] = [:]
            func order(_ index: Int) -> [Mode] { index.isMultiple(of: 2) ? Mode.allCases : Mode.allCases.reversed() }

            for index in 0..<samples {
                for mode in order(index) {
                    let overlay = makeOverlay(mode)
                    let ui = CaptureUIController(coordinator: harness.features.capture, overlay: overlay)
                    ui.prepareOverlays(displays)
                    series["overlay.cold.\(mode.rawValue)", default: []].append(
                        try await overlaySample(harness, ui, overlay))
                }
            }

            // Warm: each mode keeps one overlay controller; a capture UI around it per sample, so
            // only one capture UI observes the coordinator at a time.
            let warm = Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, makeOverlay($0)) })
            for overlay in warm.values {
                let ui = CaptureUIController(coordinator: harness.features.capture, overlay: overlay)
                ui.prepareOverlays(displays)
                _ = try await overlaySample(harness, ui, overlay)
            }
            for index in 0..<samples {
                for mode in order(index) {
                    let overlay = try context.unwrap("the \(mode.rawValue) warm overlay exists", warm[mode])
                    let ui = CaptureUIController(coordinator: harness.features.capture, overlay: overlay)
                    series["overlay.warm.\(mode.rawValue)", default: []].append(
                        try await overlaySample(harness, ui, overlay))
                }
            }

            let spares = Dictionary(
                uniqueKeysWithValues: Mode.allCases.map { mode in
                    (
                        mode,
                        WindowSparePool<Int, NSWindow>(isEnabled: mode.prebuilds) { _ in
                            EditorWindowController.makeWindow()
                        }
                    )
                })
            var firstEditor: [String: Double] = [:]
            for index in 0..<samples {
                for mode in order(index) {
                    let pool = try context.unwrap("the \(mode.rawValue) editor pool exists", spares[mode])
                    let refill = ContinuousClock.now
                    pool.prepare([0])
                    if mode.prebuilds { series["editor.spareBuild", default: []].append(milliseconds(since: refill)) }
                    let (window, image) = try await editorSample(
                        harness, pool: pool, name: "prebuilt-\(mode)-\(index).png")
                    if firstEditor[mode.rawValue] == nil { firstEditor[mode.rawValue] = window }
                    series["editor.window.\(mode.rawValue)", default: []].append(window)
                    series["editor.image.\(mode.rawValue)", default: []].append(image)
                }
            }

            for (name, values) in series.sorted(by: { $0.key < $1.key }) {
                context.check("measured \(name) (evidence, not a budget)", values.count >= samples, summary(values))
            }
            for (mode, ms) in firstEditor.sorted(by: { $0.key < $1.key }) {
                context.check("measured editor.first.\(mode) (evidence)", true, "\(format(ms)) ms")
            }
            for (name, mib) in footprints.sorted(by: { $0.key < $1.key }) {
                context.check("measured \(name) footprint (evidence)", true, "\(format(mib)) MiB")
            }

            var report: [String: Any] = ["samples": samples, "firstEditorMs": firstEditor, "footprintMiB": footprints]
            report["series"] = series.mapValues { values -> [String: Any] in
                [
                    "p50": percentile(values, 0.5), "p95": percentile(values, 0.95), "max": values.max() ?? 0,
                    "ms": values,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: context.output.workDirectory.appending(path: "prebuilt-windows.json"))
            E2ERunner.log(
                "prebuilt windows: "
                    + series.keys.sorted().map { "\($0) \(summary(series[$0] ?? []))" }.joined(separator: "; "))
        }

        // MARK: Invariants

        /// Pre-built spares exist and are invisible to every rule that counts windows.
        private static func checkSpares(
            _ harness: E2EHarness, _ context: ScenarioContext, displays: [DisplayInfo],
            footprints: inout [String: Double]
        ) async throws {
            let presence = AppPresence.shared
            let policyBefore = NSApp.activationPolicy()
            let userWindowBefore = presence.hasUserWindow

            var before = footprint()
            let overlay = makeOverlay(.prebuilt)
            overlay.prepare(displays: displays)
            footprints["overlay spares (\(displays.count) display(s), drawn)"] = mebibytes(footprint() - before)
            before = footprint()
            let editors = EditorWindowManager(prebuildsSpare: true)
            editors.prepareSpare()
            footprints["editor spare shell"] = mebibytes(footprint() - before)

            let overlaySpare = try context.unwrap(
                "pre-building keeps a hidden overlay panel for the display", displays.first.flatMap(overlay.spare(for:))
            )
            let editorSpare = try context.unwrap("pre-building keeps a spare editor window", editors.spareWindow)
            let onScreen = Set((NSWindow.windowNumbers(options: []) ?? []).map(\.intValue))
            for (name, spare) in [("the overlay spare", overlaySpare as NSWindow), ("the editor spare", editorSpare)] {
                context.check(
                    "\(name) is not on screen or minimized, so window switchers cannot list it",
                    !spare.isVisible && !spare.isMiniaturized && !onScreen.contains(spare.windowNumber),
                    "visible=\(spare.isVisible) minimized=\(spare.isMiniaturized)")
                context.check("\(name) is not a switchable window", !AppPresence.isSwitchable(spare))
                context.check(
                    "\(name) is not left for the Space policy monitor to adopt", !SpacePolicy.needsAdoption(spare),
                    "\(spare.collectionBehavior.rawValue)")
            }
            context.check(
                "the overlay spare joins all Spaces and stays nonactivating from construction",
                overlaySpare.collectionBehavior.contains(.canJoinAllSpaces)
                    && overlaySpare.styleMask.contains(.nonactivatingPanel))
            context.check(
                "the editor spare follows the active Space from construction",
                editorSpare.collectionBehavior == SpacePolicy.followsActiveSpace)
            context.check(
                "the editor spare holds no document, view or pixels",
                editorSpare.contentViewController == nil && editorSpare.contentView?.subviews.isEmpty != false)
            context.check("the editor spare is not an editor with unexported edits", editors.unexportedEditCount == 0)

            presence.setNeedsRefresh()
            await settle()
            context.check(
                "spares do not count as a window the person can return to (presence, quit)",
                presence.hasUserWindow == userWindowBefore, "before=\(userWindowBefore) now=\(presence.hasUserWindow)")
            context.check(
                "spares leave the activation policy alone", NSApp.activationPolicy() == policyBefore,
                "before=\(policyBefore.rawValue) now=\(NSApp.activationPolicy().rawValue)")

            let original = presence.onLastWindowClosed
            var lastWindowReports = 0
            presence.onLastWindowClosed = { lastWindowReports += 1 }
            defer { presence.onLastWindowClosed = original }
            overlay.prepare(displays: [])  // a display change that drops the spare
            editorSpare.close()
            overlaySpare.close()
            presence.setNeedsRefresh()
            await settle()
            context.check("dropping or closing a spare is never the last window closing", lastWindowReports == 0)
        }

        /// A reused panel is the pre-built one, starts without the last selection, and a changed
        /// display replaces it.
        private static func checkReuse(_ harness: E2EHarness, _ context: ScenarioContext, displays: [DisplayInfo])
            async throws
        {
            let display = try context.unwrap("a capture display", displays.first)
            let overlay = makeOverlay(.prebuilt)
            let ui = CaptureUIController(coordinator: harness.features.capture, overlay: overlay)
            ui.prepareOverlays(displays)
            let spare = try context.unwrap("the display has a pre-built panel", overlay.spare(for: display))

            harness.app.perform(.captureRegion)
            try await waitFor("the region overlay appears") { overlay.isPresented }
            let shown = try context.unwrap("the capture shows a panel", overlay.presentedWindows.first)
            context.check("the capture shows the pre-built panel", shown === spare)
            context.check("a shown panel is no longer held as a spare", overlay.spare(for: display) == nil)
            let view = shown.selectionView
            view.mouseDown(with: try CaptureScenarios.mouseEvent(.leftMouseDown, at: CGPoint(x: 40, y: 40), in: view))
            view.mouseDragged(
                with: try CaptureScenarios.mouseEvent(.leftMouseDragged, at: CGPoint(x: 200, y: 160), in: view))
            try context.require("the drag started a selection", view.hasSelection)
            harness.features.capture.cancel()  // what Escape does mid-drag
            try await waitFor("the region overlay hides") { !overlay.isPresented }
            context.check(
                "a dismissed panel is hidden and kept for the next capture",
                !shown.isVisible && overlay.spare(for: display) === shown)
            context.check("a kept panel forgets the unfinished drag", !view.hasSelection)

            harness.app.perform(.captureRegion)
            try await waitFor("the region overlay appears again") { overlay.isPresented }
            context.check(
                "the next capture reuses the panel without a selection",
                overlay.presentedWindows.first === shown && !view.hasSelection)
            harness.features.capture.cancel()
            try await waitFor("the region overlay hides again") { !overlay.isPresented }

            let changed = DisplayInfo(
                id: display.id, frame: display.frame, pointPixelScale: display.pointPixelScale,
                fingerprint: display.fingerprint + "-changed")
            ui.prepareOverlays([changed])
            context.check(
                "a display change replaces the panel built for the old configuration",
                overlay.spare(for: display) == nil && overlay.spare(for: changed) != nil
                    && overlay.spare(for: changed) !== shown)
        }

        // MARK: Samples

        private static func makeOverlay(_ mode: Mode) -> RegionOverlayController {
            RegionOverlayController(prebuilds: mode.prebuilds) { display, screen in
                let window = OverlayWindow(display: display, screen: screen)
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                return window
            }
        }

        /// Shortcut handler entry to the overlay's first drawn frame; then cancels and waits for dismissal.
        private static func overlaySample(
            _ harness: E2EHarness, _ ui: CaptureUIController, _ overlay: RegionOverlayController
        ) async throws -> Double {
            let start = ContinuousClock.now
            harness.app.perform(.captureRegion)
            try await waitFor("the region overlay appears") { overlay.isPresented }
            for window in overlay.presentedWindows { window.displayIfNeeded() }
            let ms = milliseconds(since: start)
            harness.features.capture.cancel()
            try await waitFor("the region overlay hides") { !overlay.isPresented }
            withExtendedLifetime(ui) {}
            await settle()
            return ms
        }

        /// A decoded document to its editor window's first frame, and to the canvas's first image draw.
        private static func editorSample(_ harness: E2EHarness, pool: WindowSparePool<Int, NSWindow>, name: String)
            async throws -> (window: Double, image: Double)
        {
            let session = try await LatencyScenarios.importedSession(harness, name: name)
            let start = ContinuousClock.now
            let controller = EditorWindowController(
                model: EditorModel(session: session, environment: harness.environment), window: pool.take(0))
            guard let window = controller.window else { throw E2EAbort("the editor has no window") }
            defer { window.close() }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            window.displayIfNeeded()
            let windowMs = milliseconds(since: start)
            let deadline = ContinuousClock.now + .seconds(15)
            while !controller.model.isBaseCurrent {
                guard ContinuousClock.now < deadline else { throw E2EAbort("the editor's image did not render") }
                try await Task.sleep(for: .milliseconds(1))
            }
            controller.canvasView?.display()
            return (windowMs, milliseconds(since: start))
        }

        // MARK: Helpers

        /// Yields the main actor until `condition` holds, so the capture UI's observation turn runs
        /// without a polling delay inside the measured interval.
        private static func waitFor(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw E2EAbort("\(what): timed out") }
                await Task.yield()
            }
        }

        /// Lets coalesced presence refreshes and window restoration run.
        private static func settle() async {
            for _ in 0..<3 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(30))
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now)
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }

        private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }

        private static func summary(_ values: [Double]) -> String {
            "n=\(values.count) p50 \(format(percentile(values, 0.5))) ms; p95 \(format(percentile(values, 0.95))) ms; "
                + "max \(format(values.max() ?? 0)) ms"
        }

        private static func format(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(1)))
        }

        /// The process's physical footprint, as Activity Monitor's Memory column reports it.
        private static func footprint() -> Int64 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return result == 0 ? Int64(info.ri_phys_footprint) : 0
        }

        private static func mebibytes(_ bytes: Int64) -> Double { Double(bytes) / 1_048_576 }
    }
#endif
