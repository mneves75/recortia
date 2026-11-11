#if DEBUG
    import AppKit
    import ApplicationServices
    import Domain
    import Features

    /// The inspector shows only what the person is working on (FR-04, FR-06): the Image tab with
    /// nothing selected, the active tool's or the selection's format otherwise, and the secure or
    /// cosmetic redaction wording for the matching tool.
    @MainActor
    enum InspectorScenarios {
        static func contextual(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            controller.window?.orderFront(nil)
            let model = controller.model
            let root = try context.unwrap("inspector editor content", controller.contentRoot)
            let canvas = try context.unwrap("inspector canvas", controller.canvasView)
            let preferences = harness.settings.preferences
            defer { harness.settings.update { $0.annotationPalette = preferences.annotationPalette } }
            let p = E2EActions.point

            func expect(_ situation: String, present: [String], absent: [String]) async {
                E2ERunner.log("inspector-context: \(situation)")
                let shown = await seen(Set(present + absent), controller, root)
                for identifier in present {
                    context.check("\(situation): \(identifier) is shown", shown.contains(identifier))
                }
                for identifier in absent {
                    context.check("\(situation): \(identifier) is not shown", !shown.contains(identifier))
                }
            }

            model.selectTool(.select)
            model.clearSelection()
            await E2ESnapshot.settle(root)
            await expect(
                "nothing selected with Select", present: ["inspector.tab", "image.background"],
                absent: ["style.fill", "style.lineWidth", "style.textSize", "frame.x"])
            await E2EActions.snapshotEditor(controller, context, shot: "image")

            model.selectTool(.arrow)
            await E2ESnapshot.settle(root)
            await expect(
                "arrow tool", present: ["arrow.straight", "arrow.curved", "style.lineWidth"],
                absent: ["style.fill", "style.textSize", "image.background", "redaction.cosmeticWarning"])
            await E2EActions.snapshotEditor(controller, context, shot: "arrow-tool")

            E2EActions.drag(model, .rectangle, from: p(40, 40), to: p(300, 220))
            let rectangle = try context.unwrap("rectangle annotation", model.document.annotations.last)
            model.selectTool(.select)
            model.select(.annotation(rectangle.id))
            await E2ESnapshot.settle(root)
            await expect(
                "rectangle selected",
                present: ["style.fill", "style.lineWidth", "frame.x", "frame.y", "frame.width", "frame.height"],
                absent: ["style.textSize", "arrow.straight", "textAppearance.standard", "image.background"])
            await E2EActions.snapshotEditor(controller, context, shot: "rectangle-selected")

            E2EActions.click(model, .text, at: p(380, 80))
            try context.require(
                "text opens a native editor",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
            let input = try context.unwrap(
                "native text editor", EditorWindowController.first(NSTextView.self, in: canvas))
            input.insertText("Revisão", replacementRange: input.selectedRange())
            controller.commitPendingText()
            let text = try context.unwrap("text annotation", model.document.annotations.last)
            model.selectTool(.select)
            model.select(.annotation(text.id))
            await E2ESnapshot.settle(root)
            await expect(
                "plain text selected",
                present: ["style.textSize"] + TextAppearance.allCases.map { "textAppearance.\($0.rawValue)" },
                absent: ["style.lineWidth", "arrow.straight", "image.background"])
            await E2EActions.snapshotEditor(controller, context, shot: "text-selected")

            try chooseTab(1, controller, root, context)
            await E2ESnapshot.settle(root)
            await expect(
                "manual Image with text selected", present: ["image.background"], absent: ["style.textSize"])
            await E2ESnapshot.settle(root)
            context.check(
                "the manual Image choice survives while selection and tool stay the same",
                await seen(["image.background"], controller, root).contains("image.background"))
            model.select(.annotation(rectangle.id))
            await E2ESnapshot.settle(root)
            await expect(
                "selecting after a manual Image choice", present: ["style.fill"], absent: ["image.background"])
            try chooseTab(1, controller, root, context)
            await E2ESnapshot.settle(root)
            context.check(
                "Image can be chosen again",
                await seen(["image.background"], controller, root).contains("image.background"))
            model.clearSelection()
            model.selectTool(.ellipse)
            await E2ESnapshot.settle(root)
            await expect(
                "changing tool after a manual Image choice", present: ["style.fill"], absent: ["image.background"])

            // The renderer fills step discs and sizes them by line width; outlined text strokes
            // with line width, and boxed text paints its background through its own controls.
            model.selectTool(.step)
            await E2ESnapshot.settle(root)
            await expect(
                "step tool", present: ["style.fill", "style.lineWidth"], absent: ["style.textSize"])
            model.selectTool(.text)
            try context.require("outlined is the future text style", model.setTextAppearance(.outlined))
            await E2ESnapshot.settle(root)
            await expect(
                "text tool with outlined style", present: ["style.lineWidth", "style.textSize", "style.fill"],
                absent: ["textBackground.color"])
            try context.require("boxed is the future text style", model.setTextAppearance(.boxed))
            await E2ESnapshot.settle(root)
            await expect(
                "text tool with boxed style", present: ["textBackground.color", "style.textSize"],
                absent: ["style.fill", "style.lineWidth"])
            try context.require("standard is the future text style", model.setTextAppearance(.standard))

            model.selectTool(.blur)
            await E2ESnapshot.settle(root)
            await expect(
                "blur tool", present: ["redaction.cosmeticWarning"],
                absent: ["redaction.color", "style.lineWidth", "image.background"])
            await E2EActions.snapshotEditor(controller, context, shot: "blur-tool")

            model.selectTool(.redact)
            await E2ESnapshot.settle(root)
            await expect(
                "redact tool", present: ["redaction.color"],
                absent: ["redaction.cosmeticWarning", "style.lineWidth", "image.background"])
            await E2EActions.snapshotEditor(controller, context, shot: "redact-tool")

            model.selectTool(.rectangle)
            let palette: [RGBA] = (0..<12).map { (index: Int) -> RGBA in
                let red = UInt8(20 + index * 18)
                let green = UInt8(200 - index * 12)
                return RGBA(r: red, g: green, b: 90)
            }
            for color in palette {
                model.setStrokeColor(color)
                context.check("palette fixture saves \(color.hex)", model.saveCurrentStrokeColor())
            }
            await E2ESnapshot.settle(root)
            await expect(
                "twelve saved colors",
                present: palette.map { "palette.apply.\($0.hex.dropFirst())" } + ["palette.save", "palette.remove"],
                absent: [])
            await E2EActions.snapshotEditor(controller, context, shot: "saved-colors")

            let window = try context.unwrap("inspector editor window", controller.window)
            window.setContentSize(NSSize(width: 980, height: 560))
            window.appearance = NSAppearance(named: .darkAqua)
            model.zoomToFit()
            await E2ESnapshot.settle(root)
            context.check("the inspector fits the minimum editor width", abs(root.bounds.width - 980) < 1)
            context.snapshot(root, shot: "saved-colors-compact-dark")
            model.selectTool(.select)
            model.select(.annotation(text.id))
            await E2ESnapshot.settle(root)
            await E2EActions.scrollInspector(controller, to: 0)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "text-selected-compact-dark")
        }

        /// Which of `identifiers` the editor shows anywhere along the inspector's scroll range. The
        /// grouped form creates rows as they scroll into view, so an absence is only meaningful
        /// after visiting the whole range.
        private static func seen(_ identifiers: Set<String>, _ controller: EditorWindowController, _ root: NSView)
            async -> Set<String>
        {
            // SwiftUI creates accessibility nodes lazily; query only this runner's own process.
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            var windows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
            var found: Set<String> = []
            for fraction in [0.0, 0.5, 1.0] {
                await E2EActions.scrollInspector(controller, to: fraction)
                await E2ESnapshot.settle(root, for: .milliseconds(100))
                for identifier in identifiers.subtracting(found)
                where E2EAccessibilityControl.isPresent(identifier, in: root) {
                    found.insert(identifier)
                }
                if found == identifiers { break }
            }
            await E2EActions.scrollInspector(controller, to: 0)
            return found
        }

        /// Selects a segment of the inspector's Format/Image picker the way a click ends: the
        /// segmented control's own selection and action, inside this runner's window.
        private static func chooseTab(
            _ segment: Int, _ controller: EditorWindowController, _ root: NSView, _ context: ScenarioContext
        ) throws {
            let canvas = try context.unwrap("tab canvas", controller.canvasView)
            // The inspector column sits beside the canvas; the toolbar's Save split button sits above it.
            let column = canvas.convert(canvas.bounds, to: root)
            let pickers = EditorWindowController.all(NSSegmentedControl.self, in: root).filter {
                let frame = $0.convert($0.bounds, to: root)
                return $0.segmentCount == 2 && frame.minX > column.maxX && frame.midY > column.minY
                    && frame.midY < column.maxY
            }
            let picker = try context.unwrap(
                "the inspector has one Format/Image picker", pickers.count == 1 ? pickers.first : nil,
                "found \(pickers.count)")
            picker.setSelected(true, forSegment: segment)
            try context.require("the picker sends its action", picker.sendAction(picker.action, to: picker.target))
        }
    }
#endif
