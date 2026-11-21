#if DEBUG
    import AppKit
    import Domain
    import Features
    import Foundation
    import RecortiaFixtures

    /// Text-only redaction (A-6) through the real editor window: the native Text Only control, a
    /// drawn rectangle that the canvas covers at once, exports refused while recognition is pending,
    /// then one mask per line in an exported copy. Recognition is scripted (`SyntheticSensitiveText`)
    /// over the synthetic desktop; nothing reads the screen and Vision does not run.
    @MainActor
    enum TextRedactionScenarios {
        static func textRedaction(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let recognition = harness.sensitiveText
            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            controller.window?.orderFront(nil)
            try context.require("the editor is ordered for native actions", controller.window?.isVisible == true)
            let model = controller.model
            let root = try context.unwrap("editor content", controller.contentRoot)
            let asset = try context.unwrap("captured asset", model.document.layers.first?.assetID)
            let line = AutoRedactionScenarios.secretPixels
            // The planted line with room around it, as a person draws over a paragraph.
            let drawn = PixelRect(x: line.x - 24, y: line.y - 16, width: line.width + 48, height: line.height + 32)

            context.check("Text Only is off by default", !model.redactsTextOnly)
            model.selectTool(.redact)
            await E2EActions.scrollInspector(controller, to: 0)
            await E2ESnapshot.settle(root)
            try E2EAccessibilityControl.pressCheckingEffect("redaction.textOnly", in: root, context)
            try context.require(
                "the native Text Only control turns it on", await E2EWait.until { model.redactsTextOnly })
            let before = try canvasPixels(model, context)
            context.check(
                "positive control: the canvas shows the line before it is redacted", uncovered(line, in: before) > 0)

            // Pending: the cover hides the whole rectangle at once and every export waits.
            recognition.lines = [line]
            recognition.holds = true
            let undoCount = model.session.undoCount
            draw(drawn, in: model)
            try context.require("recognition runs on the rectangle", await E2EWait.until { recognition.isWaiting })
            context.check(
                "recognition reads the rectangle's source pixels", recognition.lineAreas == [drawn],
                "\(recognition.lineAreas)")
            context.check("the editor waits for the lines", model.isMaskingPending)
            context.check(
                "pending: one opaque mask over the whole rectangle",
                model.document.masks.count == 1 && model.document.masks[0].sourceRegions == [asset: [drawn]]
                    && model.document.masks[0].fill.isOpaque,
                "\(model.document.masks)")
            let pending = try canvasPixels(model, context)
            context.check(
                "pending: the canvas covers every pixel of the rectangle", uncovered(drawn, in: pending) == 0,
                "\(uncovered(drawn, in: pending)) uncovered pixels")
            let copy = await model.export(.copy)
            context.check(
                "Copy is refused while the lines are pending",
                copy == .failed(.maskingUnfinished) && !model.canStartExport, "\(copy)")
            context.check(
                "the editor says what it waits for", model.notice == .textRedactionInProgress,
                "\(String(describing: model.notice))")
            let pins = harness.features.pins.pins.count
            await model.pin()
            context.check("Pin is refused while the lines are pending", harness.features.pins.pins.count == pins)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "text-redaction-pending")

            // The lines land: one mask per line, one undo step, and only the text is covered.
            recognition.release()
            try context.require("the lines land", await E2EWait.until { !model.isMaskingPending })
            context.check(
                "one mask per recognized line replaces the cover",
                model.document.masks.map(\.sourceRegions) == [[asset: [line]]], "\(model.document.masks)")
            context.check(
                "the editor says how many lines it covered", model.notice == .textLinesCovered(1),
                "\(String(describing: model.notice))")
            context.check("the cover and the lines are one undo step", model.session.undoCount == undoCount + 1)
            try await harness.editors.waitForBase(model)
            let copied = try await copiedPixels(controller, harness, context, "the text-only redaction")
            context.check(
                "the exported copy covers every pixel of the line", uncovered(line, in: copied) == 0,
                "\(uncovered(line, in: copied)) uncovered pixels of the planted line")
            context.check(
                "only the text is covered: the rest of the rectangle is exported",
                uncovered(drawn, in: copied) > 0)
            await E2EActions.snapshotEditor(controller, context, shot: "text-redaction-lines")
            model.undo()
            context.check("one Undo removes the line masks", model.document.masks.isEmpty)
            try await harness.editors.waitForBase(model)
            let undone = try await copiedPixels(controller, harness, context, "the image after Undo")
            context.check(
                "positive control: after Undo the line is exported", uncovered(line, in: undone) > 0,
                "\(uncovered(line, in: undone)) visible pixels")

            // No line found, or recognition failed: the whole rectangle stays covered.
            for (name, fails) in [("no line found", false), ("recognition failed", true)] {
                recognition.holds = false
                recognition.lines = []
                recognition.fails = fails
                draw(drawn, in: model)
                try context.require("\(name): recognition settles", await E2EWait.until { !model.isMaskingPending })
                context.check(
                    "\(name): the cover over the whole rectangle stays",
                    model.document.masks.map(\.sourceRegions) == [[asset: [drawn]]], "\(model.document.masks)")
                context.check(
                    "\(name): the editor says the area stays covered", model.notice == .textRedactionKeptArea,
                    "\(String(describing: model.notice))")
                try await harness.editors.waitForBase(model)
                let kept = try await copiedPixels(controller, harness, context, name)
                context.check(
                    "\(name): the exported copy covers the whole rectangle", uncovered(drawn, in: kept) == 0,
                    "\(uncovered(drawn, in: kept)) uncovered pixels")
                model.undo()
            }
        }

        private static func draw(_ rect: PixelRect, in model: EditorModel) {
            E2EActions.drag(
                model, .redact, from: E2EActions.point(Double(rect.x), Double(rect.y)),
                to: E2EActions.point(Double(rect.maxX), Double(rect.maxY)))
        }

        /// What the editing canvas draws for the document, at one document pixel per pixel, through
        /// the canvas's own renderer.
        private static func canvasPixels(_ model: EditorModel, _ context: ScenarioContext) throws -> DecodedPixels {
            let width = Int(model.document.canvasSize.width), height = Int(model.document.canvasSize.height)
            let space = try context.unwrap("sRGB", CGColorSpace(name: CGColorSpace.sRGB))
            let bitmap = try context.unwrap(
                "canvas bitmap",
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // Document space has a top-left origin, as on the canvas.
            bitmap.translateBy(x: 0, y: CGFloat(height))
            bitmap.scaleBy(x: 1, y: -1)
            try EditorCanvasRenderer.draw(
                model.document, base: model.baseImage, calloutBase: model.calloutBaseImage, in: bitmap)
            let image = try context.unwrap("canvas image", bitmap.makeImage())
            return try ContainerInspector.pixels(of: image)
        }

        /// A manual Copy Image of `editor`, decoded from the pasteboard.
        private static func copiedPixels(
            _ editor: EditorWindowController, _ harness: E2EHarness, _ context: ScenarioContext, _ name: String
        ) async throws -> DecodedPixels {
            let outcome = await editor.model.export(.copy)
            try context.require("Copy of \(name) succeeds", outcome == .copied, "\(outcome)")
            let data = try context.unwrap(
                "\(name) PNG on the pasteboard", harness.clipboard.pasteboard.data(forType: .png))
            return try E2EActions.decode(data, name, context)
        }

        /// Pixels in `rect` that are not the black mask fill.
        private static func uncovered(_ rect: PixelRect, in pixels: DecodedPixels) -> Int {
            var count = 0
            for y in max(0, rect.y)..<min(pixels.height, rect.maxY) {
                for x in max(0, rect.x)..<min(pixels.width, rect.maxX) {
                    let p = pixels.pixel(x: x, y: y)
                    if max(p.r, p.g, p.b) > 30 { count += 1 }
                }
            }
            return count
        }
    }
#endif
