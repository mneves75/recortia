#if DEBUG
    import AppKit
    import Domain
    import Features
    import MacPlatform

    /// These scenarios run on the host desktop without creating Spaces. Focus/presentation use an owned synthetic
    /// foreground process; no unrelated application may be driven. Checks marked
    /// "configured" read a window's `collectionBehavior`: they guard the policy, not what macOS
    /// does with it. Real Space switching, fullscreen-Space placement, and physical keyboard
    /// outcomes are covered only by the owner-run physical probe in `scripts/space-probe`
    /// (macOS 27) and dedicated-desktop qualification. The owned foreground and cooperative
    /// activation controls must succeed before synthetic focus results qualify.
    @MainActor
    enum CaptureVisibilityScenarios {
        private static func configureKeyboardFixture(_ window: OverlayWindow, screen: NSScreen) {
            window.alphaValue = 1
            window.ignoresMouseEvents = true
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(SyntheticDesktop.size)
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
        }

        private final class ActivationProbe {
            var appActivationCount = 0
            var foregroundPIDs: [pid_t] = []
            var keyEvents: [String] = []
            var keyEventsTruncated = false
            var observedWindows = 0

            func recordKeyEvent(_ event: String) {
                guard keyEvents.count < 64 else {
                    keyEventsTruncated = true
                    return
                }
                keyEvents.append(event)
            }
        }

        static func editorPresentation(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let foregroundFixture = try await E2EForegroundFixture.start(context)
            defer { foregroundFixture.requestStop() }
            var controller: EditorWindowController?
            let originalOpenDocument = harness.app.openDocument
            harness.app.openDocument = { session in
                let model = EditorModel(session: session, environment: harness.environment)
                let opened = EditorWindowController(model: model)
                // Exercise production presentation without exposing desktop pixels or
                // intercepting real input. Snapshots render this synthetic view only.
                opened.window?.alphaValue = 1
                opened.window?.ignoresMouseEvents = true
                controller = opened
                opened.present()
                return model
            }
            defer {
                harness.app.openDocument = originalOpenDocument
                controller?.window?.close()
                NSApp.unhideWithoutActivation()
            }
            NSApp.hide(nil)
            try context.require("the app starts hidden", await E2EWait.until { NSApp.isHidden })
            harness.app.perform(.captureRegion)
            try context.require("selection starts", harness.features.capture.state == .selecting)
            try context.require(
                "synthetic region commits",
                harness.features.capture.commitRegion(
                    Rect(x: 0, y: 0, width: 300, height: 200), on: harness.capture.display))
            try context.require("completion creates the real controller", await E2EWait.until { controller != nil })
            let opened = try context.unwrap("the editor exists", controller)
            let window = try context.unwrap("the editor has a window", opened.window)
            await E2ESnapshot.settle(window.contentView)
            context.check("capture unhides the application", !NSApp.isHidden)
            context.check("capture editor is ordered onscreen", window.isVisible)
            context.check(
                "capture editor is on the active Space (observed on this single desktop)", window.isOnActiveSpace)
            context.check("capture editor uses the normal window level", window.level == .normal)
            context.check(
                "capture editor is an ordinary activating window", !window.styleMask.contains(.nonactivatingPanel))
            context.check(
                "capture editor is configured to follow the active Space (collectionBehavior only)",
                window.collectionBehavior.contains(.moveToActiveSpace))
            context.check(
                "capture editor is configured as fullscreen-auxiliary (collectionBehavior only)",
                window.collectionBehavior.contains(.fullScreenAuxiliary))
            let canvas = try context.unwrap("hosted layout attaches the canvas", opened.canvasView)
            context.check(
                "the editor installs its canvas responder", window.firstResponder === canvas,
                "responder=\(String(describing: window.firstResponder))")
            context.check(
                "the editor is configured without fullscreen-primary (collectionBehavior only)",
                !window.collectionBehavior.contains(.fullScreenPrimary))
            let content = try context.unwrap("the editor hosts content", window.contentView)
            context.snapshot(content, shot: "presented-editor", over: harness.desktop)

            window.miniaturize(nil)
            try context.require("the existing editor is minimized", await E2EWait.until { window.isMiniaturized })
            opened.present()
            await E2ESnapshot.settle(window.contentView)
            context.check("presenting an existing editor restores it", !window.isMiniaturized && window.isVisible)

            window.orderBack(nil)
            try await foregroundFixture.cover(window.frame)
            let foreground = foregroundFixture.processIdentifier
            try context.require(
                "presentation starts behind the owned foreground application",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && !NSApp.isActive)
            try context.require(
                "the covered editor is ordered on the active display", window.isVisible && window.isOnActiveSpace)
            try context.require(
                "negative visibility control: the opaque host fully occludes the editor",
                await E2EWait.until { !window.occlusionState.contains(.visible) })
            opened.present()
            await E2ESnapshot.settle(window.contentView)
            context.check("inactive presentation still orders the editor", window.isVisible && window.isOnActiveSpace)
            context.check("the inactive ordering case receives no cooperative activation", !NSApp.isActive)
            let inFront = await E2EWait.until(timeout: .seconds(3)) { window.occlusionState.contains(.visible) }
            context.check(
                "inactive presentation puts the opaque editor in front of the known cover", inFront,
                "occlusion=\(window.occlusionState.rawValue); active=\(NSApp.isActive); key=\(window.isKeyWindow)")
            context.check("presentation preserves the document", !opened.model.isClosed)
            try await foregroundFixture.restore()
            try await foregroundFixture.yieldToRunner()
            opened.present()
            try context.require(
                "the cooperative activation control activates the editor", await E2EWait.until { NSApp.isActive })
            context.check("an activated editor owns the keyboard", window.isKeyWindow)
            context.check("the activated editor retains its canvas responder", window.firstResponder === canvas)
            await foregroundFixture.stop(context)
        }

        /// Counts `didBecomeActive` for `app` and records the pid of every application the
        /// workspace reports as activated. The scenario and its wiring control share this code.
        /// Returns the removal action.
        private static func observeActivations(
            _ probe: ActivationProbe, app: AnyObject, center: NotificationCenter, workspace: NotificationCenter
        ) -> () -> Void {
            let appObserver = center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: app, queue: .main
            ) { _ in MainActor.assumeIsolated { probe.appActivationCount += 1 } }
            let workspaceObserver = workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated { if let pid { probe.foregroundPIDs.append(pid) } }
            }
            return {
                center.removeObserver(appObserver)
                workspace.removeObserver(workspaceObserver)
            }
        }

        static func shortcutFocus(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let foregroundFixture = try await E2EForegroundFixture.start(context)
            defer { foregroundFixture.requestStop() }
            let display = try context.unwrap(
                "a connected display is available", DesktopGeometry.displays().first)
            let probe = ActivationProbe()
            var keyObservers: [NSObjectProtocol] = []
            defer { keyObservers.forEach(NotificationCenter.default.removeObserver) }
            var created: OverlayWindow?
            let overlay = RegionOverlayController { display, screen in
                let window = OverlayWindow(display: display, screen: screen)
                configureKeyboardFixture(window, screen: screen)
                probe.observedWindows += 1
                let ordinal = probe.observedWindows
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    keyObservers.append(
                        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                            MainActor.assumeIsolated {
                                probe.recordKeyEvent(
                                    "\(ProcessInfo.processInfo.systemUptime): window\(ordinal) \(name.rawValue)")
                            }
                        })
                }
                created = window
                return window
            }
            defer {
                overlay.dismiss()
                harness.features.capture.cancel()
            }

            // The known foreground process and all pixels belong to synthetic fixtures.
            // App-local key dispatch below does not qualify physical keyboard delivery.
            try await foregroundFixture.restore()
            let foreground = foregroundFixture.processIdentifier
            try context.require(
                "the shortcut starts in the known foreground process",
                foreground != ProcessInfo.processInfo.processIdentifier
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && !NSApp.isActive)
            let removeObservers = observeActivations(
                probe, app: NSApp, center: .default, workspace: NSWorkspace.shared.notificationCenter)
            defer { removeObservers() }
            harness.app.perform(.captureRegion)
            try context.require("the shortcut action starts selection", harness.features.capture.state == .selecting)
            probe.recordKeyEvent("\(ProcessInfo.processInfo.systemUptime): first present requested")
            overlay.present(displays: [display], notice: nil, allowsWindowSwitch: true)
            let window = try context.unwrap("the real region overlay was created", created)
            await E2ESnapshot.settle(window.selectionView)
            context.check(
                "region selection sends no application activation notification", probe.appActivationCount == 0,
                "notifications=\(probe.appActivationCount); isActive=\(NSApp.isActive)")
            context.check(
                "region selection never activates another foreground application",
                probe.foregroundPIDs.allSatisfy { $0 == foreground },
                "baseline=\(foreground); observed=\(probe.foregroundPIDs)")
            context.check(
                "region selection preserves the foreground application",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            let initialKey = window.isKeyWindow
            probe.recordKeyEvent("\(ProcessInfo.processInfo.systemUptime): initial key assertion=\(initialKey)")
            context.check(
                "the selection still receives keyboard input", initialKey,
                "visible=\(window.isVisible); keyWindowMatches=\(NSApp.keyWindow === window); "
                    + "responderMatches=\(window.firstResponder === window.selectionView); "
                    + "hidden=\(NSApp.isHidden); isActive=\(NSApp.isActive); "
                    + "policy=\(NSApp.activationPolicy().rawValue); "
                    + "foregroundUnchanged=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground); "
                    + "ownKeyWindow=\(NSApp.keyWindow?.windowNumber ?? -1); events=\(probe.keyEvents); "
                    + "traceTruncated=\(probe.keyEventsTruncated)")
            if !initialKey {
                // Collect recovery only after recording FAIL; two seconds is not a product timing allowance.
                let recovered = await E2EWait.until(timeout: .seconds(2)) { window.isKeyWindow }
                E2ERunner.log(
                    "capture-focus: recoveredWithin2s=\(recovered); at=\(ProcessInfo.processInfo.systemUptime); "
                        + "events=\(probe.keyEvents); traceTruncated=\(probe.keyEventsTruncated)")
            }
            context.check("the selection view owns the responder", window.firstResponder === window.selectionView)
            context.check(
                "the overlay can join the current Space", window.collectionBehavior.contains(.canJoinAllSpaces))
            context.check(
                "the overlay supports fullscreen Spaces", window.collectionBehavior.contains(.fullScreenAuxiliary))
            context.check(
                "the overlay does not activate the application", window.styleMask.contains(.nonactivatingPanel))
            context.check(
                "the keyboard fixture is onscreen with nonzero opacity",
                display.screen?.frame.intersects(window.frame) == true && window.alphaValue > 0)
            context.snapshot(window.selectionView, shot: "shortcut-selection", over: harness.desktop)

            var canceled = false
            overlay.onCancel = { [weak overlay] in
                canceled = true
                harness.features.capture.cancel()
                overlay?.dismiss()
            }
            try sendKey(53, characters: "\u{1b}", to: window)
            context.check("Escape cancels without quitting", canceled && harness.features.capture.state == .canceled)
            context.check("cancel removes all overlays", !overlay.isPresented && !window.isVisible)
            context.check(
                "cancellation preserves the foreground application",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)

            // A repeated presentation must remain usable without depending on AppKit allowing
            // a background process to activate itself (a real menu click is owner-only QA).
            overlay.present(displays: [display], notice: nil, allowsWindowSwitch: true)
            let repeatedWindow = try context.unwrap("the replacement overlay was created", created)
            await E2ESnapshot.settle(repeatedWindow.selectionView)
            context.check(
                "replacement selection preserves the foreground application",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            context.check(
                "replacement selection still receives keyboard input", repeatedWindow.isKeyWindow,
                "visible=\(repeatedWindow.isVisible); keyWindowMatches=\(NSApp.keyWindow === repeatedWindow); "
                    + "responderMatches=\(repeatedWindow.firstResponder === repeatedWindow.selectionView); "
                    + "isActive=\(NSApp.isActive); policy=\(NSApp.activationPolicy().rawValue); "
                    + "foregroundUnchanged=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)")
            overlay.onSwitchToWindow = { harness.features.capture.switchToWindowSelection() }
            harness.app.perform(.captureRegion)
            try sendKey(49, characters: " ", to: repeatedWindow)
            context.check("Space through AppKit switches to window selection", harness.features.capture.mode == .window)
            var committedDisplay: DisplayInfo?
            overlay.onCommit = { _, selected in committedDisplay = selected }
            try sendKey(36, characters: "\r", to: repeatedWindow)
            context.check("Return through AppKit selects the same display", committedDisplay == display)
            overlay.dismiss()
            await E2ESnapshot.settle(nil)
            context.check(
                "all keyboard transitions preserve the foreground application",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            context.check("no keyboard transition activates Recortia", probe.appActivationCount == 0)
            context.check(
                "no keyboard transition activates another app",
                probe.foregroundPIDs.allSatisfy { $0 == foreground })

            // Positive control: "== 0" and "allSatisfy" also hold when an observer is miswired or
            // its notification never arrives. Activating Recortia once on purpose must move both
            // probes, which shows the zero counts above could have been non-zero. The owned
            // host cooperates only in this positive-control phase.
            let own = ProcessInfo.processInfo.processIdentifier
            // Host-independent half: the same observers, on private notification centers, must
            // count a delivered activation and make the foreground comparison fail.
            let wiringProbe = ActivationProbe()
            let privateCenter = NotificationCenter(), privateWorkspace = NotificationCenter()
            let sender = NSObject()
            let removeWiring = observeActivations(
                wiringProbe, app: sender, center: privateCenter, workspace: privateWorkspace)
            defer { removeWiring() }
            privateCenter.post(name: NSApplication.didBecomeActiveNotification, object: sender)
            privateWorkspace.post(
                name: NSWorkspace.didActivateApplicationNotification, object: nil,
                userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
            let counted = await E2EWait.until(timeout: .seconds(2)) {
                wiringProbe.appActivationCount == 1 && wiringProbe.foregroundPIDs == [own]
            }
            context.check(
                "positive control: the probes count a delivered activation and notice Recortia in front", counted,
                "didBecomeActive=\(wiringProbe.appActivationCount); foreground notifications=\(wiringProbe.foregroundPIDs)"
            )
            context.check(
                "positive control: the foreground comparison rejects Recortia becoming frontmost",
                !wiringProbe.foregroundPIDs.allSatisfy { $0 == foreground })
            probe.appActivationCount = 0
            probe.foregroundPIDs = []
            try await foregroundFixture.yieldToRunner()
            NSApp.activate()
            try context.require(
                "positive control: cooperative activation succeeds", await E2EWait.until { NSApp.isActive })
            let moved = await E2EWait.until(timeout: .seconds(3)) {
                probe.appActivationCount > 0 && probe.foregroundPIDs.contains(own)
            }
            context.check(
                "positive control: a real activation moves both activation probes (AppKit delivery)", moved,
                "didBecomeActive=\(probe.appActivationCount); foreground notifications=\(probe.foregroundPIDs); own=\(own)"
            )
            await foregroundFixture.stop(context)
        }

        static func repeatedShortcutFocus(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let foregroundFixture = try await E2EForegroundFixture.start(context)
            defer { foregroundFixture.requestStop() }
            let display = try context.unwrap("a connected display is available", DesktopGeometry.displays().first)
            var created: OverlayWindow?
            let overlay = RegionOverlayController { display, screen in
                let window = OverlayWindow(display: display, screen: screen)
                configureKeyboardFixture(window, screen: screen)
                created = window
                return window
            }
            defer {
                overlay.dismiss()
                harness.features.capture.cancel()
            }
            try await foregroundFixture.restore()
            let probe = ActivationProbe()
            let removeObservers = observeActivations(
                probe, app: NSApp, center: .default, workspace: NSWorkspace.shared.notificationCenter)
            defer { removeObservers() }
            let foreground = foregroundFixture.processIdentifier
            for cycle in 1...50 {
                try context.require(
                    "repeat starts in the owned foreground process",
                    !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
                harness.app.perform(.captureRegion)
                try context.require("repeat starts selection", harness.features.capture.state == .selecting)
                overlay.present(displays: [display], notice: nil, allowsWindowSwitch: true)
                let window = try context.unwrap("repeat creates the overlay", created)
                await E2ESnapshot.settle(window.selectionView)
                let key = window.isKeyWindow
                let state =
                    "cycle=\(cycle); visible=\(window.isVisible); hidden=\(NSApp.isHidden); "
                    + "keyWindowMatches=\(NSApp.keyWindow === window); "
                    + "responderMatches=\(window.firstResponder === window.selectionView); "
                    + "isActive=\(NSApp.isActive); policy=\(NSApp.activationPolicy().rawValue); "
                    + "foregroundUnchanged=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)"
                context.check("repeat overlay cycle \(cycle) owns keyboard", key, state)
                if !key {
                    let recovered = await E2EWait.until(timeout: .seconds(2)) { window.isKeyWindow }
                    E2ERunner.log("capture-focus-repeat: \(state); recoveredWithin2s=\(recovered)")
                    context.snapshot(window.selectionView, shot: "focus-cycle-\(cycle)", over: harness.desktop)
                }
                overlay.dismiss()
                harness.features.capture.cancel()
                await Task.yield()
            }
            context.check("repeat never activates Recortia", probe.appActivationCount == 0)
            context.check(
                "repeat preserves continuous foreground identity", probe.foregroundPIDs.allSatisfy { $0 == foreground })
            await foregroundFixture.stop(context)
        }

        static func keyEvent(_ code: UInt16, characters: String, windowNumber: Int) throws -> NSEvent {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { throw E2EAbort("could not synthesize selection key \(code)") }
            return event
        }

        private static func sendKey(_ code: UInt16, characters: String, to window: NSWindow) throws {
            NSApp.sendEvent(try keyEvent(code, characters: characters, windowNumber: window.windowNumber))
        }

        static func admission(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            harness.app.perform(.scrollingCapture)
            context.check("a queued scrolling start already holds admission", !harness.app.isEnabled(.captureRegion))
            context.check(
                "a queued scrolling start rejects another scrolling start", !harness.app.isEnabled(.scrollingCapture))
            harness.app.perform(.captureRegion)
            try context.require(
                "queued scrolling enters selection",
                await E2EWait.until { harness.features.scroll.state == .selecting })
            context.check("an immediate still command cannot overlap", !harness.features.capture.state.isActive)
            harness.features.capture.cancel()
            harness.features.scroll.cancel()
            await Task.yield()

            harness.permission.isGranted = false
            harness.permission.holdRequest = true
            let requests = harness.permission.requestCount
            harness.app.perform(.scrollingCapture)
            try context.require(
                "scroll permission request starts",
                await E2EWait.until { harness.permission.requestCount > requests })
            context.check("permission await holds still admission", !harness.app.isEnabled(.captureRegion))
            context.check("permission await holds scrolling admission", !harness.app.isEnabled(.scrollingCapture))
            harness.permission.finishRequest(granted: true)
            try context.require(
                "scroll selection starts", await E2EWait.until { harness.features.scroll.state == .selecting })
            context.check("still capture is disabled during scroll selection", !harness.app.isEnabled(.captureRegion))
            harness.app.perform(.captureRegion)
            context.check("still invocation cannot create a second session", !harness.features.capture.state.isActive)
            harness.features.capture.cancel()
            harness.features.scroll.chooseTarget(
                .region(Rect(x: 0, y: 0, width: 300, height: 200), display: harness.capture.display))
            harness.features.scroll.start()
            try context.require(
                "scroll collection starts", await E2EWait.until { harness.features.scroll.state == .collecting })
            harness.app.perform(.captureWindow)
            context.check("still invocation cannot overlap a live stream", !harness.features.capture.state.isActive)
            harness.features.capture.cancel()
            harness.features.scroll.cancel()

            harness.app.perform(.captureRegion)
            context.check(
                "scroll capture is disabled during still selection", !harness.app.isEnabled(.scrollingCapture))
            harness.app.perform(.scrollingCapture)
            await Task.yield()
            context.check("scroll invocation cannot create a second session", !harness.features.scroll.state.isActive)
            context.check("the first still session stays selecting", harness.features.capture.state == .selecting)
            harness.features.capture.cancel()
            harness.features.scroll.cancel()
        }

        static func recapture(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await harness.openImported(harness.desktop, name: "recapture.png")
            let window = try context.unwrap("the existing editor has a window", controller.window)
            // Order the real editor without displaying any pixels or intercepting the user's input.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            let document = controller.model.document
            let capturesBefore = harness.capture.captures.count
            let child = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: .borderless, backing: .buffered, defer: false)
            child.isReleasedWhenClosed = false
            child.alphaValue = 0
            child.ignoresMouseEvents = true
            window.addChildWindow(child, ordered: .above)
            defer { child.close() }
            try context.require("the editor is initially ordered", window.isVisible)
            await E2EActions.snapshotEditor(controller, context)

            harness.app.perform(.captureRegion)
            try context.require("a new region hides the existing editor synchronously", !window.isVisible)
            context.check("hiding preserves child-window ownership", child.parent === window)
            context.check("child panels are also hidden during selection", !child.isVisible)
            context.check("hiding preserves the document", controller.model.document == document)
            context.check("hiding does not close the editor", !controller.model.isClosed)
            harness.app.perform(.captureWindow)
            context.check("replacement selection keeps the editor hidden", !window.isVisible)
            harness.features.capture.cancel()
            let restored = await E2EWait.until { window.isVisible }
            try context.require("cancel restores the existing editor", restored)
            context.check("restoration preserves child-window ownership", child.parent === window)
            context.check("cancel never captures or exports", harness.capture.captures.count == capturesBefore)

            harness.app.perform(.captureWithDelay)
            context.check("delayed selection hides the editor", !window.isVisible)
            harness.features.capture.interrupt(because: .screenLocked)
            try context.require(
                "screen-lock interruption restores the existing editor", await E2EWait.until { window.isVisible })

            let hidden = NSWindow(
                contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            hidden.isReleasedWhenClosed = false
            defer { hidden.close() }
            harness.app.perform(.captureRegion)
            let before = harness.editors.controllers.count
            try context.require(
                "second region commits",
                harness.features.capture.commitRegion(
                    Rect(x: 0, y: 0, width: 300, height: 200), on: harness.capture.display))
            context.check("the editor stays hidden while capturing", !window.isVisible)
            _ = try await E2EActions.waitForNewEditor(harness, after: before, context)
            try context.require("success restores the old editor", await E2EWait.until { window.isVisible })
            context.check("previously hidden windows remain hidden", !hidden.isVisible)
            context.check("the original document survives recapture", controller.model.document == document)

            harness.app.perform(.repeatLastRegion)
            context.check("repeat capture hides the old editor", !window.isVisible)
            harness.features.capture.cancel()
            try context.require("repeat cancellation restores it", await E2EWait.until { window.isVisible })

            harness.app.perform(.captureText)
            context.check("OCR selection hides the editor", !window.isVisible)
            harness.features.capture.cancel()
            try context.require("OCR cancellation restores it", await E2EWait.until { window.isVisible })

            harness.app.perform(.scrollingCapture)
            try context.require(
                "scrolling enters selection", await E2EWait.until { harness.features.scroll.state == .selecting })
            context.check("scrolling selection hides the editor", !window.isVisible)
            harness.features.scroll.cancel()
            try context.require("scrolling cancellation restores it", await E2EWait.until { window.isVisible })

            harness.permission.isGranted = false
            harness.app.perform(.captureRegion)
            context.check("permission-denied still capture initially hides the editor", !window.isVisible)
            try context.require(
                "still permission denial restores the editor", await E2EWait.until { window.isVisible })
            harness.app.perform(.scrollingCapture)
            context.check("permission-denied scrolling initially hides the editor", !window.isVisible)
            try context.require(
                "permission denial restores the editor", await E2EWait.until { window.isVisible })
            context.check("permission denial does not start scrolling", harness.features.scroll.state == .idle)
            context.check(
                "scrolling denial reports the actionable permission message",
                harness.messages.values.last == .capture(.permissionDenied))
            harness.permission.isGranted = true

            harness.app.perform(.captureRegion)
            window.close()
            harness.features.capture.cancel()
            // Let the real restoration observer process the terminal state.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
            context.check("a closed hidden editor is never resurrected", !window.isVisible && controller.model.isClosed)
        }
    }
#endif
