#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import MacPlatform
    import RecortiaFixtures

    /// Scenario building blocks that go through the real app paths: the menu command, the capture
    /// coordinator, the editor model's pointer gestures, and the export coordinator.
    @MainActor
    enum E2EActions {
        static func point(_ x: Double, _ y: Double) -> Point<DocumentSpace> { Point(x: x, y: y) }

        static func desktopRect(_ rect: CGRect) -> Rect<DesktopSpace> {
            Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        }

        /// Capture Region from the menu command, committed the way the overlay commits a drag.
        static func captureRegion(_ harness: E2EHarness, _ rect: CGRect, _ context: ScenarioContext) async throws
            -> EditorWindowController
        {
            let coordinator = harness.features.capture
            let before = harness.editors.controllers.count
            harness.app.perform(.captureRegion)
            try context.require(
                "Capture Region starts selecting", coordinator.state == .selecting, "\(coordinator.state)")
            try context.require(
                "committing the region is accepted",
                coordinator.commitRegion(desktopRect(rect), on: harness.capture.display))
            return try await waitForNewEditor(harness, after: before, context)
        }

        static func waitForNewEditor(_ harness: E2EHarness, after count: Int, _ context: ScenarioContext) async throws
            -> EditorWindowController
        {
            let opened = await E2EWait.until { harness.editors.controllers.count > count }
            try context.require("an editor window opened", opened, "editors: \(harness.editors.controllers.count)")
            let controller = try context.unwrap("editor controller", harness.editors.controllers.last)
            try await harness.editors.waitForBase(controller.model)
            return controller
        }

        /// One pointer gesture (down, a few drags, up) with `tool`: one undo step in the model.
        static func drag(
            _ model: EditorModel, _ tool: EditorTool, from start: Point<DocumentSpace>, to end: Point<DocumentSpace>,
            via path: [Point<DocumentSpace>] = []
        ) {
            model.selectTool(tool)
            model.pointerDown(at: start)
            let steps = path.isEmpty ? interpolate(start, end, count: 6) : path
            for p in steps { model.pointerDragged(to: p) }
            model.pointerUp(at: end)
        }

        static func click(_ model: EditorModel, _ tool: EditorTool, at p: Point<DocumentSpace>) {
            model.selectTool(tool)
            model.pointerDown(at: p)
            model.pointerUp(at: p)
        }

        static func interpolate(_ a: Point<DocumentSpace>, _ b: Point<DocumentSpace>, count: Int)
            -> [Point<DocumentSpace>]
        {
            (1...count).map { i in
                let t = Double(i) / Double(count)
                return Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }

        /// Renders the editor window's content after the preview and SwiftUI have settled.
        static func snapshotEditor(
            _ controller: EditorWindowController, _ context: ScenarioContext, shot: String? = nil
        ) async {
            _ = await E2EWait.until(timeout: .seconds(10)) { controller.model.isBaseCurrent }
            if controller.model.showsOutputPreview {
                _ = await E2EWait.until(timeout: .seconds(10)) { controller.model.isOutputPreviewCurrent }
            }
            guard let root = controller.contentRoot else {
                context.check("editor has content to render", false)
                return
            }
            await E2ESnapshot.settle(root, for: .milliseconds(150))
            // The window was resized after the editor fitted its first layout; fit what is shown now.
            let model = controller.model
            let document = model.document
            let padding = document.presentation.padding
            let shown =
                model.showsOutputPreview
                ? document.contentRect.insetBy(dx: -padding, dy: -padding) : document.canvasRect
            model.setViewport(.fitting(shown, in: model.viewportSize, maxZoom: 1 / max(model.backingScale, 0.5)))
            controller.canvasView?.needsDisplay = true
            await E2ESnapshot.settle(root, for: .milliseconds(350))
            context.snapshot(root, shot: shot)
        }

        /// Scrolls the inspector (the rightmost scroll view) so `fraction` of it is above the fold.
        static func scrollInspector(_ controller: EditorWindowController, to fraction: Double) async {
            guard let root = controller.contentRoot else { return }
            let scrollViews = EditorWindowController.all(NSScrollView.self, in: root)
            let inspector = scrollViews.max { a, b in
                a.convert(a.bounds, to: root).minX < b.convert(b.bounds, to: root).minX
            }
            guard let inspector, let document = inspector.documentView else { return }
            await E2ESnapshot.settle(root, for: .milliseconds(150))
            let maxY = max(0, document.frame.height - inspector.contentView.bounds.height)
            let y = document.isFlipped ? maxY * fraction : maxY * (1 - fraction)
            inspector.contentView.scroll(to: NSPoint(x: 0, y: y))
            inspector.reflectScrolledClipView(inspector.contentView)
        }

        /// Exports through the editor's own export command and returns the outcome.
        static func export(_ controller: EditorWindowController, _ request: EditorExportRequest) async -> ExportOutcome
        {
            await controller.model.export(request)
        }

        static func decode(_ data: Data, _ name: String, _ context: ScenarioContext) throws -> DecodedPixels {
            do {
                return try ContainerInspector.decodePixels(data)
            } catch {
                try context.require("\(name) decodes", false, "\(error)")
                throw E2EAbort("unreachable")
            }
        }

        static func pixels(of image: CGImage, _ name: String, _ context: ScenarioContext) throws -> DecodedPixels {
            do {
                return try ContainerInspector.pixels(of: image)
            } catch {
                try context.require("\(name) has readable pixels", false, "\(error)")
                throw E2EAbort("unreachable")
            }
        }

        static func color(_ rgba: RGBA) -> ChartFixture.Color { ChartFixture.Color(rgba.r, rgba.g, rgba.b, rgba.a) }

        /// Largest per-channel difference between two colors.
        static func distance(_ a: ChartFixture.Color, _ b: ChartFixture.Color) -> Int {
            max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)), abs(Int(a.a) - Int(b.a)))
        }
    }
#endif
