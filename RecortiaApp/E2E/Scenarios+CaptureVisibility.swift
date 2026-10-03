#if DEBUG
    import AppKit
    import Domain
    import Features
    import MacPlatform

    @MainActor
    enum CaptureVisibilityScenarios {
        private final class ActivationProbe {
            var appActivationCount = 0
            var foregroundPIDs: [pid_t] = []
        }

        static func editorPresentation(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            var controller: EditorWindowController?
            let originalOpenDocument = harness.app.openDocument
            harness.app.openDocument = { session in
                let model = EditorModel(session: session, environment: harness.environment)
                let opened = EditorWindowController(model: model)
                // Exercise production presentation without exposing desktop pixels or
                // intercepting real input. Snapshots render this synthetic view only.
                opened.window?.alphaValue = 0
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
            context.check("capture editor belongs to the active Space", window.isOnActiveSpace)
            context.check("capture editor uses the normal window level", window.level == .normal)
            context.check(
                "capture editor is an ordinary activating window", !window.styleMask.contains(.nonactivatingPanel))
            context.check(
                "capture editor follows the active Space", window.collectionBehavior.contains(.moveToActiveSpace))
            context.check(
                "capture editor supports a fullscreen Space", window.collectionBehavior.contains(.fullScreenAuxiliary))
            if NSApp.isActive {
                context.check("an activated editor owns the keyboard", window.isKeyWindow)
            }
            let canvas = try context.unwrap("hosted layout attaches the canvas", opened.canvasView)
            context.check(
                "the editor installs its canvas responder", window.firstResponder === canvas,
                "responder=\(String(describing: window.firstResponder))")
            context.check(
                "the editor does not combine fullscreen policies",
                !window.collectionBehavior.contains(.fullScreenPrimary))
            let content = try context.unwrap("the editor hosts content", window.contentView)
            context.snapshot(content, shot: "presented-editor", over: harness.desktop)

            window.miniaturize(nil)
            try context.require("the existing editor is minimized", await E2EWait.until { window.isMiniaturized })
            opened.present()
            await E2ESnapshot.settle(window.contentView)
            context.check("presenting an existing editor restores it", !window.isMiniaturized && window.isVisible)

            window.orderOut(nil)
            NSApp.deactivate()
            try context.require("presentation starts inactive", await E2EWait.until { !NSApp.isActive })
            let foreground = try context.unwrap(
                "another app is foreground before presentation",
                NSWorkspace.shared.frontmostApplication?.processIdentifier)
            try context.require(
                "presentation starts outside Recortia", foreground != ProcessInfo.processInfo.processIdentifier)
            opened.present()
            await E2ESnapshot.settle(window.contentView)
            context.check("inactive presentation still orders the editor", window.isVisible && window.isOnActiveSpace)
            context.check("presentation preserves the document", !opened.model.isClosed)
        }

        static func shortcutFocus(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let display = try context.unwrap(
                "a connected display is available", DesktopGeometry.displays().first)
            var created: OverlayWindow?
            let overlay = RegionOverlayController { display, screen in
                let window = OverlayWindow(display: display, screen: screen)
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.setContentSize(SyntheticDesktop.size)
                E2ESnapshot.park(window)
                created = window
                return window
            }
            defer {
                overlay.dismiss()
                harness.features.capture.cancel()
            }

            // A global shortcut starts while another application is active. Only transparent,
            // offscreen synthetic windows are used; no desktop pixels or global keys are read.
            NSApp.deactivate()
            try context.require(
                "shortcut starts with Recortia inactive", await E2EWait.until { !NSApp.isActive })
            let foreground = try context.unwrap(
                "another foreground application exists", NSWorkspace.shared.frontmostApplication?.processIdentifier)
            try context.require(
                "the shortcut starts outside Recortia", foreground != ProcessInfo.processInfo.processIdentifier)
            let probe = ActivationProbe()
            let appObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
            ) { _ in MainActor.assumeIsolated { probe.appActivationCount += 1 } }
            let workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated { if let pid { probe.foregroundPIDs.append(pid) } }
            }
            defer {
                NotificationCenter.default.removeObserver(appObserver)
                NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            }
            harness.app.perform(.captureRegion)
            try context.require("the shortcut action starts selection", harness.features.capture.state == .selecting)
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
            context.check("the selection still receives keyboard input", window.isKeyWindow)
            context.check("the selection view owns the responder", window.firstResponder === window.selectionView)
            context.check(
                "the overlay can join the current Space", window.collectionBehavior.contains(.canJoinAllSpaces))
            context.check(
                "the overlay supports fullscreen Spaces", window.collectionBehavior.contains(.fullScreenAuxiliary))
            context.check(
                "the overlay does not activate the application", window.styleMask.contains(.nonactivatingPanel))
            context.check(
                "the synthetic overlay stays offscreen", window.frame.maxX < -10_000 && window.frame.maxY < -10_000)
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
            context.check("replacement selection still receives keyboard input", repeatedWindow.isKeyWindow)
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
