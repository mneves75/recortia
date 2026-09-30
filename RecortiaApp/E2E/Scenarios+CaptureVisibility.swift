#if DEBUG
    import AppKit
    import Domain
    import Features

    @MainActor
    enum CaptureVisibilityScenarios {
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
