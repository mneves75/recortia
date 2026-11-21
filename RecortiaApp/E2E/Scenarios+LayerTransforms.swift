#if DEBUG
    import AppKit
    import Domain
    import Features
    import Foundation
    import RecortiaFixtures

    /// Rotate, flip and duplicate (A-10) through the editor's real inspector controls, checked on
    /// exported copies: a whole-image turn exports the earlier export turned, pixel for pixel, with
    /// the secret line still covered; a duplicated, mirrored copy of the layer that lies clear of the
    /// box exports no pixel of the protected line. The Image menu lists every command. The capture
    /// is the synthetic desktop; nothing reads the screen.
    @MainActor
    enum LayerTransformScenarios {
        static func layerTransforms(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            controller.window?.orderFront(nil)
            try context.require("the editor is ordered for native actions", controller.window?.isVisible == true)
            let model = controller.model
            let root = try context.unwrap("editor content", controller.contentRoot)
            let line = AutoRedactionScenarios.secretPixels
            let original = try context.unwrap("captured layer", model.document.layers.first)

            for title in ImageTransform.allCases.flatMap({ [$0.imageTitle, $0.layerTitle] }) {
                context.check("the Image menu has \(title)", EditorToolbarScenarios.viewCommand(title) != nil)
            }

            try await harness.editors.waitForBase(model)
            let plain = try await copiedPixels(controller, harness, context, "the capture")
            context.check(
                "positive control: the capture exports the line", uncovered(line, in: plain) > 0,
                "\(uncovered(line, in: plain)) visible pixels")
            E2EActions.drag(
                model, .redact, from: E2EActions.point(Double(line.x), Double(line.y)),
                to: E2EActions.point(Double(line.maxX), Double(line.maxY)))
            let box = try context.unwrap("the redaction over the line", model.document.masks.first?.outputRect)
            try await harness.editors.waitForBase(model)
            let masked = try await copiedPixels(controller, harness, context, "the redacted capture")
            context.check("the redaction covers the line", uncovered(line, in: masked) == 0)

            // The whole image, from the Image tab.
            model.selectTool(.select)
            model.clearSelection()
            controller.panes.chosenInspectorTab = .image
            let undoCount = model.session.undoCount
            try await press("image.rotateRight", in: controller, root, context)
            let (w, h) = (masked.width, masked.height)
            try context.require(
                "Rotate Right turns the canvas",
                await E2EWait.until { model.document.canvasSize == Size(width: Double(h), height: Double(w)) },
                "\(model.document.canvasSize)")
            context.check("the turn is one undo step", model.session.undoCount == undoCount + 1)
            try await harness.editors.waitForBase(model)
            let turned = try await copiedPixels(controller, harness, context, "the turned image")
            try context.require(
                "the turned export swaps its sides", turned.width == h && turned.height == w,
                "\(turned.width) × \(turned.height)")
            var mismatched = 0
            for y in 0..<turned.height {
                for x in 0..<turned.width where turned.pixel(x: x, y: y) != masked.pixel(x: y, y: h - 1 - x) {
                    mismatched += 1
                }
            }
            context.check(
                "the turned export is the earlier export turned, pixel for pixel", mismatched == 0,
                "\(mismatched) pixels differ")
            let turnedLine = PixelRect(x: h - line.maxY, y: line.x, width: line.height, height: line.width)
            context.check(
                "the turned export covers every pixel of the line", uncovered(turnedLine, in: turned) == 0,
                "\(uncovered(turnedLine, in: turned)) uncovered pixels")
            await E2EActions.snapshotEditor(controller, context, shot: "layer-transforms-turned")
            model.undo()
            try context.require(
                "Undo turns it back", model.document.canvasSize == Size(width: Double(w), height: Double(h)))

            // A copy of the layer, mirrored top to bottom from the layer's own controls.
            model.setSelection([.layer(original.id)])
            try await press("layer.duplicate", in: controller, root, context)
            try context.require(
                "Duplicate adds a copy of the layer", await E2EWait.until { model.document.layers.count == 2 })
            let copy = try context.unwrap("the copy", model.document.layers.last)
            context.check(
                "the copy shows the same image 10 pt away",
                copy.assetID == original.assetID
                    && copy.placement.translation == original.placement.translation.offset(dx: 10, dy: 10))
            try context.require("the copy is selected", model.selection == [.layer(copy.id)])
            try await press("layer.flipVertical", in: controller, root, context)
            try context.require(
                "Flip Layer Vertical mirrors the copy",
                await E2EWait.until { model.document.layers.last?.placement.mirrored == true })
            context.check(
                "the box stays where it was drawn", model.document.masks.first?.outputRect == box,
                "\(String(describing: model.document.masks.first?.outputRect))")
            let flipped = try context.unwrap("the mirrored copy", model.document.layers.last)
            let size = try context.unwrap("the asset size", model.document.assets[flipped.assetID]?.pixelSize)
            let mapped = flipped.sourceToDocument(assetSize: size).apply(line.asRect)
            let copiedLine = PixelRect(
                x: Int(mapped.minX), y: Int(mapped.minY), width: Int(mapped.width), height: Int(mapped.height))
            try context.require(
                "the copy's line lies on the canvas, clear of the box",
                mapped.intersection(model.document.canvasRect) == mapped && !mapped.intersects(box),
                "line \(mapped), box \(box)")
            try await harness.editors.waitForBase(model)
            let duplicated = try await copiedPixels(controller, harness, context, "the mirrored copy")
            context.check(
                "the copy exports no pixel of the protected line", uncovered(copiedLine, in: duplicated) == 0,
                "\(uncovered(copiedLine, in: duplicated)) uncovered pixels")
            await E2EActions.snapshotEditor(controller, context, shot: "layer-transforms-copy")
        }

        /// Presses an inspector control, scrolling the inspector until SwiftUI has built it.
        private static func press(
            _ identifier: String, in controller: EditorWindowController, _ root: NSView, _ context: ScenarioContext
        ) async throws {
            for fraction in [0, 0.5, 1.0] {
                await E2EActions.scrollInspector(controller, to: fraction)
                await E2ESnapshot.settle(root)
                if E2EAccessibilityControl.exists(identifier, in: root) { break }
            }
            try E2EAccessibilityControl.pressCheckingEffect(identifier, in: root, context)
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
