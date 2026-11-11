#if DEBUG
    import AppKit
    import Domain
    import Features

    /// The editor's tools and actions live in the window's own toolbar (FR-04, FR-06), visible
    /// at the minimum and the default width, pressable through accessibility, without taking
    /// keyboard ownership from the canvas.
    @MainActor
    enum EditorToolbarScenarios {
        static let toolIdentifiers =
            [
                EditorTool.select, .hand, .crop, .text, .arrow, .line, .rectangle, .ellipse, .freehand, .highlighter,
                .step, .redact,
            ].map { "tool.\($0.rawValue)" }
        static let actionIdentifiers = [
            "toolMenu.effects", "toolMenu.measure", "toolbar.undo", "toolbar.redo", "toolbar.copy", "toolbar.save",
            "toolbar.pin", "toolbar.dragOut",
        ]

        static func toolbar(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            let model = controller.model
            let window = try context.unwrap("editor window", controller.window)
            window.orderFront(nil)
            let content = try context.unwrap("editor content view", window.contentView)
            let frameView = try context.unwrap("editor frame view", content.superview)
            await E2ESnapshot.settle(frameView)

            let toolbar = window.toolbar
            context.check("the editor window has a toolbar", toolbar != nil)
            context.check(
                "the content view no longer draws the tool strip",
                !containsLabel(EditorStrings.name(EditorTool.redact), in: content))
            for identifier in toolIdentifiers + actionIdentifiers {
                context.check(
                    "\(identifier) is in the window's toolbar",
                    E2EAccessibilityControl.isPresent(identifier, in: frameView)
                        && !E2EAccessibilityControl.isPresent(identifier, in: content))
            }

            for (width, shot) in [(980.0, "minimum-light"), (1100.0, "default-light")] {
                window.setContentSize(NSSize(width: width, height: 720))
                await E2ESnapshot.settle(frameView)
                checkAllVisible(toolbar, width: width, context)
                context.snapshot(frameView, shot: shot)
            }

            try E2EAccessibilityControl.press("tool.arrow", in: frameView, context)
            try context.require("toolbar Arrow selects the arrow tool", await E2EWait.until { model.tool == .arrow })
            await E2ESnapshot.settle(frameView)
            context.check(
                "toolbar Arrow reports the selected tool",
                try E2EAccessibilityControl.text(.value, for: "tool.arrow", in: frameView, context)
                    == String(localized: "Selected tool", table: "Editor"))

            let effects = try menu(containing: EditorTool.blur, in: toolbar, context)
            try choose(.blur, from: effects, context)
            try context.require("Effects chooses Blur", await E2EWait.until { model.tool == .blur })
            await E2ESnapshot.settle(frameView)
            context.check(
                "Effects reports the selected tool",
                try E2EAccessibilityControl.text(.value, for: "toolMenu.effects", in: frameView, context)
                    == String(localized: "Selected tool", table: "Editor"))
            context.check(
                "Effects names the active Blur tool",
                try E2EAccessibilityControl.text(.label, for: "toolMenu.effects", in: frameView, context)
                    .contains(EditorStrings.name(EditorTool.blur)))
            context.snapshot(frameView, shot: "effects-active")
            try E2EAccessibilityControl.press("tool.select", in: frameView, context)
            try context.require("toolbar Select selects", await E2EWait.until { model.tool == .select })
            await E2ESnapshot.settle(frameView)
            context.check(
                "a tool outside Effects clears its selected value",
                try E2EAccessibilityControl.text(.value, for: "toolMenu.effects", in: frameView, context).isEmpty)
            context.check(
                "Effects names its group again",
                try E2EAccessibilityControl.text(.label, for: "toolMenu.effects", in: frameView, context)
                    == String(localized: "Effects", table: "Editor"))
            let measure = try menu(containing: EditorTool.ruler, in: toolbar, context)
            try choose(.ruler, from: measure, context)
            try context.require("Measure chooses Ruler", await E2EWait.until { model.tool == .ruler })

            context.check(
                "Undo is disabled with nothing to undo",
                try !E2EAccessibilityControl.isEnabled("toolbar.undo", in: frameView, context))
            E2EActions.drag(model, .rectangle, from: E2EActions.point(40, 40), to: E2EActions.point(240, 160))
            await E2ESnapshot.settle(frameView)
            context.check(
                "Undo follows canUndo",
                try E2EAccessibilityControl.isEnabled("toolbar.undo", in: frameView, context) == model.canUndo
                    && model.canUndo)
            context.check(
                "Redo follows canRedo",
                try E2EAccessibilityControl.isEnabled("toolbar.redo", in: frameView, context) == model.canRedo
                    && !model.canRedo)
            try E2EAccessibilityControl.press("toolbar.undo", in: frameView, context)
            try context.require("toolbar Undo undoes", await E2EWait.until { model.canRedo })
            await E2ESnapshot.settle(frameView)
            context.check(
                "Redo becomes enabled after Undo",
                try E2EAccessibilityControl.isEnabled("toolbar.redo", in: frameView, context))
            try E2EAccessibilityControl.press("toolbar.redo", in: frameView, context)
            try context.require("toolbar Redo redoes", await E2EWait.until { model.canUndo && !model.canRedo })

            let clipboardChanges = harness.clipboard.pasteboard.changeCount
            let snapshots = harness.exportGate.snapshotCount
            try E2EAccessibilityControl.press("toolbar.copy", in: frameView, context)
            try context.require(
                "toolbar Copy writes the image clipboard through the export path",
                await E2EWait.until {
                    harness.clipboard.pasteboard.changeCount != clipboardChanges
                        && harness.exportGate.snapshotCount > snapshots
                })

            let canvas = try context.unwrap("editor canvas", controller.canvasView)
            try context.require("the canvas owns the keyboard", window.makeFirstResponder(canvas))
            try E2EAccessibilityControl.press("tool.rectangle", in: frameView, context)
            try context.require("toolbar Rectangle selects", await E2EWait.until { model.tool == .rectangle })
            context.check("a toolbar tool leaves the canvas first responder", window.firstResponder === canvas)

            window.setContentSize(NSSize(width: 980, height: 560))
            window.appearance = NSAppearance(named: .darkAqua)
            await E2ESnapshot.settle(frameView)
            checkAllVisible(toolbar, width: 980, context)
            context.snapshot(frameView, shot: "compact-dark")
        }

        /// Every item the toolbar holds is in its visible set, so nothing sits in the overflow menu.
        private static func checkAllVisible(_ toolbar: NSToolbar?, width: Double, _ context: ScenarioContext) {
            let spacers: Set<NSToolbarItem.Identifier> = [.space, .flexibleSpace]
            let items = (toolbar?.items ?? []).filter { !spacers.contains($0.itemIdentifier) }
            let visible = Set((toolbar?.visibleItems ?? []).map(\.itemIdentifier))
            let hidden = items.filter { !visible.contains($0.itemIdentifier) }
            context.check(
                "at \(Int(width)) pt every toolbar item is visible", !items.isEmpty && hidden.isEmpty,
                "items \(items.count), visible \(visible.count), overflow \(hidden.map(\.itemIdentifier.rawValue))")
        }

        /// The toolbar menu whose items include `tool`.
        private static func menu(containing tool: EditorTool, in toolbar: NSToolbar?, _ context: ScenarioContext)
            throws -> NSMenu
        {
            let menus = (toolbar?.items ?? []).compactMap { ($0 as? NSMenuToolbarItem)?.menu }
            for menu in menus {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
            }
            return try context.unwrap(
                "a toolbar menu lists \(tool.rawValue)",
                menus.first { index(of: tool, in: $0) != nil },
                "menus \(menus.map { $0.items.map(\.title) })")
        }

        /// Sends the menu item's own action, as choosing it does, without a tracking loop.
        private static func choose(_ tool: EditorTool, from menu: NSMenu, _ context: ScenarioContext) throws {
            let found = try context.unwrap("menu item for \(tool.rawValue)", index(of: tool, in: menu))
            found.menu.performActionForItem(at: found.index)
        }

        private static func index(of tool: EditorTool, in menu: NSMenu) -> (menu: NSMenu, index: Int)? {
            let title = EditorStrings.name(tool)
            for (position, item) in menu.items.enumerated() {
                if item.title == title { return (menu, position) }
                if let submenu = item.submenu, let found = index(of: tool, in: submenu) { return found }
            }
            return nil
        }

        /// Whether any view or accessibility element under `root` carries `label`.
        private static func containsLabel(_ label: String, in root: NSView) -> Bool {
            var visited: Set<ObjectIdentifier> = []
            var remaining = 4096
            func walk(_ element: Any, depth: Int) -> Bool {
                guard depth < 64, remaining > 0, let object = element as? NSObject,
                    visited.insert(ObjectIdentifier(object)).inserted
                else { return false }
                remaining -= 1
                if object.responds(to: NSSelectorFromString("accessibilityLabel")),
                    object.value(forKey: "accessibilityLabel") as? String == label
                {
                    return true
                }
                if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                    let children = object.value(forKey: "accessibilityChildren") as? [Any],
                    children.contains(where: { walk($0, depth: depth + 1) })
                {
                    return true
                }
                if let view = element as? NSView {
                    return view.subviews.contains { walk($0, depth: depth + 1) }
                }
                return false
            }
            return walk(root, depth: 0)
        }
    }
#endif
