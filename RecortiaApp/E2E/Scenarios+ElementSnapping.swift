#if DEBUG
    import AppKit
    import Domain
    import Features
    import MacPlatform

    /// Snapping a region selection to interface elements (FR-02, B-7, ADR-010) in the overlay's real
    /// selection view, with `SyntheticInterfaceElements` standing in for Accessibility: no real AX
    /// read and no TCC. Reports carry element counts only, never element frames.
    @MainActor
    enum ElementSnappingScenarios {
        static func snapping(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let coordinator = harness.features.capture
            let elements = harness.interfaceElements
            let choice = harness.settings.preferences.snapsToInterfaceElementsChoice
            let trusted = harness.accessibility.isTrusted
            defer {
                elements.holds = false
                elements.releaseAll()
                harness.accessibility.isTrusted = trusted
                harness.settings.update { $0.snapsToInterfaceElementsChoice = choice }
            }
            let accessibilityRequests = harness.accessibility.requestCount
            let screenRequests = harness.permission.requestCount
            let selection = RegionSelectionView(display: harness.capture.display)
            let window = E2ESnapshot.host(nsView: selection, size: SyntheticDesktop.size)
            defer { window.close() }
            var committed: [Rect<DesktopSpace>] = []
            selection.onCommit = { rect, display in
                committed.append(rect)
                coordinator.commitRegion(rect, on: display)
            }
            selection.onCancel = { coordinator.cancel() }
            let windowFrames = harness.capture.windowList.map(\.frame)
            let button = SyntheticInterfaceElements.button
            func elementCount() -> Int { max(0, coordinator.snapFrames.count - windowFrames.count) }

            func begin(_ label: String) async throws -> Int {
                let editors = harness.editors.controllers.count
                harness.app.perform(.captureRegion)
                try context.require(
                    "\(label): Capture Region starts selecting", coordinator.state == .selecting, "\(coordinator.state)"
                )
                try context.require(
                    "\(label): the selection lists the synthetic windows to snap to",
                    await E2EWait.until { coordinator.snapFrames.starts(with: windowFrames) },
                    "\(coordinator.snapFrames.count) frames")
                return editors
            }
            /// No read can still arrive: the coordinator reads elements right after the window list.
            func settled() async { try? await Task.sleep(for: .milliseconds(300)) }
            /// Drags the selection's right edge to 4 pt short of the button's right edge.
            func dragTowardButton() throws -> Double? {
                selection.snapFrames = coordinator.snapFrames
                selection.aspect = .free
                selection.mouseDown(with: try mouse(.leftMouseDown, 240, 200, in: selection))
                selection.mouseDragged(with: try mouse(.leftMouseDragged, button.maxX - 4, 360, in: selection))
                return selection.selection?.maxX
            }
            func escape() throws {
                selection.keyDown(with: try escapeEvent(in: selection))
                selection.clearSelection()
            }

            // Off, as by default: nothing is read and the edge does not move.
            harness.settings.update { $0.snapsToInterfaceElements = false }
            _ = try await begin("off")
            await settled()
            context.check("off: no element is read", elements.readCount == 0, "\(elements.readCount) reads")
            context.check("off: only window frames are snap targets", elementCount() == 0, "\(elementCount())")
            context.check("off: the edge does not snap to the button", try dragTowardButton() == button.maxX - 4)
            try escape()

            // On, with Accessibility not granted: no effect and no prompt.
            harness.settings.update { $0.snapsToInterfaceElements = true }
            harness.accessibility.isTrusted = false
            _ = try await begin("untrusted")
            await settled()
            context.check(
                "untrusted: no element frame reaches the selection", elementCount() == 0, "\(elementCount())")
            context.check("untrusted: the edge does not snap to the button", try dragTowardButton() == button.maxX - 4)
            try escape()
            harness.accessibility.isTrusted = true

            // On and trusted: the admitted elements join the window frames, and an edge snaps.
            let reads = elements.readCount
            let before = try await begin("on")
            try context.require(
                "on: the admitted element frames join the window frames",
                await E2EWait.until { elementCount() == SyntheticInterfaceElements.admittedCount },
                "\(elementCount()) element frames, \(elements.readCount - reads) reads")
            context.check(
                "on: an edge 4 pt away snaps to the button's edge", try dragTowardButton() == button.maxX)
            context.check(
                "on: one vertical guide shows on the snapped edge",
                selection.visibleGuides.count == 1 && selection.visibleGuides.first?.axis == .vertical,
                "\(selection.visibleGuides.count) guides")
            await E2ESnapshot.settle(selection)
            let light = context.snapshot(selection, shot: "element-snapped", over: harness.desktop)
            await context.darkOverlay(
                selection, in: window, shot: "element-snapped", over: harness.desktop, light: light)
            selection.mouseUp(with: try mouse(.leftMouseUp, button.maxX - 4, 360, in: selection))
            context.check("on: release commits the snapped selection", committed.last?.maxX == button.maxX)
            context.check(
                "on: the element frames are dropped with the selection", coordinator.snapFrames.isEmpty,
                "\(coordinator.snapFrames.count) frames")
            let controller = try await E2EActions.waitForNewEditor(harness, after: before, context)
            let geometry = try context.unwrap(
                "on: the capture carries geometry", CaptureScenarios.capturedGeometry(controller.model))
            context.check("on: the capture ends at the button's edge", geometry.desktopBounds.maxX == button.maxX)

            // A read that finishes after Escape is discarded.
            elements.holds = true
            _ = try await begin("escape")
            try context.require(
                "escape: the element read is in progress", await E2EWait.until { elements.waitingCount == 1 })
            try escape()
            elements.releaseOldest()
            await settled()
            context.check(
                "escape: the late read never reaches a selection",
                coordinator.state != .selecting && coordinator.snapFrames.isEmpty,
                "\(coordinator.state), \(coordinator.snapFrames.count) frames")

            // A read from a replaced request never reaches the next selection.
            _ = try await begin("first")
            try context.require(
                "replaced: the first read is in progress", await E2EWait.until { elements.waitingCount == 1 })
            _ = try await begin("second")
            try context.require(
                "replaced: the second read is in progress", await E2EWait.until { elements.waitingCount == 2 })
            elements.releaseOldest()
            await settled()
            context.check(
                "replaced: the first request's read is discarded", elementCount() == 0, "\(elementCount())")
            elements.releaseOldest()
            context.check(
                "replaced: the current request's read arrives",
                await E2EWait.until { elementCount() == SyntheticInterfaceElements.admittedCount },
                "\(elementCount())")
            try escape()

            context.check(
                "no capture asked for Accessibility",
                harness.accessibility.requestCount == accessibilityRequests,
                "\(harness.accessibility.requestCount - accessibilityRequests) requests")
            context.check(
                "no capture asked for Screen Recording", harness.permission.requestCount == screenRequests,
                "\(harness.permission.requestCount - screenRequests) requests")
        }

        private static func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, in view: NSView) throws
            -> NSEvent
        {
            try CaptureScenarios.mouseEvent(type, at: CGPoint(x: x, y: y), in: view)
        }

        private static func escapeEvent(in view: NSView) throws -> NSEvent {
            guard let window = view.window,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            else { throw E2EAbort("could not synthesize Escape") }
            return event
        }
    }
#endif
