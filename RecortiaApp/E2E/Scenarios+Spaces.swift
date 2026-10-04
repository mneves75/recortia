#if DEBUG
    import AppKit
    import Domain
    import Features
    import MacPlatform

    /// FR-01 on every desktop: each window Recortia shows carries a Space policy. A physical probe
    /// (`scripts/space-probe`, macOS 27) showed that activating the app switches the user to any
    /// Space holding a Recortia window without one, even out of another app's fullscreen Space,
    /// while windows that follow the active Space move to the user instead. This scenario guards
    /// the configuration; it cannot create Spaces, so it does not replace the physical check.
    @MainActor
    enum SpaceScenarios {
        private static let follows: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        private static let joinsAll: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        static func spacePolicy(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            func checkFollows(_ name: String, _ window: NSWindow) {
                let behavior = window.collectionBehavior
                context.check(
                    "\(name) follows the active Space", behavior.isSuperset(of: follows), "raw=\(behavior.rawValue)")
                context.check("\(name) does not also join every Space", !behavior.contains(.canJoinAllSpaces))
                context.check(
                    "\(name) has a single fullscreen behavior",
                    !behavior.contains(.fullScreenPrimary) && !behavior.contains(.fullScreenNone))
            }
            func checkJoinsAll(_ name: String, _ window: NSWindow) {
                let behavior = window.collectionBehavior
                context.check(
                    "\(name) is shown on every Space", behavior.isSuperset(of: joinsAll), "raw=\(behavior.rawValue)")
                context.check("\(name) does not also move between Spaces", !behavior.contains(.moveToActiveSpace))
            }

            // Windows Recortia constructs.
            checkFollows("the onboarding window", OnboardingWindowController.makeWindow(NSViewController()))
            checkFollows(
                "the scrolling review window", ScrollUIController.makeReviewWindow(model: harness.features.scroll))
            // Settings is Recortia's own window: SwiftUI's Settings scene orders its window inside
            // openSettings, before a policy can exist, and a fresh one switched Spaces (0.10.1).
            let settings = SettingsWindowController.makeWindow(model: harness.app)
            defer { settings.close() }
            checkFollows("the Settings window", settings)
            let tabs = try context.unwrap(
                "Settings uses native tabs", settings.contentViewController as? NSTabViewController)
            context.check("Settings shows toolbar tabs like macOS Settings", tabs.tabStyle == .toolbar)
            context.check(
                "Settings has one tab per area", tabs.tabViewItems.count == 9, "\(tabs.tabViewItems.count) tabs")
            context.check(
                "every Settings tab has a label and an icon",
                tabs.tabViewItems.allSatisfy { !$0.label.isEmpty && $0.image != nil })
            for message in [UserMessage.capture(.permissionDenied), .scroll(.targetLost)] {
                checkFollows("the alert \"\(message.title)\"", MessagePresenter.makeAlert(message).window)
            }
            checkJoinsAll("the window chooser", HostingPanel(title: "chooser", activating: true))
            checkJoinsAll("the countdown HUD", HostingPanel(title: "countdown", activating: false))
            if let display = DesktopGeometry.displays().first, let screen = display.screen {
                checkJoinsAll("the region overlay", OverlayWindow(display: display, screen: screen))
            }
            let pinID = try harness.features.pins.add(harness.desktop, source: nil, displayScale: 2)
            defer { harness.features.pins.close(pinID) }
            checkJoinsAll("a pin", PinPanel(pinID: pinID, model: harness.features.pins))

            // Windows AppKit and SwiftUI make for Recortia (Settings, About, alerts): adopted before
            // the application activates, so activation cannot switch Spaces.
            let framework = parkedWindow(style: [.titled, .closable])
            framework.collectionBehavior = [.fullScreenPrimary]
            let panel = parkedWindow(style: [.titled])
            panel.collectionBehavior = joinsAll
            let borderless = parkedWindow(style: [.borderless])
            defer { [framework, panel, borderless].forEach { $0.close() } }
            context.check(
                "the framework window starts without a Space policy",
                !framework.collectionBehavior.contains(.moveToActiveSpace))
            NotificationCenter.default.post(name: NSApplication.willBecomeActiveNotification, object: NSApp)
            checkFollows("a framework-made titled window", framework)
            context.check(
                "a panel that joins every Space keeps its policy", panel.collectionBehavior == joinsAll,
                "raw=\(panel.collectionBehavior.rawValue)")
            context.check(
                "a borderless system window is left alone", borderless.collectionBehavior == [],
                "raw=\(borderless.collectionBehavior.rawValue)")
        }

        /// A transparent, click-through window ordered in offscreen: never visible to the user.
        private static func parkedWindow(style: NSWindow.StyleMask) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: style, backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            E2ESnapshot.park(window)
            window.orderBack(nil)
            return window
        }
    }
#endif
