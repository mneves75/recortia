#if DEBUG
    import AppKit
    import Features

    /// UX-02 / ADR-007: Recortia is accessory while it has no switchable window and regular while it
    /// has one, so ⌘Tab, the Dock and window switchers reach its windows. Every window here is parked
    /// offscreen and transparent; the physical AltTab and fullscreen-Space checks stay manual.
    @MainActor
    enum PresenceScenarios {
        static func windowPresence(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let presence = AppPresence.shared
            harness.reset()
            try context.require(
                "with no window Recortia is accessory (no Dock icon)",
                await E2EWait.until(timeout: .seconds(3)) { NSApp.activationPolicy() == .accessory },
                policy())

            // A titled window as presenting code shows it (Settings, onboarding, About). Hosting
            // windows such as Settings recurse in layout when ordered offscreen in this process, so
            // the rule is exercised on plain windows and the real editor; the installed app covers
            // Settings itself.
            let settings = plainWindow()
            show(settings, presence)
            context.check(
                "presenting a window makes Recortia regular at once", NSApp.activationPolicy() == .regular, policy())
            checkAppMenu(context)

            // One window replacing another in the same turn never demotes.
            let demotionsBefore = presence.demotions
            let replacement = plainWindow()
            settings.close()
            show(replacement, presence)
            try? await Task.sleep(for: .milliseconds(200))
            context.check(
                "closing one window while another opens keeps Recortia regular",
                NSApp.activationPolicy() == .regular && presence.demotions == demotionsBefore,
                "\(policy()), demotions \(presence.demotions - demotionsBefore)")
            try checkPinWindow(harness, context)
            replacement.close()
            context.check(
                "closing the last window returns Recortia to accessory",
                await E2EWait.until(timeout: .seconds(3)) { NSApp.activationPolicy() == .accessory }, policy())
            context.check("that return is one demotion", presence.demotions == demotionsBefore + 1)

            // An editor: minimizing, capture suspension and Hide keep Recortia regular.
            let controller = try await harness.openImported(harness.desktop, name: "presence.png")
            let editor = try context.unwrap("the editor has a window", controller.window)
            editor.ignoresMouseEvents = true
            show(editor, presence)
            context.check("an open editor makes Recortia regular", NSApp.activationPolicy() == .regular, policy())

            let held = presence.demotions
            harness.app.perform(.captureRegion)
            try context.require("capture hides the editor", !editor.isVisible)
            try? await Task.sleep(for: .milliseconds(200))
            context.check(
                "a capture that hides the editor keeps Recortia regular",
                NSApp.activationPolicy() == .regular && presence.demotions == held, policy())
            harness.features.capture.cancel()
            try context.require("cancel restores the editor", await E2EWait.until { editor.isVisible })

            NSApp.hide(nil)
            try? await Task.sleep(for: .milliseconds(200))
            context.check(
                "hiding Recortia keeps it regular", NSApp.activationPolicy() == .regular && presence.demotions == held,
                policy())
            NSApp.unhideWithoutActivation()
            _ = await E2EWait.until { editor.isVisible }

            editor.miniaturize(nil)
            try context.require(
                "the editor minimizes", await E2EWait.until(timeout: .seconds(5)) { editor.isMiniaturized })
            try? await Task.sleep(for: .milliseconds(200))
            context.check(
                "a minimized editor keeps Recortia regular",
                NSApp.activationPolicy() == .regular && presence.demotions == held, policy())
            context.check("the minimized editor is what a Dock click restores", presence.minimizedWindow === editor)
            harness.app.handleReopen(hasVisibleWindows: false)
            context.check(
                "a Dock click restores the minimized editor instead of opening Settings",
                await E2EWait.until(timeout: .seconds(5)) { !editor.isMiniaturized })

            editor.close()
            context.check(
                "closing the editor returns Recortia to accessory",
                await E2EWait.until(timeout: .seconds(3)) { NSApp.activationPolicy() == .accessory }, policy())
            harness.reset()
        }

        /// The real pin panel, constructed only: a hosting panel ordered offscreen in this process
        /// can recurse in layout (the `pins` scenario orders it in a child-process probe). It is
        /// released before its pin closes, as `PinsUIController` does.
        private static func checkPinWindow(_ harness: E2EHarness, _ context: ScenarioContext) throws {
            let pins = harness.features.pins
            let pinID = try pins.add(harness.desktop, source: nil, displayScale: 2)
            do {
                let pin = PinPanel(pinID: pinID, model: pins)
                context.check("a pin is a normal-level window", pin.level == .normal, "level \(pin.level.rawValue)")
                context.check("a pin does not float", !pin.isFloatingPanel)
                context.check("a pin has a title switchers can show", !pin.title.isEmpty)
                context.check(
                    "a pin is still shown on every Space",
                    pin.collectionBehavior.isSuperset(of: SpacePolicy.joinsAllSpaces),
                    "raw=\(pin.collectionBehavior.rawValue)")
                pin.close()
            }
            pins.close(pinID)
        }

        private static func plainWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }

        /// FR-01: opening Recortia shows a window (onboarding first, then Settings) so it is visible
        /// in ⌘Tab and the Dock; "Open at login" stays silent. The login marker is what macOS puts
        /// on the open-application event of a login item.
        static func launchPresentation(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            func openEvent(loginItem: Bool) -> NSAppleEventDescriptor {
                let event = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                    targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID))
                if loginItem {
                    event.setParam(
                        NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
                        forKeyword: AEKeyword(keyAEPropData))
                }
                return event
            }
            context.check(
                "an open event marked as a login item is a login launch",
                LaunchKind(openEvent: openEvent(loginItem: true)) == .loginItem)
            context.check(
                "a plain open event is a launch by the person",
                LaunchKind(openEvent: openEvent(loginItem: false)) == .user)
            context.check("a launch without an event counts as the person's", LaunchKind(openEvent: nil) == .user)
            context.check(
                "first launch shows onboarding",
                LaunchWindow.choose(onboardingPending: true, kind: .user) == .onboarding
                    && LaunchWindow.choose(onboardingPending: true, kind: .loginItem) == .onboarding)
            context.check(
                "opening Recortia shows Settings",
                LaunchWindow.choose(onboardingPending: false, kind: .user) == .settings)
            context.check(
                "Open at login shows no window",
                LaunchWindow.choose(onboardingPending: false, kind: .loginItem) == .none)
        }

        /// Orders `window` in the way presenting code does, parked offscreen and transparent.
        private static func show(_ window: NSWindow, _ presence: AppPresence) {
            E2ESnapshot.park(window)
            window.alphaValue = 0
            presence.windowWillAppear()
            window.orderBack(nil)
        }

        /// The menu bar shows Recortia's own menu while it is regular: Settings and a Quit that goes
        /// through `applicationShouldTerminate` (unexported-edits confirmation).
        private static func checkAppMenu(_ context: ScenarioContext) {
            let items = allItems(NSApp.mainMenu)
            let settings = items.first { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
            context.check(
                "the app menu has Settings… (⌘,)", settings != nil, items.map(\.title).joined(separator: ", "))
            let quit = items.first { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command }
            context.check(
                "the app menu's Quit (⌘Q) terminates through the app delegate",
                quit?.action == #selector(NSApplication.terminate(_:)), String(describing: quit?.action))
        }

        private static func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + allItems($0.submenu) }
        }

        private static func policy() -> String {
            switch NSApp.activationPolicy() {
            case .regular: "regular"
            case .accessory: "accessory"
            case .prohibited: "prohibited"
            @unknown default: "unknown"
            }
        }
    }
#endif
