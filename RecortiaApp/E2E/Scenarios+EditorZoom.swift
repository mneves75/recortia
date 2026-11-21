#if DEBUG
    import AppKit
    import Domain
    import Features

    /// Settings › General's zoom preferences in real editors (FR-04): how a new editor frames its
    /// image, and what a real scroll-wheel event does on the canvas with wheel zoom off, on,
    /// with Option, and reversed. ⌘0 still fits afterwards.
    @MainActor
    enum EditorZoomScenarios {
        static func zoom(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let preferences = harness.settings.preferences
            defer {
                harness.settings.update {
                    $0.editorOpenZoomChoice = preferences.editorOpenZoomChoice
                    $0.zoomsWithScrollWheelChoice = preferences.zoomsWithScrollWheelChoice
                    $0.reversesScrollWheelZoomChoice = preferences.reversesScrollWheelZoomChoice
                }
                harness.reset()
            }
            context.check(
                "new editors fit by default, and the wheel does not zoom",
                preferences.editorOpenZoom == .fit && !preferences.zoomsWithScrollWheel
                    && !preferences.reversesScrollWheelZoom)

            // An image 20 points smaller than the canvas at 100 %: Fit's margin shrinks it, while
            // "Actual size when it fits" shows it at 100 %.
            let probe = try await E2EActions.captureRegion(
                harness, CGRect(x: 200, y: 160, width: 240, height: 120), context)
            let canvas = probe.model.viewportSize, scale = probe.model.backingScale
            try context.require("the editor has a canvas", canvas.width > 100 && canvas.height > 100, "\(canvas)")
            let nearlyCanvas = try E2EDrawing.image(
                size: CGSize(width: canvas.width - 20, height: canvas.height - 20), scale: scale
            ) { bounds in
                NSColor.systemTeal.setFill()
                bounds.fill()
            }
            let fitted = try await harness.openImported(nearlyCanvas, name: "zoom-fit.png")
            context.check(
                "Fit opens an image that fits only without the margin below 100 %",
                fitted.model.zoomPercent < 99.9, "\(fitted.model.zoomPercent) %")

            harness.settings.update { $0.editorOpenZoom = .actualSizeWhenFits }
            let actual = try await harness.openImported(nearlyCanvas, name: "zoom-actual.png")
            context.check(
                "Actual size when it fits opens that image at 100 %", abs(actual.model.zoomPercent - 100) < 0.001,
                "\(actual.model.zoomPercent) %")
            let large = try await E2EActions.captureRegion(
                harness, CGRect(x: 0, y: 0, width: 1280, height: 800), context)
            let largeShown = large.model.viewport.viewRect(large.model.document.contentRect)
            context.check(
                "an image larger than the canvas still opens fitted inside it",
                large.model.zoomPercent < 100 && largeShown.width <= canvas.width
                    && largeShown.height <= canvas.height,
                "\(large.model.zoomPercent) %, shown \(largeShown.size)")

            let editor = actual
            let view = try context.unwrap("the editor canvas", editor.canvasView)
            let model = editor.model
            func send(_ delta: Int32, flags: CGEventFlags = []) throws -> Point<ViewSpace> {
                let event = try context.unwrap(
                    "a scroll-wheel event",
                    CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: delta, wheel2: 0,
                        wheel3: 0))
                event.flags = flags
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
                "with wheel zoom on, the wheel zooms around the pointer",
                zoomedIn != before.zoom && near(model.viewport.documentPoint(anchor), before.documentPoint(anchor)),
                "\(before) -> \(model.viewport)")
            before = model.viewport
            _ = try send(30, flags: .maskAlternate)
            context.check(
                "⌥-wheel scrolls while wheel zoom is on",
                model.viewport.zoom == before.zoom && model.viewport.offset != before.offset,
                "\(before) -> \(model.viewport)")

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
