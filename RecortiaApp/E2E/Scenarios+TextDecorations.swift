#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging

    @MainActor
    enum TextDecorationScenarios {
        static func decorations(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            controller.window?.orderFront(nil)
            let model = controller.model
            let root = try context.unwrap("decoration editor", controller.contentRoot)
            let canvas = try context.unwrap("decoration canvas", controller.canvasView)
            model.setLineWidth(1)
            model.setFontSize(36)
            E2EActions.click(model, .text, at: E2EActions.point(100, 70))
            try context.require(
                "text input appears",
                await E2EWait.until {
                    EditorWindowController.first(NSTextView.self, in: canvas) != nil
                })
            let input = try context.unwrap(
                "initial native text", EditorWindowController.first(NSTextView.self, in: canvas))
            input.insertText("Água MW🙂", replacementRange: input.selectedRange())
            controller.commitPendingText()
            let annotation = try context.unwrap("text for outline", model.document.annotations.last)
            await E2EActions.scrollInspector(controller, to: 0.5)
            await E2ESnapshot.settle(root)
            try E2EAccessibilityControl.press("textAppearance.outlined", in: root, context)
            try context.require(
                "the native Outlined choice applies",
                await E2EWait.until {
                    model.style.textAppearance == .outlined
                })
            model.beginEditingText(annotation.id)
            try context.require(
                "outlined text reopens natively",
                await E2EWait.until {
                    EditorWindowController.first(NSTextView.self, in: canvas) != nil
                })
            let editor = try context.unwrap(
                "outlined native editor", EditorWindowController.first(NSTextView.self, in: canvas))
            let storage = try context.unwrap("outlined native text storage", editor.textStorage)
            let stroke = storage.attribute(.strokeWidth, at: 0, effectiveRange: nil) as? NSNumber
            try context.require(
                "the native editor retains stroke-and-fill outline attributes", (stroke?.doubleValue ?? 0) < 0)
            context.check("outlined native glyphs have white interiors", editor.textColor == NSColor.white)
            editor.insertText(" café", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            context.check(
                "new native characters retain the outline",
                (storage.attribute(.strokeWidth, at: storage.length - 1, effectiveRange: nil) as? NSNumber)?.doubleValue
                    == stroke?.doubleValue)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.setMarkedText(
                "ação", selectedRange: NSRange(location: 4, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            try context.require("native marked text begins", editor.hasMarkedText())
            let marked = editor.markedRange()
            let selected = editor.selectedRange()
            let string = editor.string
            let canvasFrame = canvas.convert(canvas.bounds, to: root)
            let sidebarX = Int((canvasFrame.minX - 20) * E2ESnapshot.scale)
            let sidebarY = Int(canvasFrame.midY * E2ESnapshot.scale)
            let beforeZoom = try E2EActions.decode(
                E2ESnapshot.png(of: root, background: .windowBackgroundColor), "before text zoom", context)
            try context.require(
                "zoom boundary sample lies in the object list",
                sidebarX >= 0 && sidebarY >= 0 && sidebarX < beforeZoom.width && sidebarY < beforeZoom.height)
            let sidebarPixel = beforeZoom.pixel(x: sidebarX, y: sidebarY)
            model.setZoom(2, anchor: model.viewport.viewPoint(E2EActions.point(100, 70)))
            await E2ESnapshot.settle(root)
            let afterZoom = try E2EActions.decode(
                E2ESnapshot.png(of: root, background: .windowBackgroundColor), "after text zoom", context)
            context.check(
                "zoomed image and native input cannot paint over the object list",
                afterZoom.pixel(x: sidebarX, y: sidebarY) == sidebarPixel)
            context.check(
                "zoom preserves marked text and its selection",
                editor.hasMarkedText() && editor.markedRange() == marked && editor.selectedRange() == selected
                    && editor.string == string)
            context.check(
                "zoom retains the outline percentage",
                (storage.attribute(.strokeWidth, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue
                    == stroke?.doubleValue)
            let outlinedPixels = try E2EActions.decode(
                E2ESnapshot.png(of: editor, background: .black), "native outlined glyphs", context)
            var whitePixels = 0
            var strokePixels = 0
            // The first 100 raster columns contain the initial monochrome glyph, before the emoji.
            for y in 0..<outlinedPixels.height {
                for x in 0..<min(100, outlinedPixels.width) {
                    let pixel = outlinedPixels.pixel(x: x, y: y)
                    if pixel.r > 245 && pixel.g > 245 && pixel.b > 245 { whitePixels += 1 }
                    if pixel.r > 180 && pixel.g < 100 && pixel.b < 100 { strokePixels += 1 }
                }
            }
            context.check("native outlined monochrome glyphs actually paint white fill", whitePixels > 0)
            context.check("native outlined monochrome glyphs actually paint colored stroke", strokePixels > 0)
            context.snapshot(root, shot: "outlined-native-input")
            editor.unmarkText()
            controller.commitPendingText()
            if case .text(let committed) = model.document.annotations.last?.kind {
                context.check(
                    "confirm preserves outlined appearance and composed text",
                    committed.resolvedAppearance == .outlined && committed.string == string)
            } else {
                try context.require("outlined text remains editable", false)
            }

            model.setViewport(.fitting(model.document.canvasRect, in: model.viewportSize, maxZoom: 1))
            await E2EActions.scrollInspector(controller, to: 0.5)
            await E2ESnapshot.settle(root)
            try E2EAccessibilityControl.press("textAppearance.boxed", in: root, context)
            try context.require("boxed background can be customized", model.setTextBackgroundColor(.yellow))
            model.beginEditingText(annotation.id)
            try context.require(
                "boxed text reopens natively",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
            await E2ESnapshot.settle(root)
            let image = try E2ESnapshot.png(of: canvas, background: .underPageBackgroundColor)
            let pixels = try E2EActions.decode(image, "live boxed text", context)
            let paddingPoint = model.viewport.viewPoint(E2EActions.point(95, 75))
            try context.require(
                "live background sample lies inside its rendered canvas",
                paddingPoint.x >= 0 && paddingPoint.y >= 0
                    && paddingPoint.x * E2ESnapshot.scale < Double(pixels.width)
                    && paddingPoint.y * E2ESnapshot.scale < Double(pixels.height))
            let paddingPixel = pixels.pixel(
                x: Int(paddingPoint.x * E2ESnapshot.scale), y: Int(paddingPoint.y * E2ESnapshot.scale))
            try context.require(
                "native editing retains the colored padding outside the text origin",
                paddingPixel.r == RGBA.yellow.r && paddingPixel.g == RGBA.yellow.g
                    && paddingPixel.b == RGBA.yellow.b && paddingPixel.a == 255, "actual=\(paddingPixel)")
            context.snapshot(root, shot: "boxed-native-input")
            model.cancelTextEditing()
            await E2EActions.scrollInspector(controller, to: 0.2)
            await E2ESnapshot.settle(root)
            try E2EAccessibilityControl.press("textBackground.reset", in: root, context)
            try context.require(
                "native Reset restores the automatic white background",
                model.document.annotations.last?.style.fill == nil && model.style.textBackgroundColor == nil)
            model.undo()
            context.check(
                "native Reset owns a separate undo step", model.document.annotations.last?.style.fill == .yellow)
            model.redo()
            context.check("native Reset can be redone", model.document.annotations.last?.style.fill == nil)
            context.snapshot(root, shot: "boxed-background-controls")

            for appearance in [TextAppearance.outlined, .boxed, .roundedBoxed, .monospacedBoxed] {
                await E2EActions.scrollInspector(controller, to: 0.5)
                await E2ESnapshot.settle(root)
                let identifier = "textAppearance.\(appearance.rawValue)"
                try E2EAccessibilityControl.press(identifier, in: root, context)
                try context.require(
                    "native \(appearance.rawValue) choice applies",
                    await E2EWait.until { model.style.textAppearance == appearance })
                await E2ESnapshot.settle(root)
                context.check(
                    "native \(appearance.rawValue) exposes selected state",
                    try E2EAccessibilityControl.text(.value, for: identifier, in: root, context)
                        == String(localized: "Selected", table: "Editor"))
                model.beginEditingText(annotation.id)
                try context.require(
                    "\(appearance.rawValue) reopens native input",
                    await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
                let live = try context.unwrap(
                    "\(appearance.rawValue) live input", EditorWindowController.first(NSTextView.self, in: canvas))
                context.check(
                    "\(appearance.rawValue) uses its resolved native font",
                    live.font == (try TextLayout.nativeFont(for: appearance, size: 36 * model.viewport.zoom)))
                if appearance.isBoxed {
                    context.check(
                        "background Reset is disabled during \(appearance.rawValue) input",
                        try !E2EAccessibilityControl.isEnabled("textBackground.reset", in: root, context))
                }
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "\(appearance.rawValue)-native")
                model.cancelTextEditing()
            }
            if let window = controller.window {
                window.setContentSize(NSSize(width: 980, height: 560))
                window.appearance = NSAppearance(named: .darkAqua)
                model.zoomToFit()
                await E2EActions.scrollInspector(controller, to: 0.5)
                await E2ESnapshot.settle(root)
                context.check("decorations fit the minimum editor width", abs(root.bounds.width - 980) < 1)
                context.snapshot(root, shot: "decorations-compact-dark")
                await E2EActions.scrollInspector(controller, to: 0.2)
                await E2ESnapshot.settle(root)
                context.snapshot(root, shot: "background-controls-compact-dark")
            }
        }
    }
#endif
