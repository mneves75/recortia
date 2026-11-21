#if DEBUG
    import AppKit
    import Domain
    import Features

    /// Settings › General's wheel zoom in a real editor (FR-04): what real scroll-wheel events do on
    /// the canvas with wheel zoom off, on, with Option, and reversed. Mouse-wheel events carry no
    /// scroll or momentum phase; a phased (trackpad) or momentum event keeps scrolling. ⌘0 still fits.
    @MainActor
    enum EditorZoomScenarios {
        static func zoom(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let preferences = harness.settings.preferences
            defer {
                harness.settings.update {
                    $0.zoomsWithScrollWheelChoice = preferences.zoomsWithScrollWheelChoice
                    $0.reversesScrollWheelZoomChoice = preferences.reversesScrollWheelZoomChoice
                }
                harness.reset()
            }
            context.check(
                "the wheel does not zoom by default",
                !preferences.zoomsWithScrollWheel && !preferences.reversesScrollWheelZoom)

            let editor = try await E2EActions.captureRegion(
                harness, CGRect(x: 200, y: 160, width: 640, height: 420), context)
            let view = try context.unwrap("the editor canvas", editor.canvasView)
            let model = editor.model
            /// Sends one real scroll event to the canvas: a mouse wheel's when both phases are nil.
            func send(_ delta: Int32, flags: CGEventFlags = [], phase: Int64? = nil, momentum: Int64? = nil) throws
                -> Point<ViewSpace>
            {
                let event = try context.unwrap(
                    "a scroll-wheel event",
                    CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0,
                        wheel3: 0))
                event.flags = flags
                if let phase { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
                if let momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum) }
                let scroll = try context.unwrap("the event as AppKit reads it", NSEvent(cgEvent: event))
                let p = view.convert(scroll.locationInWindow, from: nil)
                view.scrollWheel(with: scroll)
                return Point(x: p.x, y: p.y)
            }
            func near(_ a: Point<DocumentSpace>, _ b: Point<DocumentSpace>) -> Bool {
                abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
            }

            var before = model.viewport
            _ = try send(30)
            context.check(
                "with wheel zoom off, the wheel scrolls without zooming",
                model.viewport.zoom == before.zoom && model.viewport.offset != before.offset,
                "\(before) -> \(model.viewport)")
            before = model.viewport
            _ = try send(30, flags: .maskCommand)
            context.check("⌘-wheel still zooms", model.viewport.zoom != before.zoom, "\(before) -> \(model.viewport)")

            harness.settings.update { $0.zoomsWithScrollWheel = true }
            model.setZoom(0.5)
            before = model.viewport
            let anchor = try send(30)
            let zoomedIn = model.viewport.zoom
            context.check(
                "with wheel zoom on, a mouse wheel zooms around the pointer",
                zoomedIn != before.zoom && near(model.viewport.documentPoint(anchor), before.documentPoint(anchor)),
                "\(before) -> \(model.viewport)")
            before = model.viewport
            _ = try send(30, flags: .maskAlternate)
            context.check(
                "⌥-wheel scrolls while wheel zoom is on",
                model.viewport.zoom == before.zoom && model.viewport.offset != before.offset,
                "\(before) -> \(model.viewport)")
            // CGScrollPhase began (1) and momentum continue (2): trackpad scrolling and its coast.
            for (label, phase, momentum) in [("a trackpad", Int64(1), Int64?.none), ("a momentum", nil, Int64(2))] {
                before = model.viewport
                _ = try send(30, phase: phase, momentum: momentum)
                context.check(
                    "with wheel zoom on, \(label) scroll event scrolls instead of zooming",
                    model.viewport.zoom == before.zoom && model.viewport.offset != before.offset,
                    "\(before) -> \(model.viewport)")
            }

            harness.settings.update { $0.reversesScrollWheelZoom = true }
            model.setZoom(0.5)
            _ = try send(30)
            context.check(
                "Reverse zoom direction turns the same wheel movement the other way",
                (model.viewport.zoom - 0.5) * (zoomedIn - 0.5) < 0, "\(zoomedIn) vs \(model.viewport.zoom)")

            model.zoomToFit()
            context.check(
                "⌘0 still fits the image", model.zoomPercent <= 100 + 0.001, "\(model.zoomPercent) %")
        }
    }
#endif
