#if DEBUG
    import AppKit
    import Domain
    import Features
    import KeyboardShortcuts
    import SwiftUI

    /// Default shortcuts that mirror the macOS Screenshot app (FR-01, ADR-005): seeding, holding
    /// while macOS claims the keys, the capture menu (⇧⌘5), and Space for a window (⇧⌘4).
    @MainActor
    enum ShortcutScenarios {
        static let region = KeyboardShortcuts.Shortcut(.four, modifiers: [.command, .shift])
        static let display = KeyboardShortcuts.Shortcut(.three, modifiers: [.command, .shift])
        static let menu = KeyboardShortcuts.Shortcut(.five, modifiers: [.command, .shift])

        static func defaults(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            let status = app.shortcutStatus
            let expected: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut?)] = [
                (.captureRegion, region), (.captureDisplay, display), (.captureMenu, menu), (.captureWindow, nil),
                (.captureText, nil),
            ]
            for (name, shortcut) in expected {
                context.check(
                    "launch gives \(name.rawValue) \(shortcut.map { "\($0)" } ?? "no shortcut")",
                    KeyboardShortcuts.getShortcut(for: name) == shortcut,
                    "\(String(describing: KeyboardShortcuts.getShortcut(for: name)))")
            }
            context.check(
                "the offered defaults are recorded",
                Set(UserDefaults.standard.stringArray(forKey: ShortcutDefaults.offeredKey) ?? [])
                    == ["captureRegion", "captureDisplay", "captureMenu"])
            // A fresh Mac: macOS still owns ⇧⌘3/4/5, so Recortia holds them and says so.
            for name in ["captureRegion", "captureDisplay", "captureMenu"] {
                context.check(
                    "\(name) is held while macOS uses its keys", status.state(of: name) == .heldBySystem,
                    "\(status.state(of: name))")
            }
            context.check("unassigned commands stay unassigned", status.state(of: "captureWindow") == .unassigned)
            context.check(
                "a press macOS also claims does nothing", !status.admitPress(named: "captureRegion"))
            let tab = ShortcutsSettingsTab(status: status, onRestoreDefaults: app.restoreDefaultShortcuts)
            let window = E2ESnapshot.host(tab.frame(width: 560, height: 760))
            defer { window.close() }
            let root = try context.unwrap("shortcuts tab hosted", window.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "held-by-macos")

            // The user turns the macOS shortcuts off; the watch that holding started picks it up.
            harness.systemShortcuts.enabled = []
            let freed = await E2EWait.until(timeout: .seconds(6)) {
                ["captureRegion", "captureDisplay", "captureMenu"].allSatisfy { status.state(of: $0) == .active }
            }
            context.check(
                "the defaults start working once macOS lets the keys go", freed,
                "\(status.state(of: "captureRegion")) / \(status.state(of: "captureDisplay"))")
            context.check("nothing is held any more", !status.isHoldingAny)
            context.check("a press now runs the command", status.admitPress(named: "captureRegion"))
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "active")

            // Binding-backed recorders must repaint even when both old and new keys stay active.
            let alternate = KeyboardShortcuts.Shortcut(.r, modifiers: [.command, .option])
            status.reassign { KeyboardShortcuts.setShortcut(alternate, for: .captureRegion) }
            await E2ESnapshot.settle(root)
            context.check(
                "the hosted recorder displays an alternate active shortcut",
                EditorWindowController.all(KeyboardShortcuts.RecorderCocoa.self, in: root)
                    .contains { $0.shortcut == alternate })
            app.restoreDefaultShortcuts()
            await E2ESnapshot.settle(root)
            let displayed = EditorWindowController.all(KeyboardShortcuts.RecorderCocoa.self, in: root)
                .compactMap(\.shortcut)
            context.check(
                "Restore Defaults refreshes the hosted recorder while its status remains active",
                status.state(of: "captureRegion") == .active && displayed.contains(region)
                    && !displayed.contains(alternate))

            // A shortcut the user clears stays cleared; Restore Defaults brings the table back.
            KeyboardShortcuts.setShortcut(nil, for: .captureRegion)
            ShortcutDefaults.seedIfNeeded(isNewInstall: true)
            context.check(
                "a cleared default is not seeded again", KeyboardShortcuts.getShortcut(for: .captureRegion) == nil)
            KeyboardShortcuts.setShortcut(.init(.t, modifiers: [.command, .option]), for: .captureText)
            app.restoreDefaultShortcuts()
            context.check(
                "Restore Defaults puts ⇧⌘4 back on Capture Region",
                KeyboardShortcuts.getShortcut(for: .captureRegion) == region)
            context.check(
                "Restore Defaults clears commands without a default",
                KeyboardShortcuts.getShortcut(for: .captureText) == nil)

            // The user turns a macOS shortcut back on: the next press is left to macOS.
            harness.systemShortcuts.enabled = [region]
            context.check(
                "a press after macOS reclaimed ⇧⌘4 does nothing", !status.admitPress(named: "captureRegion"))
            context.check("and the shortcut is held again", status.state(of: "captureRegion") == .heldBySystem)

            // An upgrade: defaults are only marked offered, never assigned; Restore Defaults applies them.
            for binding in ShortcutBinding.all { KeyboardShortcuts.setShortcut(nil, for: binding.name) }
            UserDefaults.standard.removeObject(forKey: ShortcutDefaults.offeredKey)
            ShortcutDefaults.seedIfNeeded(isNewInstall: false)
            context.check(
                "an upgrade gets no shortcut it was not offered",
                ShortcutBinding.all.allSatisfy { KeyboardShortcuts.getShortcut(for: $0.name) == nil })
            context.check(
                "an upgrade records the defaults as offered",
                (UserDefaults.standard.stringArray(forKey: ShortcutDefaults.offeredKey) ?? []).count == 3)
            app.restoreDefaultShortcuts()
            context.check(
                "Restore Defaults gives an upgrade the macOS shortcuts",
                KeyboardShortcuts.getShortcut(for: .captureDisplay) == display)

            harness.systemShortcuts.enabled = E2ESystemShortcuts.screenshotDefaults
            status.refreshAll()
        }

        static func captureMenu(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            context.check("Show Capture Menu is enabled", app.isEnabled(.captureMenu))
            let presenter = CaptureMenuPresenter(actions: app)
            let menu = presenter.makeMenu()
            context.check(
                "the menu lists every capture mode in order",
                menu.items.map(\.title) == AppCommand.captureModes.map(\.title),
                menu.items.map(\.title).joined(separator: " | "))
            for (item, command) in zip(menu.items, AppCommand.captureModes) {
                context.check(
                    "\(command.rawValue) is \(app.isEnabled(command) ? "enabled" : "disabled") in the menu",
                    item.isEnabled == app.isEnabled(command))
            }

            let index = try context.unwrap(
                "Capture Display is in the menu", AppCommand.captureModes.firstIndex(of: .captureDisplay))
            let before = harness.editors.controllers.count
            menu.performActionForItem(at: index)
            _ = try await E2EActions.waitForNewEditor(harness, after: before, context)
            context.check(
                "choosing Capture Display captured the display",
                harness.capture.captures.last == .display(harness.capture.display),
                "\(String(describing: harness.capture.captures.last))")
        }

        static func spaceForWindow(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let coordinator = harness.features.capture
            harness.app.perform(.captureRegion)
            try context.require("Capture Region starts selecting", coordinator.state == .selecting)

            let selection = RegionSelectionView(display: harness.capture.display)
            selection.allowsWindowSwitch = true
            selection.onSwitchToWindow = { coordinator.switchToWindowSelection() }
            let window = E2ESnapshot.host(nsView: selection, size: SyntheticDesktop.size)
            defer { window.close() }
            await E2ESnapshot.settle(selection)
            context.snapshot(selection, shot: "region-with-space-hint", over: harness.desktop)

            let point = CGPoint(x: 400, y: 300)
            selection.mouseDown(with: try CaptureScenarios.mouseEvent(.leftMouseDown, at: point, in: selection))
            selection.keyDown(with: try space(in: selection))
            context.check(
                "Space during a drag keeps the region selection", coordinator.mode == .region,
                "\(String(describing: coordinator.mode))")
            selection.mouseUp(with: try CaptureScenarios.mouseEvent(.leftMouseUp, at: point, in: selection))

            selection.keyDown(with: try space(in: selection))
            context.check(
                "Space switches the same request to a window", coordinator.mode == .window,
                "\(String(describing: coordinator.mode))")
            let listed = await E2EWait.until {
                if case .window = coordinator.selectionContext { return true }
                return false
            }
            context.check("the window chooser's list arrives", listed)
            coordinator.cancel()

            harness.app.perform(.captureText)
            try context.require("Capture Text starts selecting", coordinator.state == .selecting)
            selection.allowsWindowSwitch = false
            selection.keyDown(with: try space(in: selection))
            context.check(
                "Space does nothing in Capture Text",
                coordinator.mode == .region && coordinator.purpose == .recognizeText,
                "\(String(describing: coordinator.mode))")
            coordinator.cancel()
        }

        private static func space(in view: NSView) throws -> NSEvent {
            guard let window = view.window,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: 49)
            else { throw E2EAbort("could not synthesize Space") }
            return event
        }
    }
#endif
