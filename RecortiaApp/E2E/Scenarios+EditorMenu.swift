#if DEBUG
    import AppKit
    import Domain
    import Features

    /// Every editor command is in the menu bar (A-3): File, Edit, View and Tools act on the key
    /// editor as its toolbar, inspector or canvas does, are disabled while another window is key,
    /// and keep their state current for key equivalents before any menu opens. Unmodified tool
    /// letters never take a letter typed into text, marked text included.
    @MainActor
    enum EditorMenuScenarios {
        static func commands(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let controller = try await E2EActions.captureRegion(
                harness, CGRect(x: 180, y: 120, width: 700, height: 460), context)
            defer { harness.editors.closeAll() }
            let model = controller.model
            let window = try context.unwrap("editor window", controller.window)
            let canvas = try context.unwrap("editor canvas", controller.canvasView)
            try await E2EAccessibilityControl.showAndActivate(window, context)
            window.makeFirstResponder(canvas)
            await E2ESnapshot.settle(canvas, for: .milliseconds(300))

            let close = String(localized: "Close", table: "Editor")
            let save = String(localized: "Save…", table: "Editor")
            let savePreferred = String(localized: "Save to Preferred Folder", table: "Editor")
            let print = String(localized: "Print…", table: "Editor")
            let zoomIn = String(localized: "Zoom In", table: "Editor")
            let zoomOut = String(localized: "Zoom Out", table: "Editor")
            let actualPixels = String(localized: "Actual Pixels", table: "Editor")
            let zoomToFit = String(localized: "Zoom to Fit", table: "Editor")
            let zoomToSelection = String(localized: "Zoom to Selection", table: "Editor")
            let preview = String(localized: "Show Output Preview", table: "Editor")
            let inspector = String(localized: "Inspector", table: "Editor")
            let tools = EditorTool.menuSections.flatMap { $0 }
            let toolTitles = tools.map { EditorStrings.name($0) }
            let shortcuts: [(String, String, NSEvent.ModifierFlags)] = [
                (AppCommand.openImage.title, "o", .command), (AppCommand.pasteImage.title, "", []),
                (close, "w", .command), (save, "s", .command), (savePreferred, "", []), (print, "p", .command),
                (zoomIn, "+", .command),
                (zoomOut, "-", .command), (actualPixels, "1", .command), (zoomToFit, "0", .command),
                (zoomToSelection, "", []), (preview, "", []), (inspector, "", []),
                (EditorInspectorTab.format.title, "", []), (EditorInspectorTab.image.title, "", []),
            ]
            // Every command that needs a key editor; Zoom to Selection also needs a selection.
            let editorTitles =
                [
                    close, save, savePreferred, print, zoomIn, zoomOut, actualPixels, zoomToFit, preview, inspector,
                    EditorInspectorTab.format.title, EditorInspectorTab.image.title,
                ] + toolTitles
            let editActions = ["undo:", "redo:", "copy:", "delete:", "selectAll:"]

            func allTitles() -> String {
                EditorToolbarScenarios.menuItems(NSApp.mainMenu).map(\.title).joined(separator: ", ")
            }
            /// The item as it is now, without updating any menu: what a key equivalent sees.
            func current(_ title: String) -> NSMenuItem? {
                EditorToolbarScenarios.menuItems(NSApp.mainMenu).first { $0.title == title }
            }
            func command(_ title: String) throws -> NSMenuItem {
                try context.unwrap(
                    "the menu bar has \(title)", EditorToolbarScenarios.viewCommand(title), allTitles())
            }
            /// A standard Edit item, found by its action because AppKit localizes its title.
            func edit(_ action: String) throws -> NSMenuItem {
                for menu in Set(EditorToolbarScenarios.menuItems(NSApp.mainMenu).compactMap(\.menu)) {
                    EditorToolbarScenarios.prepare(menu)
                }
                return try context.unwrap(
                    "Edit has \(action)",
                    EditorToolbarScenarios.menuItems(NSApp.mainMenu).first {
                        $0.action == NSSelectorFromString(action)
                    })
            }
            func choose(_ item: NSMenuItem) throws {
                let menu = try context.unwrap("\(item.title) has a menu", item.menu)
                menu.performActionForItem(at: menu.index(of: item))
            }
            func post(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = try context.unwrap(
                        "\(characters) key event",
                        NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, characters: characters, charactersIgnoringModifiers: characters,
                            isARepeat: false, keyCode: keyCode))
                    NSApp.postEvent(event, atStart: false)
                }
            }

            // Each command exists with its shortcut; each tool shows its own letter, unmodified,
            // in the toolbar's order with one section per toolbar group.
            for (title, key, modifiers) in shortcuts {
                let item = try command(title)
                context.check(
                    "\(title) shows \(key.isEmpty ? "no shortcut" : key)",
                    item.keyEquivalent == key
                        && (key.isEmpty
                            || item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                                == modifiers),
                    "\(item.keyEquivalent.debugDescription) \(item.keyEquivalentModifierMask.rawValue)")
            }
            let toolsMenu = try context.unwrap(
                "the main menu has Tools",
                NSApp.mainMenu?.items.first { $0.title == String(localized: "Tools", table: "Editor") }?.submenu)
            EditorToolbarScenarios.prepare(toolsMenu)
            context.check(
                "Tools lists every tool once, in the toolbar's order",
                toolsMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == toolTitles
                    && Set(tools) == Set(EditorTool.allCases) && tools.count == EditorTool.allCases.count,
                "\(toolsMenu.items.map(\.title))")
            context.check(
                "Tools has one section per toolbar group",
                toolsMenu.items.filter(\.isSeparatorItem).count == EditorTool.menuSections.count - 1)
            for tool in tools {
                let item = try command(EditorStrings.name(tool))
                context.check(
                    "Tools › \(item.title) shows the unmodified letter \(tool.shortcutKey)",
                    item.keyEquivalent == String(tool.shortcutKey)
                        && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).isEmpty,
                    "\(item.keyEquivalent.debugDescription) \(item.keyEquivalentModifierMask.rawValue)")
            }

            // With another window key every editor command is disabled, and the menu items say so
            // before any menu opens, which is what a key equivalent sees.
            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered,
                defer: false)
            other.isReleasedWhenClosed = false
            other.collectionBehavior = SpacePolicy.followsActiveSpace
            other.makeKeyAndOrderFront(nil)
            await E2ESnapshot.settle(canvas, for: .milliseconds(400))
            context.check(
                "File › Close is disabled while another window is key, before any menu opens",
                current(close)?.isEnabled == false, "key window is other: \(other.isKeyWindow)")
            for title in editorTitles + [zoomToSelection] {
                context.check("\(title) is disabled while another window is key", try command(title).isEnabled == false)
            }
            for action in editActions {
                context.check(
                    "Edit › \(action) is disabled while another window is key", try edit(action).isEnabled == false)
            }
            for title in [AppCommand.openImage.title, AppCommand.pasteImage.title] {
                context.check("\(title) needs no editor", try command(title).isEnabled)
            }
            other.close()
            try await E2EAccessibilityControl.showAndActivate(window, context)
            window.makeFirstResponder(canvas)
            await E2ESnapshot.settle(canvas, for: .milliseconds(400))
            context.check(
                "File › Close is enabled again for the key editor before any menu opens",
                current(close)?.isEnabled == true)
            // ⌃⌘I reaches View › Hide Inspector without a menu having opened since the editor
            // became key again: the item was refreshed, not left disabled.
            let inspectorItem = try context.unwrap("the inspector split item", controller.splitItem(.inspector))
            try post("i", keyCode: 34, [.control, .command])
            try context.require(
                "⌃⌘I hides the inspector before any menu opens",
                await E2EWait.until(timeout: .seconds(3)) { inspectorItem.isCollapsed })
            try post("i", keyCode: 34, [.control, .command])
            try context.require(
                "⌃⌘I shows it again", await E2EWait.until(timeout: .seconds(3)) { !inspectorItem.isCollapsed })
            window.makeFirstResponder(canvas)
            for title in editorTitles {
                context.check("\(title) is enabled for the key editor", try command(title).isEnabled)
            }
            context.check(
                "Zoom to Selection is disabled without a selection", try command(zoomToSelection).isEnabled == false)

            // Tools: each item chooses its tool, and the active tool is the checked one.
            for tool in tools {
                try choose(try command(EditorStrings.name(tool)))
                context.check(
                    "Tools › \(EditorStrings.name(tool)) chooses that tool", model.tool == tool, "\(model.tool)")
            }
            try choose(try command(EditorStrings.name(EditorTool.ellipse)))
            context.check(
                "the active tool is checked and no other",
                try command(EditorStrings.name(EditorTool.ellipse)).state == .on
                    && command(EditorStrings.name(EditorTool.rectangle)).state == .off)
            try choose(try command(EditorStrings.name(EditorTool.select)))

            // Edit: the standard items act on the document through the canvas, as ⌘Z and the toolbar do.
            E2EActions.drag(model, .rectangle, from: E2EActions.point(40, 40), to: E2EActions.point(200, 140))
            E2EActions.drag(model, .ellipse, from: E2EActions.point(260, 60), to: E2EActions.point(380, 180))
            model.selectTool(.select)
            window.makeFirstResponder(canvas)
            let drawn = model.document.annotations.count
            try context.require("two shapes are drawn", drawn >= 2, "\(drawn)")
            context.check("Edit › Undo is enabled after an edit", try edit("undo:").isEnabled)
            try choose(try edit("undo:"))
            context.check("Edit › Undo undoes one step", model.document.annotations.count == drawn - 1)
            context.check("Edit › Redo is enabled after an undo", try edit("redo:").isEnabled)
            try choose(try edit("redo:"))
            context.check("Edit › Redo redoes it", model.document.annotations.count == drawn)
            try choose(try edit("selectAll:"))
            let selectedByMenu = model.selection
            model.clearSelection()
            model.selectAll()
            context.check(
                "Edit › Select All selects what ⌘A selects",
                !selectedByMenu.isEmpty && selectedByMenu == model.selection)
            let shape = try context.unwrap("a drawn shape", model.document.annotations.last)
            model.select(.annotation(shape.id))
            context.check("Edit › Delete is enabled with a selection", try edit("delete:").isEnabled)
            try choose(try edit("delete:"))
            context.check(
                "Edit › Delete removes the selection",
                model.document.annotations.count == drawn - 1
                    && !model.document.annotations.contains { $0.id == shape.id })
            model.undo()
            // ⌘Z is the canvas's own key and Undo's equivalent: one press undoes exactly one step.
            try post("z", keyCode: 6, .command)
            try context.require(
                "⌘Z undoes a step",
                await E2EWait.until(timeout: .seconds(3)) { model.document.annotations.count < drawn })
            await E2ESnapshot.settle(canvas, for: .milliseconds(300))
            context.check(
                "⌘Z acts once, not through both the canvas and the menu",
                model.document.annotations.count == drawn - 1, "\(model.document.annotations.count) of \(drawn)")
            model.redo()
            harness.clipboard.pasteboard.clearContents()
            context.check("Edit › Copy is enabled for the image", try edit("copy:").isEnabled)
            try choose(try edit("copy:"))
            context.check(
                "Edit › Copy copies the image as PNG, like the toolbar",
                await E2EWait.until { harness.clipboard.pasteboard.data(forType: .png) != nil })

            // View: the zoom commands match the canvas shortcuts; Zoom to Selection the status menu.
            model.select(.annotation(shape.id))
            let zooms: [(String, () -> Void)] = [
                (zoomIn, { model.zoomIn() }), (zoomOut, { model.zoomOut() }),
                (actualPixels, { model.zoomToActualPixels() }), (zoomToFit, { model.zoomToFit() }),
                (zoomToSelection, { model.zoomToSelection() }),
            ]
            for (title, direct) in zooms {
                let base = EditorViewport(zoom: 0.37, offset: .zero)
                model.setViewport(base)
                try choose(try command(title))
                let viaMenu = model.viewport
                model.setViewport(base)
                direct()
                context.check(
                    "View › \(title) zooms as its shortcut does", viaMenu == model.viewport && viaMenu != base,
                    "menu \(viaMenu), direct \(model.viewport)")
            }
            model.zoomToFit()
            try choose(try command(preview))
            let previewChecked = try command(preview).state == .on
            context.check(
                "View › Show Output Preview shows the output, checked", model.showsOutputPreview && previewChecked)
            try choose(try command(preview))
            context.check("choosing it again returns to editing", !model.showsOutputPreview)

            // View › Inspector picks a tab as the tab control does, and shows a hidden inspector.
            model.select(.annotation(shape.id))
            await E2ESnapshot.settle(canvas, for: .milliseconds(300))
            context.check(
                "the selection shows Format, checked",
                try command(EditorInspectorTab.format.title).state == .on
                    && command(EditorInspectorTab.image.title).state == .off)
            try choose(try command(EditorInspectorTab.image.title))
            context.check("View › Inspector › Image shows the Image tab", controller.panes.chosenInspectorTab == .image)
            controller.toggle(.inspector)
            await E2ESnapshot.settle(canvas, for: .milliseconds(400))
            try context.require("the inspector is hidden", inspectorItem.isCollapsed)
            try choose(try command(EditorInspectorTab.format.title))
            await E2ESnapshot.settle(canvas, for: .milliseconds(400))
            context.check(
                "View › Inspector › Format shows the tab and the hidden inspector",
                controller.panes.chosenInspectorTab == .format && !inspectorItem.isCollapsed)
            window.makeFirstResponder(canvas)

            // File: Save to Preferred Folder exports as the toolbar's Save menu does. Open Image… and
            // Save… open a panel, which the runner never does; their shortcuts and state are above.
            let folder = harness.output.workDirectory.appending(path: "menu-saves", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            harness.settings.update { $0.preferredSaveFolderBookmark = try? folder.bookmarkData() }
            defer { harness.settings.update { $0.preferredSaveFolderBookmark = nil } }
            func saved() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count }
            let savedBefore = saved()
            try context.require("an export can start", await E2EWait.until { model.canStartExport })
            try choose(try command(savePreferred))
            context.check(
                "File › Save to Preferred Folder writes a file there", await E2EWait.until { saved() > savedBefore })

            // File › Paste Image opens the (synthetic) pasteboard image in a new editor, and
            // File › Close closes the key editor.
            harness.importInput.pastedImage = try E2EDrawing.png(harness.desktop)
            defer { harness.importInput.pastedImage = nil }
            let editors = harness.editors.controllers.count
            try choose(try command(AppCommand.pasteImage.title))
            let pasted = try await E2EActions.waitForNewEditor(harness, after: editors, context)
            let pastedWindow = try context.unwrap("the pasted image has a window", pasted.window)
            try await E2EAccessibilityControl.showAndActivate(pastedWindow, context)
            await E2ESnapshot.settle(pastedWindow.contentView, for: .milliseconds(400))
            try choose(try command(close))
            context.check(
                "File › Close closes the key editor",
                await E2EWait.until(timeout: .seconds(3)) { pasted.model.isClosed && !pastedWindow.isVisible })

            // Typing: a tool's letter typed into a text annotation is text, marked text included;
            // on the canvas it chooses the tool; with no view taking keys, the Tools item does.
            try await E2EAccessibilityControl.showAndActivate(window, context)
            E2EActions.click(model, .text, at: E2EActions.point(120, 260))
            try context.require(
                "text input appears",
                await E2EWait.until { EditorWindowController.first(NSTextView.self, in: canvas) != nil })
            let input = try context.unwrap(
                "native text input", EditorWindowController.first(NSTextView.self, in: canvas))
            window.makeFirstResponder(input)
            try context.require("the text input has the keyboard", window.firstResponder === input)
            try post("r", keyCode: 15)
            try post("t", keyCode: 17)
            try post("x", keyCode: 7)
            await E2ESnapshot.settle(canvas, for: .milliseconds(400))
            // An input method may compose the letters instead of inserting them; either way the text has them.
            context.check(
                "tool letters typed into a text annotation are text",
                (input.string == "rtx" || input.hasMarkedText()) && model.tool == .text && model.textEditing != nil,
                "text \(input.string.debugDescription), tool \(model.tool)")
            input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
            input.setMarkedText(
                "か", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            try context.require("marked text begins", input.hasMarkedText())
            let composing = input.string
            try post("o", keyCode: 31)
            await E2ESnapshot.settle(canvas, for: .milliseconds(400))
            context.check(
                "a tool letter during marked text reaches the text, not Tools",
                input.string != composing && model.tool == .text && model.textEditing != nil,
                "text \(input.string.debugDescription), tool \(model.tool)")
            controller.commitPendingText()
            window.makeFirstResponder(canvas)
            try post("r", keyCode: 15)
            context.check(
                "R on the canvas chooses Rectangle",
                await E2EWait.until(timeout: .seconds(3)) { model.tool == .rectangle })
            model.selectTool(.select)
            window.makeFirstResponder(nil)
            try post("o", keyCode: 31)
            context.check(
                "with no view taking keys, O reaches Tools › Ellipse",
                await E2EWait.until(timeout: .seconds(3)) { model.tool == .ellipse },
                "first responder \(String(describing: window.firstResponder.map { type(of: $0) }))")
            window.makeFirstResponder(canvas)
            model.selectTool(.select)
        }
    }
#endif
