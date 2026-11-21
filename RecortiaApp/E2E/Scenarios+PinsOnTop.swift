#if DEBUG
    import AppKit
    import Features
    import SwiftUI

    /// ADR-007 amendment: per-pin Keep on Top and click-through, driven through the pin's real
    /// control strip, with Unlock All Pins as the way back. The real `PinPanel` is constructed only,
    /// because a hosting panel ordered in this process can recurse in layout; its presence while
    /// shown is checked in a child-process probe. Whether a third-party window switcher lists a
    /// floating pin stays a physical check.
    @MainActor
    enum PinLayeringScenarios {
        static func pinOnTop(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            harness.reset()
            let pins = harness.features.pins
            let first = try pins.add(harness.desktop, source: nil, displayScale: 2)
            let second = try pins.add(harness.desktop, source: nil, displayScale: 2)
            let panel = PinPanel(pinID: first, model: pins)
            let other = PinPanel(pinID: second, model: pins)
            // Released before their pins close, as `PinsUIController` does.
            defer {
                panel.close()
                other.close()
                harness.reset()
            }
            let spaces = panel.collectionBehavior
            func checkSpaces(_ step: String) {
                context.check(
                    "\(step): the pin still joins every Space",
                    panel.collectionBehavior == spaces && spaces.isSuperset(of: SpacePolicy.joinsAllSpaces),
                    "raw \(panel.collectionBehavior.rawValue), was \(spaces.rawValue)")
            }
            context.check("a new pin is a normal-level window", panel.level == .normal, "level \(panel.level.rawValue)")
            context.check("a new pin takes clicks", !panel.ignoresMouseEvents)
            context.check("with no locked pin, Unlock All Pins is disabled", !harness.app.isEnabled(.unlockAllPins))

            let host = E2ESnapshot.host(
                PinContentView(pinID: first, model: pins, fitScale: 1, controlsAlwaysVisible: true))
            defer { host.close() }
            let root = try context.unwrap("pin content hosted", host.contentView)
            await E2ESnapshot.settle(root)
            context.check(
                "Click Through is unavailable until the pin is on top",
                try !E2EAccessibilityControl.isEnabled("pin.clickThrough", in: root, context))
            context.check("an unlocked pin shows no lock", !E2EAccessibilityControl.isPresent("pin.locked", in: root))

            try E2EAccessibilityControl.pressCheckingEffect("pin.keepOnTop", in: root, context)
            context.check(
                "Keep on Top floats the pin above normal windows",
                await E2EWait.until(timeout: .seconds(3)) { panel.level == .floating }, "level \(panel.level.rawValue)")
            context.check("Keep on Top alone still takes clicks", !panel.ignoresMouseEvents)
            checkSpaces("on top")
            await E2ESnapshot.settle(root)
            context.check(
                "Click Through is available once the pin is on top",
                try E2EAccessibilityControl.isEnabled("pin.clickThrough", in: root, context))

            try E2EAccessibilityControl.pressCheckingEffect("pin.clickThrough", in: root, context)
            context.check(
                "Click Through makes the pin ignore the mouse",
                await E2EWait.until(timeout: .seconds(3)) { panel.ignoresMouseEvents })
            context.check("a click-through pin stays on top", panel.level == .floating)
            checkSpaces("click-through")
            await E2ESnapshot.settle(root)
            context.check(
                "a click-through pin shows a lock",
                E2EAccessibilityControl.isPresent("pin.locked", in: root))
            context.snapshot(root, shot: "pin-locked")
            context.check("with a locked pin, Unlock All Pins is enabled", harness.app.isEnabled(.unlockAllPins))
            let unlock = await checkMainMenu(enabled: true, context)

            pins.setKeepsOnTop(true, for: second)
            pins.setClickThrough(true, for: second)
            try context.require(
                "a second pin locks too", await E2EWait.until(timeout: .seconds(3)) { other.ignoresMouseEvents })

            let item = try context.unwrap("the Window menu has Unlock All Pins", unlock)
            let menu = try context.unwrap("Unlock All Pins belongs to the Window menu", item.menu)
            menu.performActionForItem(at: menu.index(of: item))
            context.check(
                "Unlock All Pins restores mouse events on every pin",
                await E2EWait.until(timeout: .seconds(3)) { !panel.ignoresMouseEvents && !other.ignoresMouseEvents })
            context.check(
                "unlocked pins stay on top", panel.level == .floating && other.level == .floating,
                "levels \(panel.level.rawValue), \(other.level.rawValue)")
            await E2ESnapshot.settle(root)
            context.check("an unlocked pin hides its lock", !E2EAccessibilityControl.isPresent("pin.locked", in: root))
            context.check(
                "with no locked pin, Unlock All Pins is disabled again", !harness.app.isEnabled(.unlockAllPins))
            _ = await checkMainMenu(enabled: false, context)

            try E2EAccessibilityControl.pressCheckingEffect("pin.keepOnTop", in: root, context)
            context.check(
                "turning Keep on Top off returns the pin to the normal level",
                await E2EWait.until(timeout: .seconds(3)) { panel.level == .normal }, "level \(panel.level.rawValue)")
            checkSpaces("back at the normal level")

            await E2EPanelProbe.check(.pinOnTop, context)
        }

        /// Window › Unlock All Pins in the app's menu bar, brought up to date as opening the menu would.
        private static func checkMainMenu(enabled: Bool, _ context: ScenarioContext) async -> NSMenuItem? {
            let title = AppCommand.unlockAllPins.title
            func item() -> NSMenuItem? { EditorToolbarScenarios.viewCommand(title) }
            let matched = await E2EWait.until(timeout: .seconds(3)) { item()?.isEnabled == enabled }
            let command = item()
            context.check(
                "the menu bar's Unlock All Pins is \(enabled ? "enabled" : "disabled")", matched,
                command.map { "found in menu, enabled \($0.isEnabled)" } ?? "no item titled \(title)")
            return command
        }
    }
#endif
