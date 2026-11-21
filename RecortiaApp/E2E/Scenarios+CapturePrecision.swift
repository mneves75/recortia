#if DEBUG
    import AppKit
    import Domain
    import Features
    import MacPlatform

    /// Precise region selection (FR-02, A-4) in the overlay's real selection view over the
    /// synthetic desktop: keyboard nudges, the aspect control and Shift, and snapping to a frame from
    /// the synthetic window list. Synthetic mouse and key events go to the view as in
    /// `region-overlay`, and every commit goes to the coordinator as `CaptureUIController` wires it.
    @MainActor
    enum CapturePrecisionScenarios {
        static func precision(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let coordinator = harness.features.capture
            let selection = RegionSelectionView(display: harness.capture.display)
            let window = E2ESnapshot.host(nsView: selection, size: SyntheticDesktop.size)
            defer { window.close() }
            var committed: [Rect<DesktopSpace>] = []
            selection.onCommit = { rect, display in
                committed.append(rect)
                coordinator.commitRegion(rect, on: display)
            }
            selection.onAspectChange = { coordinator.setRegionAspect($0) }

            func begin(_ label: String) async throws -> Int {
                harness.app.perform(.captureRegion)
                try context.require(
                    "\(label): Capture Region starts selecting", coordinator.state == .selecting, "\(coordinator.state)"
                )
                try context.require(
                    "\(label): the selection lists the synthetic windows to snap to",
                    await E2EWait.until { coordinator.snapFrames == harness.capture.windowList.map(\.frame) },
                    "\(coordinator.snapFrames)")
                selection.snapFrames = coordinator.snapFrames
                selection.aspect = coordinator.regionAspect
                await E2ESnapshot.settle(selection)
                return harness.editors.controllers.count
            }
            func down(_ x: Double, _ y: Double) throws {
                selection.mouseDown(
                    with: try CaptureScenarios.mouseEvent(.leftMouseDown, at: CGPoint(x: x, y: y), in: selection))
            }
            func drag(_ x: Double, _ y: Double, _ modifiers: NSEvent.ModifierFlags = []) throws {
                selection.mouseDragged(
                    with: try CaptureScenarios.mouseEvent(
                        .leftMouseDragged, at: CGPoint(x: x, y: y), in: selection, modifiers: modifiers))
            }
            func up(_ x: Double, _ y: Double) throws {
                selection.mouseUp(
                    with: try CaptureScenarios.mouseEvent(.leftMouseUp, at: CGPoint(x: x, y: y), in: selection))
            }
            func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], times: Int = 1) throws {
                for _ in 0..<times { selection.keyDown(with: try keyEvent(code, modifiers, in: selection)) }
            }
            func choose(_ aspect: SelectionAspect) throws {
                let control = try context.unwrap(
                    "the overlay shows the aspect control",
                    EditorWindowController.all(NSSegmentedControl.self, in: selection).first {
                        $0.accessibilityLabel() == String(localized: "Aspect ratio")
                    })
                context.check(
                    "the aspect control lies inside the display",
                    selection.bounds.contains(control.frame) && !control.frame.isEmpty, "\(control.frame)")
                let index = try context.unwrap(
                    "the control offers \(aspect)", SelectionAspect.allCases.firstIndex(of: aspect))
                try context.require(
                    "the control offers Free, 1:1, 4:3, 16:9 and 3:2",
                    control.segmentCount == SelectionAspect.allCases.count)
                control.setSelected(true, forSegment: index)
                try context.require(
                    "the aspect control sends its action", control.sendAction(control.action, to: control.target))
            }
            func geometry(_ label: String, after count: Int) async throws -> CaptureGeometry {
                let controller = try await E2EActions.waitForNewEditor(harness, after: count, context)
                return try context.unwrap(
                    "\(label): capture carries geometry", CaptureScenarios.capturedGeometry(controller.model))
            }

            // Nudges: a drag, arrows during it, release, more arrows, then Return.
            var before = try await begin("nudge")
            try down(100, 60)
            for p in E2EActions.interpolate(Point(x: 100, y: 60), Point(x: 520, y: 300), count: 4) {
                try drag(p.x, p.y)
            }
            context.check(
                "the drag selects its area", selection.selection == Rect(x: 100, y: 60, width: 420, height: 240),
                "\(String(describing: selection.selection))")
            try key(124, times: 3)
            try key(125, .shift)
            try key(124, .option)
            try key(126, [.option, .shift])
            try up(520, 300)
            context.check("release after a nudge keeps the selection", committed.isEmpty, "\(committed)")
            context.check(
                "arrows move by 1 pt and 10 pt with Shift; Option resizes from the bottom-right edge",
                selection.selection == Rect(x: 103, y: 70, width: 421, height: 230),
                "\(String(describing: selection.selection))")
            try key(123, .shift, times: 12)
            context.check(
                "a nudge stops at the display edge", selection.selection == Rect(x: 0, y: 70, width: 421, height: 230),
                "\(String(describing: selection.selection))")
            await E2ESnapshot.settle(selection)
            let lightNudged = context.snapshot(selection, shot: "nudged", over: harness.desktop)
            await context.darkOverlay(selection, in: window, shot: "nudged", over: harness.desktop, light: lightNudged)
            try key(36)
            let nudged = Rect<DesktopSpace>(x: 0, y: 70, width: 421, height: 230)
            context.check("Return commits the nudged selection", committed == [nudged], "\(committed)")
            let nudgedCapture = try await geometry("nudge", after: before)
            context.check(
                "the capture covers the nudged selection", nudgedCapture.desktopBounds == nudged,
                "\(nudgedCapture.desktopBounds)")

            // Aspect: 16:9 from the control, a square while Shift is held, then 16:9 again.
            before = try await begin("aspect")
            try choose(.sixteenByNine)
            context.check(
                "the chosen ratio is remembered as a preference", coordinator.regionAspect == .sixteenByNine,
                "\(coordinator.regionAspect)")
            try down(100, 60)
            try drag(300, 200, .shift)
            context.check(
                "Shift while dragging keeps a square",
                selection.selection == Rect(x: 100, y: 60, width: 200, height: 200),
                "\(String(describing: selection.selection))")
            try drag(420, 160)
            try up(420, 160)
            let wide = Rect<DesktopSpace>(x: 100, y: 60, width: 320, height: 180)
            context.check("release commits the 16:9 selection", committed.last == wide, "\(committed)")
            let wideCapture = try await geometry("aspect", after: before)
            context.check(
                "the capture is 16:9 in display pixels", wideCapture.pixelSize == PixelSize(width: 640, height: 360),
                "\(wideCapture.pixelSize)")

            // Snapping: the right edge reaches the synthetic notes window; Command turns it off.
            before = try await begin("snap")
            context.check(
                "the next selection keeps the remembered ratio", selection.aspect == .sixteenByNine,
                "\(selection.aspect)")
            try choose(.free)
            let notes = try context.unwrap("the synthetic notes window is listed", harness.capture.windowList.first)
            try down(100, 60)
            try drag(notes.frame.maxX - 7, 300)
            context.check(
                "an edge 7 pt away does not snap", selection.selection?.maxX == notes.frame.maxX - 7,
                "\(String(describing: selection.selection))")
            try drag(notes.frame.maxX - 4, 300)
            context.check(
                "an edge 4 pt away snaps to the window's edge", selection.selection?.maxX == notes.frame.maxX,
                "\(String(describing: selection.selection))")
            context.check(
                "a guide shows on the snapped edge",
                selection.visibleGuides.map(\.position) == [notes.frame.maxX]
                    && selection.visibleGuides.first?.axis == .vertical,
                "\(selection.visibleGuides)")
            await E2ESnapshot.settle(selection)
            let lightSnapped = context.snapshot(selection, shot: "snapped", over: harness.desktop)
            await context.darkOverlay(
                selection, in: window, shot: "snapped", over: harness.desktop, light: lightSnapped)
            try drag(notes.frame.maxX - 4, 300, .command)
            context.check(
                "Command turns snapping off",
                selection.selection?.maxX == notes.frame.maxX - 4 && selection.visibleGuides.isEmpty,
                "\(String(describing: selection.selection)), \(selection.visibleGuides)")
            try drag(notes.frame.maxX - 4, 300)
            try up(notes.frame.maxX - 4, 300)
            let snapped = Rect<DesktopSpace>(x: 100, y: 60, width: notes.frame.maxX - 100, height: 240)
            context.check("release commits the snapped selection", committed.last == snapped, "\(committed)")
            let snappedCapture = try await geometry("snap", after: before)
            context.check(
                "the capture ends at the window's right edge", snappedCapture.desktopBounds.maxX == notes.frame.maxX,
                "\(snappedCapture.desktopBounds)")

            try await checkReusedPanel(harness, context)
        }

        /// A pre-built panel that a capture hides and the next one reuses (A-13 step 2) never
        /// carries the previous capture's snap drag, guide, held nudge, ratio drag or window frames.
        /// The panels are invisible and ignore the pointer, as in `prebuilt-windows`.
        private static func checkReusedPanel(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let coordinator = harness.features.capture
            let display = harness.capture.display
            try context.require("reuse: the synthetic display maps to a connected screen", display.screen != nil)
            let overlay = RegionOverlayController(prebuilds: true) { display, screen in
                let window = OverlayWindow(display: display, screen: screen)
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                return window
            }
            let ui = CaptureUIController(coordinator: coordinator, overlay: overlay)
            defer { withExtendedLifetime(ui) {} }
            ui.prepareOverlays([display])
            let spare = try context.unwrap("reuse: the display has a pre-built panel", overlay.spare(for: display))
            let view = spare.selectionView
            func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws -> NSEvent {
                try CaptureScenarios.mouseEvent(type, at: CGPoint(x: x, y: y), in: view)
            }
            func show(_ label: String) async throws {
                harness.app.perform(.captureRegion)
                try context.require(
                    "reuse, \(label): the capture shows the pre-built panel with the listed windows",
                    await E2EWait.until { overlay.presentedWindows.first === spare && !view.snapFrames.isEmpty })
            }
            func hide(_ label: String) async throws {
                coordinator.cancel()
                try context.require(
                    "reuse, \(label): the panel hides", await E2EWait.until { !overlay.isPresented })
                context.check(
                    "reuse, \(label): the kept panel forgets the selection, its guides and the window frames",
                    overlay.spare(for: display) === spare && !view.hasSelection && view.visibleGuides.isEmpty
                        && view.snapFrames.isEmpty,
                    "selection=\(String(describing: view.selection)), guides=\(view.visibleGuides.count), "
                        + "frames=\(view.snapFrames.count)")
            }

            // A drag that snaps to the display's right edge, cancelled mid-drag.
            try await show("snap")
            view.mouseDown(with: try mouse(.leftMouseDown, 40, 40))
            view.mouseDragged(with: try mouse(.leftMouseDragged, view.bounds.maxX - 3, 160))
            try context.require("reuse: the drag snaps with a guide", !view.visibleGuides.isEmpty)
            try await hide("snap")

            // A 16:9 drag held by a nudge after release.
            coordinator.setRegionAspect(.sixteenByNine)
            try await show("nudge")
            context.check("reuse: the panel shows the remembered ratio", view.aspect == .sixteenByNine)
            view.mouseDown(with: try mouse(.leftMouseDown, 40, 40))
            view.mouseDragged(with: try mouse(.leftMouseDragged, 200, 100))
            view.keyDown(with: try keyEvent(124, [], in: view))
            view.mouseUp(with: try mouse(.leftMouseUp, 200, 100))
            try context.require("reuse: the nudge holds the selection after release", view.hasSelection)
            try await hide("nudge")

            try await show("next")
            context.check(
                "reuse: the next capture starts without a selection or guide",
                view.selection == nil && view.visibleGuides.isEmpty, "\(String(describing: view.selection))")
            try await hide("next")

            coordinator.setRegionAspect(.free)
            let reads = harness.capture.captures.count
            let editors = harness.editors.controllers.count
            try await show("freeze")
            let liveInstruction = String(localized: "Press F to freeze this display and use the magnifier.")
            let frozenInstruction = String(localized: "Display frozen. Press F to return to live selection.")
            try context.require(
                "freeze is offered without reading the display",
                view.accessibilityHelp()?.contains(liveInstruction) == true && harness.capture.captures.count == reads)
            func toggle(_ instruction: String) async throws {
                view.keyDown(with: try keyEvent(3, [], in: view))
                try context.require(
                    "the freeze key updates the overlay: \(instruction)",
                    await E2EWait.until { view.accessibilityHelp()?.contains(instruction) == true })
            }
            try await toggle(frozenInstruction)
            view.mouseMoved(with: try mouse(.mouseMoved, 110, 130))
            let magnified = try E2ESnapshot.png(of: view, over: harness.desktop)
            view.mouseMoved(with: try mouse(.mouseMoved, 240, 210))
            let moved = context.snapshot(view, shot: "frozen-magnifier", over: harness.desktop)
            context.check("the frozen magnifier follows the pointer", moved.map { $0 != magnified } == true)
            await context.darkOverlay(view, in: spare, shot: "frozen-magnifier", over: harness.desktop, light: moved)
            try await toggle(liveInstruction)
            try context.require("unfreezing releases the original preview", coordinator.regionFreeze == nil)
            try await toggle(frozenInstruction)

            let start = CGPoint(x: 60, y: 100)
            let end = CGPoint(x: 260, y: 220)
            view.mouseDown(with: try mouse(.leftMouseDown, start.x, start.y))
            view.mouseDragged(with: try mouse(.leftMouseDragged, end.x, end.y))
            view.mouseUp(with: try mouse(.leftMouseUp, end.x, end.y))
            let editor = try await E2EActions.waitForNewEditor(harness, after: editors, context)
            try context.require(
                "freeze and refreeze read the display once each and commit does not read it again",
                Array(harness.capture.captures.dropFirst(reads)) == [.display(display), .display(display)])
            try context.require("the frozen panel was retired", await E2EWait.until { !overlay.isPresented })
            context.check(
                "a panel that showed a frozen frame is not kept as a spare", overlay.spare(for: display) == nil)
            let geometry = try context.unwrap(
                "the crop carries geometry", CaptureScenarios.capturedGeometry(editor.model))
            let copied = try await E2EActions.copiedPixels(editor, harness, context, "frozen crop")
            let desktop = try E2EActions.pixels(of: harness.desktop, "synthetic frozen display", context)
            let left = Int(((geometry.desktopBounds.minX - display.frame.minX) * geometry.pointPixelScale).rounded())
            let top = Int(((geometry.desktopBounds.minY - display.frame.minY) * geometry.pointPixelScale).rounded())
            try context.require(
                "the copied crop is the selected bounds within the display",
                copied.width == geometry.pixelSize.width && copied.height == geometry.pixelSize.height
                    && left >= 0 && top >= 0 && left + copied.width <= desktop.width
                    && top + copied.height <= desktop.height)
            for (x, y) in [(0, 0), (copied.width / 2, copied.height / 2), (copied.width - 1, copied.height - 1)] {
                context.check(
                    "the frozen crop keeps source pixel \(x), \(y)",
                    copied.pixel(x: x, y: y) == desktop.pixel(x: left + x, y: top + y))
            }
        }

        private static func keyEvent(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, in view: NSView) throws
            -> NSEvent
        {
            let arrows: [UInt16: Int] = [
                123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey,
                126: NSUpArrowFunctionKey,
            ]
            let characters =
                arrows[code].flatMap { UnicodeScalar($0) }.map { String(Character($0)) }
                ?? (code == 3 ? "f" : "\r")
            let flags = arrows[code] == nil ? modifiers : modifiers.union([.numericPad, .function])
            guard let window = view.window,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { throw E2EAbort("could not synthesize key \(code)") }
            return event
        }
    }
#endif
