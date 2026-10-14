#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging

    @MainActor
    enum TextAppearanceScenarios {
        static func layoutFailure(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let source = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 200, height: 150), context)
            var document = source.model.document
            document.annotations = [
                Annotation(
                    kind: .rectangle(Rect(x: 20, y: 20, width: 100, height: 100)),
                    style: Annotation.Style(stroke: .red, fill: .red)),
                Annotation(
                    kind: .text(
                        .init(
                            origin: Point(x: Double.greatestFiniteMagnitude, y: 20), string: "Synthetic overflow",
                            fontSize: 24, maxWidth: Double.greatestFiniteMagnitude)),
                    style: Annotation.Style(stroke: .black)),
            ]
            let controller = harness.editors.open(DocumentSession(document: document))
            let canvas = try context.unwrap("failure canvas", controller.canvasView)
            try await harness.editors.waitForBase(controller.model)
            await E2ESnapshot.settle(controller.contentRoot)
            let bytes = try E2ESnapshot.png(of: canvas, background: .underPageBackgroundColor)
            let pixels = try E2EActions.decode(bytes, "failed canvas", context)
            let point = controller.model.viewport.viewPoint(E2EActions.point(50, 50))
            let pixel = pixels.pixel(x: Int(point.x * E2ESnapshot.scale), y: Int(point.y * E2ESnapshot.scale))
            context.check(
                "a failed layout clears previously drawn annotation pixels",
                pixel.r != RGBA.red.r || pixel.g != RGBA.red.g || pixel.b != RGBA.red.b)
            context.check("the failed canvas remains opaque", pixel.a == 255)
            context.check(
                "layout failure exposes the existing preview error", controller.model.notice == .previewFailed)
            if let root = controller.contentRoot { context.snapshot(root, shot: "layout-failure") }
        }

        static func fontDesigns(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            controller.window?.orderFront(nil)
            let model = controller.model
            let root = try context.unwrap("editor content", controller.contentRoot)
            let canvas = try context.unwrap("text canvas", controller.canvasView)
            model.setFontSize(40)
            E2EActions.click(model, .text, at: E2EActions.point(80, 60))
            try context.require(
                "text opens a native editor",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
            let editor = try context.unwrap(
                "native text editor", EditorWindowController.first(NSTextView.self, in: canvas))
            editor.insertText(EditorScenarios.accentedText, replacementRange: editor.selectedRange())
            controller.commitPendingText()
            let annotation = try context.unwrap("committed text", model.document.annotations.last)
            model.select(.annotation(annotation.id))
            await E2EActions.scrollInspector(controller, to: 0.35)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "text-style-before-action")
            try E2EAccessibilityControl.press("textAppearance.rounded", in: root, context)
            try context.require(
                "native Rounded control applies the selected text font",
                await E2EWait.until {
                    guard case .text(let text) = model.document.annotations.last?.kind else { return false }
                    return text.resolvedAppearance == .rounded
                }, "style=\(model.style.textAppearance.rawValue); editing=\(model.textEditing != nil)")
            let rounded = try context.unwrap("rounded text", model.document.annotations.last)
            if case .text(let before) = annotation.kind, case .text(let after) = rounded.kind {
                context.check("font selection preserves Unicode text", after.string == before.string)
                context.check(
                    "font selection preserves origin and wrapping",
                    after.origin == before.origin && after.maxWidth == before.maxWidth)
                context.check("font selection preserves text size", after.fontSize == before.fontSize)
            } else {
                try context.require("font selection keeps text annotations", false)
            }
            model.undo()
            context.check("font selection has an independent undo", model.document.annotations.last == annotation)
            model.redo()
            context.check("font selection can be redone", model.document.annotations.last == rounded)
            await E2EActions.snapshotEditor(controller, context, shot: "text-rounded")

            model.beginEditingText(annotation.id)
            try context.require(
                "reopening rounded text creates the native editor",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
            let reopened = try context.unwrap(
                "reopened native editor", EditorWindowController.first(NSTextView.self, in: canvas))
            let expected = try TextLayout.nativeFont(for: .rounded, size: 40 * model.viewport.zoom)
            context.check("reopened native text uses the selected rounded design", reopened.font == expected)
            await E2ESnapshot.settle(root)
            context.check(
                "native text-style control is disabled while text input is active",
                try !E2EAccessibilityControl.isEnabled("textAppearance.monospaced", in: root, context))
            context.check(
                "disabled text-style control explains how to finish input",
                try E2EAccessibilityControl.text(.help, for: "textAppearance.monospaced", in: root, context)
                    == String(localized: "Finish editing text before changing its style.", table: "Editor"))
            model.cancelTextEditing()
            try context.require(
                "cancel removes the native editor",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) == nil })
            context.check("cancel preserves rounded text", model.document.annotations.last == rounded)

            var wrappedDocument = model.document
            let wrappedAnnotation = Annotation(
                kind: .text(
                    .init(
                        origin: E2EActions.point(60, 40), string: EditorScenarios.accentedText,
                        fontSize: 24, maxWidth: 90, appearance: .monospaced)),
                style: Annotation.Style(stroke: .black))
            wrappedDocument.annotations = [wrappedAnnotation]
            let wrappedController = harness.editors.open(DocumentSession(document: wrappedDocument))
            let wrappedCanvas = try context.unwrap("wrapped canvas", wrappedController.canvasView)
            wrappedController.model.beginEditingText(wrappedAnnotation.id)
            try context.require(
                "wrapped text opens a native editor",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: wrappedCanvas) != nil })
            let wrappedEditor = try context.unwrap(
                "wrapped native editor", EditorWindowController.first(NSTextView.self, in: wrappedCanvas))
            let container = try context.unwrap("native wrapping container", wrappedEditor.textContainer)
            context.check(
                "native editing retains the document content-width constraint",
                abs(container.containerSize.width - 90 * wrappedController.model.viewport.zoom) < 0.001)
            for zoom in [0.25, 2.0] {
                wrappedController.model.setZoom(zoom)
                await E2ESnapshot.settle(wrappedController.contentRoot)
                context.check(
                    "native wrapping follows zoom \(zoom)", abs(container.containerSize.width - 90 * zoom) < 0.001)
                context.check(
                    "native monospaced font follows zoom \(zoom)",
                    wrappedEditor.font == (try TextLayout.nativeFont(for: .monospaced, size: 24 * zoom)))
            }
            let replacement = EditorScenarios.accentedText + "\nRevisão final"
            wrappedEditor.insertText(replacement, replacementRange: wrappedEditor.selectedRange())
            wrappedController.commitPendingText()
            if case .text(let committed) = wrappedController.model.document.annotations.last?.kind {
                context.check("native confirm preserves composed multiline text", committed.string == replacement)
                context.check(
                    "native confirm retains monospaced appearance", committed.resolvedAppearance == .monospaced)
                context.check("native confirm retains the content width", committed.maxWidth == 90)
            } else {
                try context.require("native confirm retains wrapped text", false)
            }
            wrappedController.window?.orderFront(nil)
            let wrappedRoot = try context.unwrap("wrapped editor content", wrappedController.contentRoot)
            for appearance in [TextAppearance.standard, .rounded, .monospaced] {
                await E2EActions.scrollInspector(wrappedController, to: 0.35)
                await E2ESnapshot.settle(wrappedRoot)
                let identifier = "textAppearance.\(appearance.rawValue)"
                try E2EAccessibilityControl.press(identifier, in: wrappedRoot, context)
                try context.require(
                    "native \(appearance.rawValue) control changes text appearance",
                    await E2EWait.until { wrappedController.model.style.textAppearance == appearance })
                await E2ESnapshot.settle(wrappedRoot)
                context.check(
                    "native \(appearance.rawValue) control exposes selected state",
                    try E2EAccessibilityControl.text(.value, for: identifier, in: wrappedRoot, context)
                        == String(localized: "Selected", table: "Editor"))
            }
            wrappedController.model.clearSelection()
            E2EActions.click(wrappedController.model, .text, at: E2EActions.point(220, 60))
            try context.require(
                "new text opens the native editor",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: wrappedCanvas) != nil })
            let nextEditor = try context.unwrap(
                "new native editor", EditorWindowController.first(NSTextView.self, in: wrappedCanvas))
            nextEditor.insertText("let answer = 42", replacementRange: nextEditor.selectedRange())
            wrappedController.commitPendingText()
            if case .text(let next) = wrappedController.model.document.annotations.last?.kind {
                context.check(
                    "new text retains the chosen monospaced appearance", next.resolvedAppearance == .monospaced)
            } else {
                try context.require("new monospaced text exists", false)
            }
            if let window = wrappedController.window {
                window.setContentSize(NSSize(width: 980, height: 560))
                window.appearance = NSAppearance(named: .darkAqua)
                wrappedController.model.zoomToFit()
                await E2EActions.scrollInspector(wrappedController, to: 0.35)
                await E2ESnapshot.settle(wrappedRoot)
                context.check("text styles fit minimum editor width", abs(wrappedRoot.bounds.width - 980) < 1)
                context.snapshot(wrappedRoot, shot: "text-styles-compact-dark")
            }
            try await selectAllStyle(harness, document: model.document, context)
        }

        private static func selectAllStyle(
            _ harness: E2EHarness, document: Document, _ context: ScenarioContext
        ) async throws {
            var document = document
            let annotation = Annotation(
                kind: .text(
                    .init(
                        origin: E2EActions.point(60, 40), string: "Selecionar tudo🙂",
                        fontSize: 40, appearance: .rounded)), style: .default)
            document.layers = []
            document.annotations = [annotation]
            let controller = harness.editors.open(DocumentSession(document: document))
            controller.window?.orderFront(nil)
            let canvas = try context.unwrap("Select All canvas", controller.canvasView)
            let root = try context.unwrap("Select All editor", controller.contentRoot)
            let model = controller.model
            model.clearSelection()
            model.setTextAppearance(.standard)
            let before = model.document
            let undoCount = model.session.undoCount
            try context.require(
                "the synthetic canvas accepts keyboard ownership", controller.window?.makeFirstResponder(canvas) == true
            )
            let event = try context.unwrap(
                "Select All key equivalent",
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                    windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                    characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            context.check("the native canvas handles Select All", canvas.performKeyEquivalent(with: event))
            context.check("Select All loads the selected text's actual font", model.style.textAppearance == .rounded)
            context.check(
                "Select All preserves content and undo history",
                model.document == before && model.session.undoCount == undoCount)
            await E2EActions.scrollInspector(controller, to: 0.35)
            await E2ESnapshot.settle(root)
            context.check(
                "Select All exposes the actual selected style in native controls",
                try E2EAccessibilityControl.text(.value, for: "textAppearance.rounded", in: root, context)
                    == String(localized: "Selected", table: "Editor"))
        }
    }
#endif
