#if DEBUG
    import AppKit
    import Domain
    import Features
    import RecortiaFixtures

    /// Arrowhead styles and freehand smoothing (A-11) through the real editor window: each head is
    /// chosen with its native inspector control, then a Copy Image is checked pixel by pixel against
    /// the canvas renderer and against the pixels each head must and must not paint. A wobbling
    /// freehand stroke is drawn through pointer events with Smooth on, then off.
    @MainActor
    enum ArrowStyleScenarios {
        private typealias Probe = (point: (Double, Double), painted: Bool)

        static func styles(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            controller.window?.orderFront(nil)
            try context.require(
                "the synthetic editor is ordered for native actions", controller.window?.isVisible == true)
            let model = controller.model
            let root = try context.unwrap("arrow style editor content", controller.contentRoot)
            let baseline = try await E2EActions.copiedPixels(controller, harness, context, "the image before arrows")

            // Width 4 by default: heads are 18 long and reach 12 to each side of the shaft.
            E2EActions.drag(model, .arrow, from: E2EActions.point(70, 100), to: E2EActions.point(400, 100))
            let arrow = try context.unwrap("created arrow", model.document.annotations.last)
            await E2EActions.scrollInspector(controller, to: 0)
            await E2ESnapshot.settle(root)
            let probes: [Annotation.ArrowHead: [Probe]] = [
                .filled: [((388, 106), true), ((82, 106), false), ((200, 100), true)],
                .open: [((388, 108), true), ((385, 105), false), ((82, 106), false)],
                .plain: [((388, 106), false), ((82, 106), false), ((200, 100), true)],
                .double: [((388, 106), true), ((82, 106), true), ((200, 100), true)],
            ]
            for head in [Annotation.ArrowHead.open, .plain, .double, .filled] {
                let undoCount = model.session.undoCount
                try E2EAccessibilityControl.press("arrow.head.\(head.rawValue)", in: root, context)
                try context.require(
                    "the native \(head.rawValue) head control changes the selected arrow",
                    await E2EWait.until { model.arrowHeadState == head && model.style.arrowHead == head })
                context.check("the \(head.rawValue) head is one Undo step", model.session.undoCount == undoCount + 1)
                context.check(
                    "the \(head.rawValue) head keeps the arrow's identity",
                    model.document.annotations.last?.id == arrow.id)
                await E2ESnapshot.settle(root)
                context.check(
                    "the \(head.rawValue) control reports itself selected",
                    try !E2EAccessibilityControl.text(.value, for: "arrow.head.\(head.rawValue)", in: root, context)
                        .isEmpty)
                context.snapshot(root, shot: "arrow-head-\(head.rawValue)")
                let exported = try await E2EActions.copiedPixels(
                    controller, harness, context, "the \(head.rawValue) head")
                try expectCanvasMatches(exported, model, context, "the \(head.rawValue) head")
                for probe in probes[head] ?? [] {
                    let x = Int(probe.point.0), y = Int(probe.point.1)
                    let changed = E2EActions.distance(exported.pixel(x: x, y: y), baseline.pixel(x: x, y: y)) > 40
                    let red = exported.pixel(x: x, y: y).r > 160 && exported.pixel(x: x, y: y).g < 150
                    context.check(
                        "the \(head.rawValue) head \(probe.painted ? "paints" : "leaves") (\(x), \(y))",
                        probe.painted ? changed && red : !changed, exported.pixel(x: x, y: y).hex)
                }
            }
            try await mixedAndFuture(controller, arrow: arrow, context)
            try await smoothing(controller, harness, context)
        }

        private static func mixedAndFuture(
            _ controller: EditorWindowController, arrow: Annotation, _ context: ScenarioContext
        ) async throws {
            let model = controller.model
            let root = try context.unwrap("arrow style content", controller.contentRoot)
            try E2EAccessibilityControl.press("arrow.head.double", in: root, context)
            _ = await E2EWait.until { model.style.arrowHead == .double }
            model.clearSelection()
            E2EActions.drag(model, .arrow, from: E2EActions.point(70, 250), to: E2EActions.point(400, 250))
            let second = try context.unwrap("arrow with the future head", model.document.annotations.last)
            context.check(
                "a new arrow takes the future head",
                second.kind == .arrow(start: Point(x: 70, y: 250), end: Point(x: 400, y: 250), head: .double))
            try E2EAccessibilityControl.press("arrow.head.plain", in: root, context)
            _ = await E2EWait.until { model.arrowHeadState == .plain }
            model.setSelection([.annotation(arrow.id), .annotation(second.id)])
            await E2ESnapshot.settle(root)
            context.check("mixed heads have no single state", model.arrowHeadState == nil)
            for head in Annotation.ArrowHead.allCases {
                context.check(
                    "mixed heads expose no selected \(head.rawValue) value",
                    try E2EAccessibilityControl.text(.value, for: "arrow.head.\(head.rawValue)", in: root, context)
                        .isEmpty)
            }
            context.check(
                "mixed heads have a localized description",
                try E2EAccessibilityControl.text(.value, for: "arrow.head.mixed", in: root, context)
                    == String(localized: "Mixed arrowheads", table: "Editor"))
            context.snapshot(root, shot: "arrow-head-mixed")
            let mixed = model.document, count = model.session.undoCount
            try E2EAccessibilityControl.press("arrow.head.open", in: root, context)
            try context.require(
                "mixed selected arrows take one head",
                await E2EWait.until { model.arrowHeadState == .open })
            context.check("a mixed head change is one Undo step", model.session.undoCount == count + 1)
            model.undo()
            context.check("Undo restores the mixed heads", model.document == mixed)
            if let window = controller.window { window.appearance = NSAppearance(named: .darkAqua) }
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "arrow-head-mixed-dark")
            controller.window?.appearance = nil
        }

        /// A hand-drawn wobble in document points, dense enough for smoothing to drop most points.
        private static func wobble(from x: Double, y: Double) -> [Point<DocumentSpace>] {
            (0...150).map { i in
                Point(
                    x: x + Double(i) * 2,
                    y: y + sin(Double(i) / 150 * .pi * 2) * 40 + sin(Double(i) * 12.9898) * 0.6)
            }
        }

        private static func smoothing(
            _ controller: EditorWindowController, _ harness: E2EHarness, _ context: ScenarioContext
        ) async throws {
            let model = controller.model
            let root = try context.unwrap("smoothing content", controller.contentRoot)
            model.clearSelection()
            model.selectTool(.freehand)
            await E2ESnapshot.settle(root)
            context.check("new strokes are smoothed by default", model.style.smoothsStrokes)
            context.check(
                "the native Smooth control is enabled",
                try E2EAccessibilityControl.isEnabled("stroke.smooth", in: root, context))
            context.snapshot(root, shot: "stroke-smooth")
            let smoothPath = wobble(from: 80, y: 380)
            E2EActions.drag(
                model, .freehand, from: smoothPath[0], to: smoothPath[smoothPath.count - 1],
                via: Array(smoothPath.dropFirst()))
            let smooth = try context.unwrap("smoothed stroke", model.document.annotations.last)
            guard case .freehand(let stored, let smoothed) = smooth.kind else {
                try context.require("the stroke is freehand", false, "\(smooth.kind)")
                return
            }
            context.check("the stroke is stored as smoothed", smoothed == true)
            context.check(
                "smoothing stores fewer points than were drawn", stored.count < smoothPath.count / 3,
                "\(stored.count) of \(smoothPath.count)")
            context.check(
                "smoothing keeps both ends", stored.first == smoothPath.first && stored.last == smoothPath.last)
            let exported = try await E2EActions.copiedPixels(controller, harness, context, "the smoothed stroke")
            try expectCanvasMatches(exported, model, context, "the smoothed stroke")

            try E2EAccessibilityControl.pressCheckingEffect("stroke.smooth", in: root, context)
            try context.require(
                "the native Smooth control turns smoothing off", await E2EWait.until { !model.style.smoothsStrokes })
            let rawPath = wobble(from: 80, y: 300)
            E2EActions.drag(
                model, .freehand, from: rawPath[0], to: rawPath[rawPath.count - 1], via: Array(rawPath.dropFirst()))
            context.check(
                "with Smooth off the stroke keeps every drawn point",
                model.document.annotations.last?.kind == .freehand(rawPath))
            context.check("the smoothed stroke is unchanged", model.document.annotations.contains(smooth))
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "stroke-smooth-off")
        }

        private static func expectCanvasMatches(
            _ exported: DecodedPixels, _ model: EditorModel, _ context: ScenarioContext, _ name: String
        ) throws {
            let canvas = try E2EActions.canvasPixels(model, context)
            try context.require(
                "\(name): the export and the canvas have one size",
                canvas.width == exported.width && canvas.height == exported.height,
                "\(canvas.width) × \(canvas.height) vs \(exported.width) × \(exported.height)")
            var worst = 0
            for y in 0..<canvas.height {
                for x in 0..<canvas.width {
                    worst = max(worst, E2EActions.distance(canvas.pixel(x: x, y: y), exported.pixel(x: x, y: y)))
                }
            }
            context.check(
                "\(name): the export matches the canvas pixel for pixel", worst <= 1, "largest difference \(worst)")
        }
    }
#endif
