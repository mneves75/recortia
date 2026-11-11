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

            try E2EAccessibilityControl.pressCheckingEffect("tool.arrow", in: frameView, context)
            try context.require("toolbar Arrow selects the arrow tool", await E2EWait.until { model.tool == .arrow })
            await E2ESnapshot.settle(frameView)
            context.check(
                "toolbar Arrow reports the selected tool",
                try E2EAccessibilityControl.text(.value, for: "tool.arrow", in: frameView, context)
                    == String(localized: "Selected tool", table: "Editor"))

            let effectsItems = try await choose(.blur, from: "toolMenu.effects", in: frameView, context)
            context.check(
                "Effects lists blur, pixelate, spotlight and magnifier",
                effectsItems.map(\.title)
                    == [EditorTool.blur, .pixelate, .spotlight, .magnifier].map { EditorStrings.name($0) },
                "\(effectsItems.map(\.title))")
            try context.require("Effects chooses Blur", await E2EWait.until { model.tool == .blur })
            await E2ESnapshot.settle(frameView)
            context.check(
                "Effects reports the selected tool",
                try E2EAccessibilityControl.text(.value, for: "toolMenu.effects", in: frameView, context)
                    == String(localized: "Selected tool", table: "Editor"))
            context.check(
                "Effects names the active Blur tool",
                try E2EAccessibilityControl.name(for: "toolMenu.effects", in: frameView, context)
                    .contains(EditorStrings.name(EditorTool.blur)))
            context.snapshot(frameView, shot: "effects-active")
            try E2EAccessibilityControl.pressCheckingEffect("tool.select", in: frameView, context)
            try context.require("toolbar Select selects", await E2EWait.until { model.tool == .select })
            await E2ESnapshot.settle(frameView)
            context.check(
                "a tool outside Effects clears its selected value",
                try E2EAccessibilityControl.text(.value, for: "toolMenu.effects", in: frameView, context).isEmpty)
            context.check(
                "Effects names its group again",
                try E2EAccessibilityControl.name(for: "toolMenu.effects", in: frameView, context)
                    == String(localized: "Effects", table: "Editor"))
            let measureItems = try await choose(.ruler, from: "toolMenu.measure", in: frameView, context)
            context.check(
                "Measure lists loupe, ruler and color picker, none checked",
                measureItems.map(\.title) == [EditorTool.loupe, .ruler, .colorPicker].map { EditorStrings.name($0) }
                    && measureItems.allSatisfy { !$0.checked }, "\(measureItems)")
            try context.require("Measure chooses Ruler", await E2EWait.until { model.tool == .ruler })
            await E2ESnapshot.settle(frameView)
            let reopened = try await choose(nil, from: "toolMenu.measure", in: frameView, context)
            context.check(
                "Measure checks the active Ruler",
                reopened.filter(\.checked).map(\.title) == [EditorStrings.name(.ruler)],
                "\(reopened)")

            // Each grouped tool keeps its own help, with its single-key shortcut, in the menu and on
            // the menu button while it is active; otherwise the button shows the group's help.
            let groups: [(String, [EditorTool], String)] = [
                (
                    "toolMenu.effects", [.blur, .pixelate, .spotlight, .magnifier],
                    String(localized: "Effects: blur, pixelate, spotlight and magnifier", table: "Editor")
                ),
                (
                    "toolMenu.measure", [.loupe, .ruler, .colorPicker],
                    String(localized: "Measure: loupe, ruler and color picker", table: "Editor")
                ),
            ]
            for (identifier, tools, groupHelp) in groups {
                model.selectTool(.select)
                await E2ESnapshot.settle(frameView)
                context.check(
                    "\(identifier) shows its group help with a tool outside it active",
                    (try? E2EAccessibilityControl.help(for: identifier, in: frameView, context)) == groupHelp,
                    "\(String(describing: try? E2EAccessibilityControl.help(for: identifier, in: frameView, context)))")
                let entries = try await choose(nil, from: identifier, in: frameView, context)
                context.check(
                    "\(identifier) entries carry each tool's help",
                    entries.map(\.toolTip) == tools.map { EditorStrings.help($0) }, "\(entries.map(\.toolTip))")
                for tool in tools {
                    model.selectTool(tool)
                    await E2ESnapshot.settle(frameView)
                    let shown = try? E2EAccessibilityControl.help(for: identifier, in: frameView, context)
                    context.check(
                        "\(identifier) shows \(tool.rawValue)'s help while it is active",
                        shown == EditorStrings.help(tool), "\(String(describing: shown))")
                }
            }

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
            try E2EAccessibilityControl.pressCheckingEffect("toolbar.undo", in: frameView, context)
            try context.require("toolbar Undo undoes", await E2EWait.until { model.canRedo })
            await E2ESnapshot.settle(frameView)
            context.check(
                "Redo becomes enabled after Undo",
                try E2EAccessibilityControl.isEnabled("toolbar.redo", in: frameView, context))
            try E2EAccessibilityControl.pressCheckingEffect("toolbar.redo", in: frameView, context)
            try context.require("toolbar Redo redoes", await E2EWait.until { model.canUndo && !model.canRedo })

            let clipboardChanges = harness.clipboard.pasteboard.changeCount
            let snapshots = harness.exportGate.snapshotCount
            try E2EAccessibilityControl.pressCheckingEffect("toolbar.copy", in: frameView, context)
            try context.require(
                "toolbar Copy writes the image clipboard through the export path",
                await E2EWait.until {
                    harness.clipboard.pasteboard.changeCount != clipboardChanges
                        && harness.exportGate.snapshotCount > snapshots
                })

            // Keyboard ownership qualifies only in a visible, key, active, frontmost window: the owned
            // host takes the foreground and yields it, and missing readiness fails the scenario.
            let canvas = try context.unwrap("editor canvas", controller.canvasView)
            let foreground = try await E2EForegroundFixture.start(context)
            defer { foreground.requestStop() }
            window.center(on: ScreenChoice.screen())
            if !E2EForegroundFixture.runnerIsForeground {
                try await foreground.restore()
                try await foreground.yieldToRunner()
            }
            try await E2EAccessibilityControl.showAndActivate(window, context)
            await E2ESnapshot.settle(frameView, for: .milliseconds(300))
            try context.require("the canvas owns the keyboard", window.makeFirstResponder(canvas))
            try E2EAccessibilityControl.pressCheckingEffect("tool.rectangle", in: frameView, context)
            try context.require("toolbar Rectangle selects", await E2EWait.until { model.tool == .rectangle })
            context.check("a toolbar tool leaves the canvas first responder", window.firstResponder === canvas)
            try E2EAccessibilityControl.click("tool.line", in: frameView, context)
            await E2ESnapshot.settle(frameView)
            try context.require("clicking toolbar Line selects it", await E2EWait.until { model.tool == .line })
            context.check("a clicked toolbar tool leaves the canvas first responder", window.firstResponder === canvas)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try context.unwrap(
                    "Ellipse shortcut event",
                    NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "o",
                        charactersIgnoringModifiers: "o",
                        isARepeat: false, keyCode: 31))
                NSApp.postEvent(event, atStart: false)
            }
            await E2ESnapshot.settle(frameView)
            context.check(
                "after a toolbar click the canvas still receives keys (O selects Ellipse)",
                await E2EWait.until { model.tool == .ellipse } && window.firstResponder === canvas,
                "tool \(model.tool.rawValue), responder \(String(describing: window.firstResponder.map { type(of: $0) }))"
            )
            E2ESnapshot.park(window)

            // The remembered editor size is the content size, without the toolbar above it.
            let remembered = harness.settings.preferences.editorContentSize
            defer { harness.settings.update { $0.editorContentSize = remembered } }
            let chosen = NSSize(width: 1040, height: 640)
            window.setContentSize(chosen)
            await E2ESnapshot.settle(frameView)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            let stored = harness.settings.preferences.editorContentSize
            context.check(
                "the remembered size is the content size, not content plus toolbar",
                stored == Size(width: chosen.width, height: chosen.height)
                    && content.frame.size == chosen && window.frame.height - content.frame.height > 40,
                "stored \(String(describing: stored)), content \(content.frame.size), frame \(window.frame.size)")

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

        private static func choose(
            _ tool: EditorTool?, from identifier: String, in root: NSView, _ context: ScenarioContext
        ) async throws -> [E2EMenuEntry] {
            try await E2EAccessibilityControl.chooseFromMenu(
                tool.map(EditorStrings.name), opening: identifier, in: root, context)
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
