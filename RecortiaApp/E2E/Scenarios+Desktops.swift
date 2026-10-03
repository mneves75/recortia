#if DEBUG
    import AppKit
    import Domain
    import Features
    import MacPlatform

    /// FR-01/FR-02/FR-09 on every desktop: Spaces, displays and focus. Physical Spaces and second
    /// displays cannot be created here; these checks use AppKit's own window properties and
    /// synthetic display layouts, and `scripts/space-probe` records the physical evidence.
    @MainActor
    enum DesktopScenarios {
        /// A window AppKit reports as being on another Space.
        private final class OtherSpaceWindow: NSWindow {
            override var isOnActiveSpace: Bool { false }
        }

        private struct FakeScreen: Equatable {
            var id: CGDirectDisplayID
            var frame: CGRect
        }

        static func otherSpaces(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let here = parked(NSWindow.self)
            let elsewhere = parked(OtherSpaceWindow.self)
            defer { [here, elsewhere].forEach { $0.close() } }
            try context.require("both windows start ordered", here.isVisible && elsewhere.isVisible)

            harness.app.perform(.captureRegion)
            context.check("selection hides a window on the current Space", !here.isVisible)
            context.check("selection leaves a window on another Space where it is", elsewhere.isVisible)
            harness.features.capture.cancel()
            try context.require("cancel restores the current Space's window", await E2EWait.until { here.isVisible })
            context.check("the other Space's window stays visible", elsewhere.isVisible)
        }

        static func screenChoice(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            // Two displays side by side; the second has a negative origin like a display placed left.
            let primary = FakeScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
            let left = FakeScreen(id: 2, frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
            let screens = [primary, left]
            func pick(_ id: CGDirectDisplayID?, _ pointer: CGPoint) -> FakeScreen? {
                ScreenChoice.pick(screens, displayID: id, pointer: pointer, id: \.id, frame: \.frame)
            }
            context.check(
                "a capture's display wins over the pointer", pick(2, CGPoint(x: 100, y: 100)) == left)
            context.check("without a display, the pointer's screen", pick(nil, CGPoint(x: -100, y: 100)) == left)
            context.check(
                "a display that went away falls back to the pointer", pick(9, CGPoint(x: 100, y: 100)) == primary)
            context.check(
                "a pointer between screens falls back to the first", pick(nil, CGPoint(x: 9000, y: 9000)) == primary)

            // A large pin is sized for the screen it appears on, not the key window's screen.
            let small = CGRect(x: -1280, y: 0, width: 1280, height: 720)
            let image = try E2EDrawing.image(size: CGSize(width: 2400, height: 1400), scale: 1) { rect in
                NSColor.systemTeal.setFill()
                rect.fill()
            }
            let id = try harness.features.pins.add(image, source: nil, displayScale: 1)
            defer { harness.features.pins.close(id) }
            let scale = PinPanel.fitScale(for: harness.features.pins.pin(for: id), visibleFrame: small)
            context.check(
                "a pin fits 60% of a small display", Double(2400) * scale <= small.width * 0.6 + 0.5,
                "scale=\(scale)")
        }

        static func countdownCancel(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let panel = CaptureUIController.makeCountdownPanel()
            context.check(
                "the countdown never activates Recortia when shown", panel.styleMask.contains(.nonactivatingPanel))
            context.check(
                "a click makes the countdown key, so Escape cancels without the hot key", panel.canBecomeKey)
        }

        static func heldShortcutPolling(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let delays = (0..<12).map { AppModel.heldShortcutPollDelay(afterChecks: $0) }
            context.check("the first re-check is quick", delays.first == .seconds(2), "\(delays)")
            context.check("re-checks back off", delays == delays.sorted() && delays.last! > delays.first!, "\(delays)")
            context.check(
                "a freed key is claimed within 10 s", delays.allSatisfy { $0 <= .seconds(10) }, "\(delays)")
        }

        static func captureMenuFocus(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let other = try context.unwrap(
                "another application is running",
                NSWorkspace.shared.runningApplications.first {
                    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
                })
            var returned: [pid_t] = []
            var activations = 0
            func presenter(choosing index: Int?) -> CaptureMenuPresenter {
                CaptureMenuPresenter(
                    actions: harness.app,
                    focus: .init(
                        frontmost: { other }, activate: { activations += 1 },
                        popUp: { menu in if let index { menu.performActionForItem(at: index) } },
                        returnFocus: { returned.append($0.processIdentifier) }))
            }
            presenter(choosing: nil).present()
            context.check("the menu activates Recortia for keyboard use", activations == 1)
            context.check(
                "dismissing the menu returns focus to the previous app", returned == [other.processIdentifier],
                "\(returned)")

            returned = []
            let index = try context.unwrap(
                "Capture Region is in the menu", AppCommand.captureModes.firstIndex(of: .captureRegion))
            presenter(choosing: index).present()
            context.check("choosing a mode keeps focus for the capture", returned.isEmpty, "\(returned)")
            _ = await E2EWait.until { harness.features.capture.state == .selecting }
            harness.features.capture.cancel()
        }

        /// A transparent, click-through window ordered in offscreen: never visible to the user.
        private static func parked<W: NSWindow>(_ type: W.Type) -> W {
            let window = W(
                contentRect: NSRect(x: 0, y: 0, width: 160, height: 100), styleMask: [.titled], backing: .buffered,
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
