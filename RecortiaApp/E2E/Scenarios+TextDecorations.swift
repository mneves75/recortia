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
            try context.require("mixed-selection fixture has custom fill", model.setTextBackgroundColor(.yellow))
            model.clearSelection()
            try context.require("future background resets independently", model.setTextBackgroundColor(nil))
            model.selectAll()
            try context.require("the background fixture has mixed selection", model.selection.count > 1)
            let layers = model.document.layers
            await E2EActions.scrollInspector(controller, to: 0.2)
            await E2ESnapshot.settle(root)
            try context.require(
                "Reset remains enabled for colored boxed text in a mixed selection",
                try E2EAccessibilityControl.isEnabled("textBackground.reset", in: root, context))
            context.check(
                "the native color well shows the selected boxed fill, not the future default",
                EditorWindowController.all(NSColorWell.self, in: root).contains {
                    guard let color = $0.color.usingColorSpace(.sRGB) else { return false }
                    return abs(color.redComponent - 1) < 0.01 && abs(color.greenComponent - 214.0 / 255) < 0.01
                        && color.blueComponent < 0.01
                })
            try E2EAccessibilityControl.press("textBackground.reset", in: root, context)
            context.check(
                "mixed-selection Reset clears boxed fill and preserves unrelated layers",
                model.document.annotations.last?.style.fill == nil && model.document.layers == layers)
            model.undo()
            context.check(
                "mixed-selection Reset has independent undo",
                model.document.annotations.last?.style.fill == .yellow && model.document.layers == layers)
            await E2ESnapshot.settle(root)
            context.check(
                "undo restores native Reset eligibility in mixed selection",
                try E2EAccessibilityControl.isEnabled("textBackground.reset", in: root, context))
            model.clearSelection()
            try context.require("second text has an explicit clear background", model.setTextBackgroundColor(.clear))
            E2EActions.click(model, .text, at: E2EActions.point(400, 200))
            try context.require(
                "second boxed text opens native input",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
            let second = try context.unwrap(
                "second native text", EditorWindowController.first(NSTextView.self, in: canvas))
            second.insertText("second", replacementRange: second.selectedRange())
            controller.commitPendingText()
            model.selectAll()
            await E2EActions.scrollInspector(controller, to: 0.2)
            await E2ESnapshot.settle(root)
            context.check(
                "different selected backgrounds are explicitly described",
                try E2EAccessibilityControl.text(.value, for: "textBackground.mixed", in: root, context)
                    == String(localized: "Mixed backgrounds", table: "Editor"))
            try E2EAccessibilityControl.press("textBackground.reset", in: root, context)
            context.check(
                "Reset clears all selected box backgrounds",
                model.document.annotations.allSatisfy { $0.style.fill == nil })
            model.undo()
            await E2ESnapshot.settle(root)
            context.check(
                "undo restores the mixed-background description",
                try E2EAccessibilityControl.text(.value, for: "textBackground.mixed", in: root, context)
                    == String(localized: "Mixed backgrounds", table: "Editor"))
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
            try await decoratedWrapping(harness, document: model.document, context)
        }

        private static func decoratedWrapping(
            _ harness: E2EHarness, document: Document, _ context: ScenarioContext
        ) async throws {
            for appearance in [TextAppearance.outlined, .boxed, .roundedBoxed, .monospacedBoxed] {
                var wrapped = document
                let annotation = Annotation(
                    kind: .text(
                        .init(
                            origin: E2EActions.point(60, 40), string: "ação🙂\nمرحبا mundo",
                            fontSize: 24, maxWidth: 90, appearance: appearance)),
                    style: Annotation.Style(stroke: .red, fill: .yellow, lineWidth: 1))
                wrapped.annotations = [annotation]
                let controller = harness.editors.open(DocumentSession(document: wrapped))
                let canvas = try context.unwrap("\(appearance.rawValue) wrapped canvas", controller.canvasView)
                controller.model.beginEditingText(annotation.id)
                try context.require(
                    "\(appearance.rawValue) wrapped text opens native input",
                    await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
                let input = try context.unwrap(
                    "\(appearance.rawValue) wrapped input", EditorWindowController.first(NSTextView.self, in: canvas))
                let container = try context.unwrap("wrapped text container", input.textContainer)
                input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
                input.setMarkedText(
                    "ção", selectedRange: NSRange(location: 3, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                let marked = input.markedRange(), selected = input.selectedRange(), string = input.string
                for zoom in [0.25, 2.0] {
                    controller.model.setZoom(
                        zoom / controller.model.backingScale,
                        anchor: controller.model.viewport.viewPoint(E2EActions.point(60, 40)))
                    await E2ESnapshot.settle(controller.contentRoot)
                    context.check(
                        "\(appearance.rawValue) reaches the displayed \(zoom * 100)% zoom",
                        abs(controller.model.zoomPercent - zoom * 100) < 0.001)
                    context.check(
                        "\(appearance.rawValue) preserves the content-width constraint at \(zoom)",
                        abs(container.containerSize.width - 90 * controller.model.viewport.zoom) < 0.001)
                    context.check(
                        "\(appearance.rawValue) preserves composed wrapped input at \(zoom)",
                        input.hasMarkedText() && input.markedRange() == marked && input.selectedRange() == selected
                            && input.string == string)
                    let used: CGRect
                    if let layout = input.textLayoutManager {
                        let range = try context.unwrap(
                            "native text document range", layout.textContentManager?.documentRange)
                        layout.ensureLayout(for: range)
                        layout.textViewportLayoutController.layoutViewport()
                        used = layout.usageBoundsForTextContainer
                    } else {
                        let layout = try context.unwrap("native layout manager", input.layoutManager)
                        layout.ensureLayout(for: container)
                        used = layout.usedRect(for: container)
                    }
                    await E2ESnapshot.settle(controller.contentRoot)
                    context.check(
                        "\(appearance.rawValue) viewport layout preserves marked input",
                        input.hasMarkedText() && input.markedRange() == marked && input.selectedRange() == selected
                            && input.string == string)
                    context.check(
                        "\(appearance.rawValue) native input contains all wrapped glyphs at \(zoom)",
                        input.bounds.height >= used.maxY,
                        "bounds=\(input.bounds); used=\(used); container=\(container.containerSize)")
                }
                let livePixels = try E2EActions.decode(
                    E2ESnapshot.png(of: input, background: .black), "wrapped native glyph pixels", context)
                var lowerLinePixels = 0
                let lowerLineY = min(livePixels.height, Int(36 * controller.model.viewport.zoom * E2ESnapshot.scale))
                for y in lowerLineY..<livePixels.height {
                    for x in 0..<livePixels.width {
                        let pixel = livePixels.pixel(x: x, y: y)
                        if pixel.r > 180 && pixel.g < 120 && pixel.b < 120 { lowerLinePixels += 1 }
                    }
                }
                context.check(
                    "\(appearance.rawValue) paints native glyphs below the first line", lowerLinePixels > 0)
                input.unmarkText()
                await E2ESnapshot.settle(controller.contentRoot)
                context.check("unmarking preserves the complete draft", input.string == string)
                let finalFont =
                    input.textStorage?.attribute(
                        .font, at: string.utf16.count - 1, effectiveRange: nil) as? NSFont
                context.check(
                    "composed text follows the displayed font size after zoom",
                    abs((finalFont?.pointSize ?? 0) - 24 * controller.model.viewport.zoom) < 0.001)
                let linePixels = try E2EActions.decode(
                    E2ESnapshot.png(of: input, background: .white), "native wrapped lines", context)
                let window = try context.unwrap("wrapped text window", input.window)
                for index in [0, 7, 13, string.utf16.count - 1] {
                    let screen = input.firstRect(
                        forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
                    let local = input.convert(window.convertFromScreen(screen), from: nil)
                    let sample = local.intersection(input.bounds)
                    try context.require("native glyph anchor lies in the input", !sample.isNull && !sample.isEmpty)
                    let scale = E2ESnapshot.scale
                    let minX = max(0, Int(floor(sample.minX * scale)))
                    let maxX = min(linePixels.width, Int(ceil(sample.maxX * scale)))
                    let minY = max(0, Int(floor(sample.minY * scale)))
                    let maxY = min(linePixels.height, Int(ceil(sample.maxY * scale)))
                    var ink = 0
                    for y in minY..<maxY {
                        for x in minX..<maxX {
                            let pixel = linePixels.pixel(x: x, y: y)
                            if pixel.r < 180 || pixel.g < 180 || pixel.b < 180 { ink += 1 }
                        }
                    }
                    context.check(
                        "\(appearance.rawValue) paints the native glyph at UTF-16 index \(index)", ink > 0)
                }
                if let root = controller.contentRoot { context.snapshot(root, shot: "\(appearance.rawValue)-wrapped") }
                input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
                input.breakUndoCoalescing()
                harness.textPasteboard.clearContents()
                try context.require(
                    "private plaintext paste fixture is available",
                    harness.textPasteboard.setString(" teste", forType: .string))
                try context.require(
                    "native input accepts private plaintext paste",
                    input.readSelection(from: harness.textPasteboard, type: .string))
                context.check("native paste preserves Unicode", input.string == string + " teste")
                input.breakUndoCoalescing()
                await E2ESnapshot.settle(controller.contentRoot)
                input.deleteBackward(nil)
                context.check("native deletion removes one character", input.string == string + " test")
                input.breakUndoCoalescing()
                await E2ESnapshot.settle(controller.contentRoot)
                let undo = try context.unwrap("native text undo", input.undoManager)
                undo.undo()
                context.check(
                    "undo restores the draft before the native edit group", input.string == string,
                    "actual=\(input.string); canUndo=\(undo.canUndo)")
                controller.commitPendingText()
                if case .text(let text) = controller.model.document.annotations.last?.kind {
                    context.check(
                        "\(appearance.rawValue) confirms Unicode and wrapping unchanged",
                        text.string == string && text.maxWidth == 90 && text.resolvedAppearance == appearance)
                } else {
                    try context.require("decorated wrapped text remains text", false)
                }
            }
        }
    }
#endif
