#if DEBUG
    import AppKit
    import Domain
    import Features

    @MainActor
    enum CurvedArrowScenarios {
        static func editing(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            controller.window?.orderFront(nil)
            try context.require(
                "the synthetic editor is ordered for native actions", controller.window?.isVisible == true)
            let model = controller.model
            let root = try context.unwrap("curve editor content", controller.contentRoot)
            model.selectTool(.arrow)
            await E2EActions.scrollInspector(controller, to: 0)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "arrow-before-action")
            try E2EAccessibilityControl.press("arrow.curved", in: root, context)
            try context.require(
                "the native Curved control changes the future default",
                await E2EWait.until { model.style.curvedArrows })
            E2EActions.drag(model, .arrow, from: E2EActions.point(70, 100), to: E2EActions.point(400, 100))
            let arrow = try context.unwrap("created curved arrow", model.document.annotations.last)
            context.check(
                "creation stores an editable quadratic curve",
                arrow.kind
                    == .arrow(
                        start: Point(x: 70, y: 100), end: Point(x: 400, y: 100), control: Point(x: 235, y: 182.5)))
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "arrow-curved")
            context.check(
                "the native bend X field is enabled",
                try E2EAccessibilityControl.isEnabled("arrow.bendX", in: root, context))
            context.check(
                "the native bend Y field is enabled",
                try E2EAccessibilityControl.isEnabled("arrow.bendY", in: root, context))
            await E2EActions.scrollInspector(controller, to: 0.1)
            try await E2EAccessibilityControl.enterNumber("arrow.bendX", text: "280", in: root, context)
            try context.require(
                "Bend X commits through its native field", await E2EWait.until { model.selectedArrowBend?.x == 280 })
            try await E2EAccessibilityControl.enterNumber("arrow.bendY", text: "170", in: root, context)
            try context.require(
                "Bend Y commits through its native field",
                await E2EWait.until { model.selectedArrowBend == Point(x: 280, y: 170) },
                "actual bend=\(String(describing: model.selectedArrowBend))")
            let edited = try context.unwrap("numerically edited arrow", model.document.annotations.last)
            context.check(
                "native fields describe the visible curve handle",
                edited.kind
                    == .arrow(
                        start: Point(x: 70, y: 100), end: Point(x: 400, y: 100), control: Point(x: 325, y: 240)))
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "arrow-numeric-bend")
            try E2EAccessibilityControl.press("arrow.straight", in: root, context)
            try context.require(
                "the native Straight action is delivered",
                await E2EWait.until {
                    model.document.annotations.last?.kind
                        == .arrow(start: Point(x: 70, y: 100), end: Point(x: 400, y: 100))
                })
            context.check(
                "the native Straight control preserves annotation identity",
                model.document.annotations.last?.id == arrow.id)
            context.check(
                "Straight removes the selected arrow's bend",
                model.document.annotations.last?.kind
                    == .arrow(
                        start: Point(x: 70, y: 100), end: Point(x: 400, y: 100)))
            model.undo()
            context.check("native straightening has an independent Undo", model.document.annotations.last == edited)
            context.check("Undo leaves the explicit future default independent", !model.style.curvedArrows)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "arrow-undo")
            try await qualify(controller, context)
        }

        private static func qualify(_ controller: EditorWindowController, _ context: ScenarioContext) async throws {
            let model = controller.model
            let root = try context.unwrap("curve qualification content", controller.contentRoot)
            let canvas = try context.unwrap("curve canvas", controller.canvasView)
            let curved = try context.unwrap("curve to qualify", model.document.annotations.last)
            model.duplicateSelection()
            let duplicate = try context.unwrap("duplicate curve", model.document.annotations.last)
            context.check(
                "duplication retains curve geometry", duplicate.kind == curved.translated(dx: 10, dy: 10).kind)
            context.check("duplicate has a distinct identity", duplicate.id != curved.id)
            model.undo()
            context.check("duplication has one Undo", model.document.annotations.last == curved)
            model.clearSelection()
            E2EActions.drag(model, .arrow, from: E2EActions.point(70, 250), to: E2EActions.point(400, 250))
            let straight = try context.unwrap("independent straight default", model.document.annotations.last)
            context.check(
                "the future default still creates straight arrows",
                straight.kind == .arrow(start: Point(x: 70, y: 250), end: Point(x: 400, y: 250)))
            model.setSelection([.annotation(curved.id), .annotation(straight.id)])
            await E2ESnapshot.settle(root)
            context.check(
                "mixed arrows expose no false selected Curved value",
                try E2EAccessibilityControl.text(.value, for: "arrow.curved", in: root, context).isEmpty)
            context.check(
                "mixed arrows expose no false selected Straight value",
                try E2EAccessibilityControl.text(.value, for: "arrow.straight", in: root, context).isEmpty)
            context.check(
                "mixed arrows have a localized description",
                try E2EAccessibilityControl.text(.value, for: "arrow.mixed", in: root, context)
                    == String(localized: "Mixed arrow shapes", table: "Editor"))
            context.snapshot(root, shot: "arrow-mixed")
            let mixed = model.document
            let count = model.session.undoCount
            try E2EAccessibilityControl.press("arrow.curved", in: root, context)
            try context.require(
                "mixed selected arrows become curved",
                await E2EWait.until {
                    model.document.annotations.allSatisfy {
                        if case .arrow(_, _, .some) = $0.kind { true } else { false }
                    }
                })
            context.check("mixed style changes are one undo action", model.session.undoCount == count + 1)
            model.undo()
            context.check("Undo restores the mixed geometry", model.document == mixed)
            model.select(.annotation(curved.id))
            model.clearSelection()
            for zoom in [0.25, 2.0] {
                model.setZoom(zoom / model.backingScale, anchor: model.viewport.viewPoint(E2EActions.point(280, 170)))
                await E2ESnapshot.settle(root)
                context.check(
                    "curve reaches displayed \(zoom * 100)% zoom", abs(model.zoomPercent - zoom * 100) < 0.001)
                try verifyBendInk(canvas, model: model, context)
                context.snapshot(canvas, shot: "arrow-\(Int(zoom * 100))-viewport")
                context.snapshot(root, shot: "arrow-\(Int(zoom * 100))-editor")
            }
            if let window = controller.window {
                window.setContentSize(NSSize(width: 980, height: 560))
                window.appearance = NSAppearance(named: .darkAqua)
            }
            model.zoomToFit()
            model.select(.annotation(curved.id))
            await E2EActions.scrollInspector(controller, to: 0.1)
            await E2ESnapshot.settle(root)
            context.check("curve controls fit the minimum editor width", abs(root.bounds.width - 980) < 1)
            context.snapshot(root, shot: "arrow-compact-dark")
            E2EActions.click(model, .text, at: E2EActions.point(520, 350))
            try context.require(
                "text input opens in the same canvas",
                await E2EWait.until {
                    EditorWindowController.first(NSTextView.self, in: canvas) != nil
                })
            let input = try context.unwrap(
                "native composed text input", EditorWindowController.first(NSTextView.self, in: canvas))
            input.setMarkedText(
                "ação", selectedRange: NSRange(location: 4, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            let string = input.string, marked = input.markedRange(), selected = input.selectedRange()
            let before = model.document, style = model.style, editing = model.textEditing
            await E2ESnapshot.settle(root)
            for identifier in ["arrow.curved", "arrow.straight", "arrow.bendX", "arrow.bendY"] {
                context.check(
                    "\(identifier) is disabled during composition",
                    try !E2EAccessibilityControl.isEnabled(identifier, in: root, context))
            }
            context.check(
                "curve commands refuse during composition",
                !model.setArrowCurved(false) && !model.setArrowBend(Point(x: 300, y: 200)))
            context.check(
                "refusal preserves model input and geometry",
                model.document == before && model.style == style && model.textEditing == editing)
            context.check(
                "refusal retains marked native input",
                input.hasMarkedText() && input.string == string && input.markedRange() == marked
                    && input.selectedRange() == selected)
            context.snapshot(root, shot: "arrow-composition-disabled-compact-dark")
            model.cancelTextEditing()
            context.check(
                "overflowing native bend requests refuse",
                !model.setArrowBend(Point(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude)))
            context.check(
                "the refusal retains the valid geometry",
                model.document == before && model.notice == .arrowGeometryRefused)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "arrow-refused-compact-dark")
        }

        private static func verifyBendInk(_ canvas: NSView, model: EditorModel, _ context: ScenarioContext) throws {
            let raster = try E2EActions.decode(
                E2ESnapshot.png(of: canvas, background: .underPageBackgroundColor), "native curved arrow", context)
            let point = model.viewport.viewPoint(E2EActions.point(280, 170))
            let x = Int(point.x * E2ESnapshot.scale), y = Int(point.y * E2ESnapshot.scale)
            try context.require(
                "the visible bend sample lies inside the canvas",
                x >= 2 && y >= 2 && x + 2 < raster.width && y + 2 < raster.height)
            var red = 0
            for row in (y - 2)...(y + 2) {
                for column in (x - 2)...(x + 2) {
                    let pixel = raster.pixel(x: column, y: row)
                    if pixel.r > 160 && pixel.g < 150 && pixel.b < 150 { red += 1 }
                }
            }
            context.check("the native canvas paints the bend at displayed \(model.zoomPercent)%", red > 0)
        }
    }
#endif
