#if DEBUG
    import AppKit
    import Domain
    import Features
    import RecortiaFixtures

    /// Framing presets through the real Image-tab controls (FR-13, A-8): a swatch, the aspect menu,
    /// the Balance switch and Save as Default Framing, checked in the exported files, then a new
    /// synthetic capture that opens with the saved framing.
    @MainActor
    enum FramingScenarios {
        static let body = ChartFixture.Color(40, 90, 200)

        /// 320 × 224, like a window captured with its shadow: an opaque body in the top-left
        /// 300 × 200, a half-black shadow under it and a transparent margin to its right.
        static func windowLike() throws -> CGImage {
            var bytes: [UInt8] = []
            for y in 0..<224 {
                for x in 0..<320 {
                    if x < 300, y < 200 {
                        bytes += [body.r, body.g, body.b, 255]
                    } else if y >= 200, x < 304 {
                        bytes += [0, 0, 0, 128]
                    } else {
                        bytes += [0, 0, 0, 0]
                    }
                }
            }
            return try ChartFixture.image(width: 320, height: 224, straightRGBA: bytes)
        }

        /// Left, top, right and bottom margins around the body colour in an export.
        static func bodyMargins(_ p: DecodedPixels) -> (left: Int, top: Int, right: Int, bottom: Int)? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<p.height {
                for x in 0..<p.width where E2EActions.distance(p.pixel(x: x, y: y), body) <= 2 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            return maxX < 0 ? nil : (minX, minY, p.width - 1 - maxX, p.height - 1 - maxY)
        }

        static func framingPresets(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let saved = harness.settings.preferences.defaultFraming
            let savedRecipes = harness.settings.preferences.framingRecipes
            defer {
                harness.settings.update {
                    $0.defaultFraming = saved
                    $0.framingRecipes = savedRecipes
                }
            }
            harness.settings.update {
                $0.defaultFraming = nil
                $0.framingRecipes = nil
            }
            let image: CGImage
            do { image = try windowLike() } catch { throw E2EAbort("framing fixture: \(error)") }
            let controller = try await harness.openImported(image, name: "framing.png")
            let model = controller.model
            let root = try context.unwrap("editor content", controller.contentRoot)
            let window = try context.unwrap("editor window", controller.window)
            try await E2EAccessibilityControl.showAndActivate(window, context)
            model.selectTool(.select)
            model.clearSelection()
            controller.panes.chosenInspectorTab = .image
            func show(_ fraction: Double = 0) async {
                await E2ESnapshot.settle(root)
                await E2EActions.scrollInspector(controller, to: fraction)
                await E2ESnapshot.settle(root)
            }
            var exports = 0
            func exported(_ controller: EditorWindowController, _ name: String) async throws -> DecodedPixels {
                exports += 1
                let url = harness.output.workDirectory.appending(path: "framing-\(exports)-\(name).png")
                let outcome = await E2EActions.export(controller, .save(url, format: .fixed(.png), replacing: nil))
                try context.require("\(name) exported", outcome == .saved(url), "\(outcome)")
                let decoded = try E2EActions.decode(try Data(contentsOf: url), name, context)
                let expected = controller.model.document.outputPixelSize(exportScale: 1)
                context.check(
                    "\(name): the file is the document's output size",
                    decoded.width == expected.width && decoded.height == expected.height,
                    "\(decoded.width) × \(decoded.height), expected \(expected.width) × \(expected.height)")
                return decoded
            }

            // A swatch applies its background.
            await show()
            try E2EAccessibilityControl.click("image.swatch.0", in: root, context)
            try context.require(
                "the White swatch applies a white background",
                await E2EWait.until { model.document.presentation.background == .solid(.white) },
                "\(model.document.presentation.background)")
            model.setPadding(24)
            context.check(
                "Balance is hidden while the aspect is Free",
                !E2EAccessibilityControl.isPresent("image.balance", in: root))

            // The aspect menu names presets by ratio only.
            await show()
            let entries = try await E2EAccessibilityControl.chooseFromMenu(
                "1:1", opening: "image.aspect", in: root, context)
            let free = String(localized: "Free", table: "Editor")
            context.check(
                "the aspect menu offers Free and five ratios",
                entries.map(\.title) == [free, "1:1", "4:5", "16:9", "9:16", "3:2"], "\(entries)")
            try context.require(
                "1:1 is chosen", await E2EWait.until { model.document.presentation.aspect == .square },
                "\(model.document.presentation.aspect)")
            await show()
            context.check("Balance appears, on", E2EAccessibilityControl.isPresent("image.balance", in: root))
            context.check("Balance starts on", model.document.presentation.balancesContent)

            // 1:1, balanced: the opaque body is centred although the shadow margin is not even.
            let square = try await exported(controller, "square")
            context.check(
                "1:1 is 368 × 368", square.width == 368 && square.height == 368, "\(square.width) × \(square.height)")
            let balanced = try context.unwrap("the body is in the 1:1 export", bodyMargins(square))
            context.check(
                "balanced: equal margins around the window body",
                balanced.left == 34 && balanced.right == 34 && balanced.top == 84 && balanced.bottom == 84,
                "\(balanced)")
            context.check(
                "the white swatch frames the output",
                square.pixel(x: 0, y: 0) == ChartFixture.Color(255, 255, 255), square.pixel(x: 0, y: 0).hex)
            await E2EActions.snapshotEditor(controller, context, shot: "square")
            await E2EActions.darkEditor(controller, context, shot: "square", surface: "editor, Image tab framing")

            // Balance off centres the box, shadow margin included.
            await show()
            try E2EAccessibilityControl.pressCheckingEffect("image.balance", in: root, context)
            try context.require(
                "Balance turns off", await E2EWait.until { !model.document.presentation.balancesContent })
            let boxed = try context.unwrap(
                "the body is in the unbalanced export", bodyMargins(try await exported(controller, "square-box")))
            context.check(
                "unbalanced: the 320 × 224 box is centred, so the body sits up and left",
                boxed.left == 24 && boxed.right == 44 && boxed.top == 72 && boxed.bottom == 96, "\(boxed)")
            await show()
            try E2EAccessibilityControl.pressCheckingEffect("image.balance", in: root, context)
            try context.require(
                "Balance turns back on", await E2EWait.until { model.document.presentation.balancesContent })

            // 9:16 with the radial swatch.
            await show()
            _ = try await E2EAccessibilityControl.chooseFromMenu("9:16", opening: "image.aspect", in: root, context)
            try context.require(
                "9:16 is chosen", await E2EWait.until { model.document.presentation.aspect == .portrait9x16 })
            await show()
            try E2EAccessibilityControl.click("image.swatch.9", in: root, context)
            try context.require(
                "the radial swatch applies",
                await E2EWait.until {
                    if case .radialGradient = model.document.presentation.background { return true }
                    return false
                })
            let tall = try await exported(controller, "portrait")
            context.check(
                "9:16 is 369 × 656, an exact ratio",
                tall.width == 369 && tall.height == 656 && tall.width * 16 == tall.height * 9,
                "\(tall.width) × \(tall.height)")
            let tallBody = try context.unwrap("the body is in the 9:16 export", bodyMargins(tall))
            context.check(
                "9:16 balanced: the body is centred",
                abs(tallBody.left - tallBody.right) <= 1 && tallBody.top == 228 && tallBody.bottom == 228, "\(tallBody)"
            )
            let corner = tall.pixel(x: 0, y: 0)
            context.check(
                "the radial gradient reaches its edge colour in the corner",
                E2EActions.distance(corner, ChartFixture.Color(142, 142, 147)) <= 8, corner.hex)
            model.setShowsOutputPreview(true)
            await E2EActions.snapshotEditor(controller, context, shot: "portrait-preview")
            await E2EActions.darkEditor(
                controller, context, shot: "portrait-preview", surface: "editor, framed preview")
            model.setShowsOutputPreview(false)

            // Save as Default Framing: one preference, applied to the next capture only.
            let framing = model.document.presentation
            await show(1)
            let resetBeforeSave = try E2EAccessibilityControl.isEnabled("image.resetDefaultFraming", in: root, context)
            context.check("Reset Default Framing is unavailable before a save", !resetBeforeSave)
            try E2EAccessibilityControl.press("image.saveDefaultFraming", in: root, context)
            try context.require(
                "the framing is saved as the default",
                await E2EWait.until { harness.settings.preferences.defaultFraming == framing })
            await show(1)
            let saveAfterSave = try E2EAccessibilityControl.isEnabled("image.saveDefaultFraming", in: root, context)
            context.check("Save is unavailable while the framing is the saved one", !saveAfterSave)
            await E2EActions.snapshotEditor(controller, context, shot: "saved")
            await E2EActions.darkEditor(controller, context, shot: "saved", surface: "editor, saved framing")

            let captured = try await E2EActions.captureRegion(
                harness, CGRect(x: 0, y: 0, width: 300, height: 200), context)
            context.check(
                "a new capture opens with the saved framing", captured.model.document.presentation == framing,
                "\(captured.model.document.presentation)")
            let capturedExport = try await exported(captured, "capture")
            context.check(
                "the capture exports 648 × 1152, 9:16",
                capturedExport.width == 648 && capturedExport.height == 1152,
                "\(capturedExport.width) × \(capturedExport.height)")
            context.check("the framed document is unchanged", model.document.presentation == framing)

            // Reset clears the default; open documents keep their framing.
            let capturedWindow = try context.unwrap("captured editor window", captured.window)
            try await E2EAccessibilityControl.showAndActivate(capturedWindow, context)
            captured.model.selectTool(.select)
            captured.model.clearSelection()
            captured.panes.chosenInspectorTab = .image
            let capturedRoot = try context.unwrap("captured editor content", captured.contentRoot)
            await E2ESnapshot.settle(capturedRoot)
            await E2EActions.scrollInspector(captured, to: 1)
            await E2ESnapshot.settle(capturedRoot)
            try E2EAccessibilityControl.click("image.resetDefaultFraming", in: capturedRoot, context)
            try context.require(
                "Reset clears the default", await E2EWait.until { harness.settings.preferences.defaultFraming == nil })
            context.check("the open capture keeps its framing", captured.model.document.presentation == framing)
            let plain = try await E2EActions.captureRegion(
                harness, CGRect(x: 0, y: 0, width: 300, height: 200), context)
            context.check(
                "the next capture opens unframed", plain.model.document.presentation == .plain,
                "\(plain.model.document.presentation)")
            try await verifyOutputDecoration(plain, context)
            let decorated = try await exported(plain, "decorated")
            let black = ChartFixture.Color(0, 0, 0)
            context.check(
                "the decoration is present in the exported file",
                decorated.pixel(x: 0, y: 0) == black
                    && decorated.pixel(x: decorated.width - 1, y: decorated.height - 1) == black)
            try await namedRecipes(controller, context) {
                let fromRecipe = try await exported(controller, "recipe-replay")
                context.check("the named recipe reproduces all the original output pixels", fromRecipe == tall)
            }
        }

        private static func verifyOutputDecoration(_ editor: EditorWindowController, _ context: ScenarioContext)
            async throws
        {
            let window = try context.unwrap("editor window for decoration", editor.window)
            let root = try context.unwrap("editor content for decoration", editor.contentRoot)
            try await E2EAccessibilityControl.showAndActivate(window, context)
            editor.panes.chosenInspectorTab = .image
            await E2ESnapshot.settle(root)
            await E2EActions.scrollInspector(editor, to: 0)
            await E2ESnapshot.settle(root)
            try await E2EAccessibilityControl.setDisclosure(
                "image.decoration", titled: String(localized: "Output Decoration", table: "Editor"),
                expanded: true, in: root, context)
            try E2EAccessibilityControl.click("image.decoration.border", in: root, context)
            try context.require(
                "the border control applies its default width",
                await E2EWait.until { editor.model.document.presentation.border?.width == 4 })
            try E2EAccessibilityControl.press("image.decoration.applyWatermark", in: root, context)
            try context.require(
                "blank watermark text is refused without editing",
                await E2EWait.until {
                    E2EAccessibilityControl.isPresent("image.decoration.textError", in: root)
                        && editor.model.document.presentation.watermark == nil
                })
            try E2EAccessibilityControl.click("image.decoration.watermark", in: root, context)
            try context.require(
                "the watermark control opens its native text editor",
                await E2EWait.until { (window.firstResponder as? NSTextView)?.isFieldEditor == true })
            let field = try context.unwrap("watermark field editor", window.firstResponder as? NSTextView)
            field.insertText("Revisão", replacementRange: field.selectedRange())
            try context.require("typing reaches the watermark field", field.string == "Revisão")
            try E2EAccessibilityControl.press("image.decoration.applyWatermark", in: root, context)
            try context.require(
                "the native field commits the accented watermark",
                await E2EWait.until { editor.model.document.presentation.watermark?.text == "Revisão" })
            editor.model.undo()
            context.check("one undo removes the watermark", editor.model.document.presentation.watermark == nil)
            editor.model.redo()
            context.check(
                "redo restores the watermark", editor.model.document.presentation.watermark?.text == "Revisão")
            editor.model.setShowsOutputPreview(true)
            await E2EActions.snapshotEditor(editor, context, shot: "output-decoration")
            await E2EActions.darkEditor(editor, context, shot: "output-decoration", surface: "decorated output preview")
            editor.model.setShowsOutputPreview(false)
        }

        private static func namedRecipes(
            _ controller: EditorWindowController, _ context: ScenarioContext,
            verifyAppliedOutput: () async throws -> Void
        ) async throws {
            let root = try context.unwrap("recipe controls root", controller.contentRoot)
            let window = try context.unwrap("recipe editor window", controller.window)
            try await E2EAccessibilityControl.showAndActivate(window, context)
            let model = controller.model
            let framing = model.document.presentation
            let name = "Café"
            let maximumName = String(repeating: "é", count: 32)
            func click(_ identifier: String) async throws {
                await E2EActions.scrollInspector(controller, to: 1)
                await E2ESnapshot.settle(root)
                try E2EAccessibilityControl.click(identifier, in: root, context)
            }
            try await click("image.saveFramingRecipe")
            try await enterRecipeName(name, in: window, refusing: [""], context)
            let recipe = try context.unwrap("the saved named framing", model.framingRecipes.first)
            context.check(
                "the saved recipe contains the original framing", recipe.name == name && recipe.presentation == framing)
            try await click("image.saveFramingRecipe")
            try await enterRecipeName(
                maximumName, in: window, refusing: ["CAFE\u{301}", maximumName + "a"], context)
            context.check(
                "duplicate save and 65 UTF-8 bytes are refused and 64 UTF-8 bytes are accepted",
                model.framingRecipes.map(\.name) == [name, maximumName])

            model.setPadding(37)
            let revised = model.document.presentation
            model.setShowsOutputPreview(true)
            let undoCount = model.session.undoCount
            await E2EActions.scrollInspector(controller, to: 1)
            await E2ESnapshot.settle(root)
            _ = try await E2EAccessibilityControl.chooseFromMenu(
                name, opening: "image.framingRecipe", in: root, context)
            try E2EAccessibilityControl.click("image.applyFramingRecipe", in: root, context)
            try context.require(
                "applying a recipe restores the whole framing in Preview",
                await E2EWait.until {
                    model.document.presentation == framing && model.showsOutputPreview
                })
            context.check("applying adds one undo step", model.session.undoCount == undoCount + 1)
            try await verifyAppliedOutput()
            model.undo()
            context.check("one undo restores the former framing", model.document.presentation == revised)
            model.redo()
            context.check("one redo reapplies the framing", model.document.presentation == framing)
            let appliedCount = model.session.undoCount
            try model.applyFramingRecipe(recipe.id)
            context.check(
                "applying the current style again succeeds without new history", model.session.undoCount == appliedCount
            )
            try await click("image.saveDefaultFraming")
            try context.require(
                "the applied recipe is saved as the explicit default",
                await E2EWait.until {
                    model.defaultFraming == framing
                })

            let renamed = "Água"
            try await click("image.renameFramingRecipe")
            try await enterRecipeName(renamed, in: window, refusing: [maximumName], context)
            context.check(
                "duplicate rename is refused and a valid rename keeps the recipe identity",
                model.framingRecipes.contains { $0.id == recipe.id && $0.name == renamed })
            try await click("image.deleteFramingRecipe")
            try context.require(
                "deleting removes the named recipe",
                await E2EWait.until {
                    model.framingRecipes.map(\.name) == [maximumName]
                })
            context.check(
                "renaming and deleting leave both the applied framing and the explicit default",
                model.document.presentation == framing && model.defaultFraming == framing)

            model.setPadding(37)
            try await click("image.saveFramingRecipe")
            try await enterRecipeName(renamed, in: window, context)
            let replacement = try context.unwrap(
                "the recreated recipe", model.framingRecipes.first { $0.name == renamed })
            try context.require("reusing a deleted name creates a new identity", replacement.id != recipe.id)
            try checkStaleRecipe(recipe.id, in: model, context)
            model.setShowsOutputPreview(false)
        }

        private static func checkStaleRecipe(_ id: UUID, in model: EditorModel, _ context: ScenarioContext) throws {
            let document = model.document
            let history = model.session.undoCount
            let recipes = model.framingRecipes
            func failsClosed(_ action: () throws(FramingRecipes.Failure) -> Void) -> Bool {
                do {
                    try action()
                    return false
                } catch {
                    return error == .unavailable
                }
            }
            try context.require(
                "a stale ID cannot apply, rename or delete the recreated recipe",
                failsClosed { () throws(FramingRecipes.Failure) in try model.applyFramingRecipe(id) }
                    && failsClosed { () throws(FramingRecipes.Failure) in try model.renameFramingRecipe(id, to: "Outro")
                    }
                    && failsClosed { () throws(FramingRecipes.Failure) in try model.removeFramingRecipe(id) })
            context.check(
                "the recreated recipe, document and history are untouched",
                model.framingRecipes == recipes && model.document == document && model.session.undoCount == history)
        }

        private static func enterRecipeName(
            _ name: String, in window: NSWindow, refusing rejected: [String] = [], _ context: ScenarioContext
        ) async throws {
            let sheet = try context.unwrap(
                "the recipe name sheet",
                await E2EWait.until { window.attachedSheet != nil } ? window.attachedSheet : nil)
            let root = try context.unwrap("recipe name sheet content", sheet.contentView)
            await E2ESnapshot.settle(root)
            func fill(_ text: String) async throws {
                try E2EAccessibilityControl.click("framing.recipeName", in: root, context)
                try context.require(
                    "the name field owns this sheet's editor",
                    await E2EWait.until { (sheet.firstResponder as? NSTextView)?.isFieldEditor == true })
                let editor = try context.unwrap("recipe native field editor", sheet.firstResponder as? NSTextView)
                editor.selectAll(nil)
                editor.insertText(text, replacementRange: editor.selectedRange())
            }
            for rejectedName in rejected {
                try await fill(rejectedName)
                try context.require(
                    "typing clears the previous recipe-name error",
                    await E2EWait.until {
                        !E2EAccessibilityControl.isPresent("framing.recipeNameError", in: root)
                    })
                try E2EAccessibilityControl.click("framing.saveRecipeName", in: root, context)
                try context.require(
                    "the refused name leaves its sheet open with an error",
                    await E2EWait.until {
                        window.attachedSheet === sheet
                            && E2EAccessibilityControl.isPresent("framing.recipeNameError", in: root)
                    })
            }
            try await fill(name)
            try E2EAccessibilityControl.click("framing.saveRecipeName", in: root, context)
            try context.require(
                "saving a valid name closes the sheet",
                await E2EWait.until {
                    window.attachedSheet == nil
                })
        }
    }
#endif
