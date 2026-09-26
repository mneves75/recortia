#if DEBUG
    import AppKit
    import Domain
    import Features
    import SwiftUI

    /// App shell: first launch, the menu-bar menu, and Settings (FR-01, FR-14).
    @MainActor
    enum ShellScenarios {
        static func onboarding(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let onboarding = harness.app.onboarding
            context.check("fresh settings present onboarding", onboarding.shouldPresent)
            context.check(
                "starts on the local-processing step", onboarding.step == .localProcessing, "\(onboarding.step)")
            let view = OnboardingView(onboarding: onboarding, shortcutStatus: harness.app.shortcutStatus, onClose: {})
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            E2ESnapshot.park(window)
            defer { window.close() }
            let root = try context.unwrap("onboarding window has content", window.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "local-processing")

            onboarding.next()
            context.check("Continue moves to shortcuts", onboarding.step == .shortcuts, "\(onboarding.step)")
            context.check("Back is available on the shortcuts step", onboarding.canGoBack)
            await E2ESnapshot.settle(root)
            context.snapshot(root, shot: "shortcuts")

            onboarding.finish()
            context.check("Done completes onboarding", harness.settings.preferences.hasCompletedOnboarding)
            context.check("onboarding is not shown again", !onboarding.shouldPresent)
            context.check(
                "onboarding requested no Screen Recording permission", harness.permission.requestCount == 0,
                "requests: \(harness.permission.requestCount)")
        }

        static func menu(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            let expected: [AppCommand: Bool] = [
                .captureRegion: true, .captureDisplay: true, .captureWindow: true, .captureWithDelay: true,
                .repeatLastRegion: false, .scrollingCapture: true, .captureText: true, .openImage: true,
                .pasteImage: true, .bringPinsForward: false, .closeAllPins: false, .settings: true, .about: true,
                .quit: true,
            ]
            for command in AppCommand.allCases {
                let enabled = app.isEnabled(command)
                context.check(
                    "\(command.rawValue) is \(expected[command] == true ? "enabled" : "disabled")",
                    enabled == expected[command], "isEnabled == \(enabled)")
            }
            let titles = AppCommand.allCases.map(\.title)
            context.check(
                "every command has a distinct localized title", Set(titles).count == titles.count,
                titles.joined(separator: " | "))

            let menu = VStack(alignment: .leading, spacing: 2) {
                MenuContent(model: app)
            }
            .buttonStyle(.plain)
            .padding(10)
            .frame(width: 300, alignment: .leading)
            let window = E2ESnapshot.host(menu)
            defer { window.close() }
            let root = try context.unwrap("menu content hosted", window.contentView)
            await E2ESnapshot.settle(root)
            context.snapshot(root)
        }

        static func settings(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let preferences = harness.settings.preferences
            context.check("automatic copy is off by default", !preferences.autoCopy)
            context.check("automatic save is off by default", !preferences.autoSave)
            context.check("update checks are off by default", !preferences.updateChecksEnabled)
            context.check("automatic scrolling is off by default", !preferences.automaticScrollingEnabled)
            context.check("export defaults to PNG at 100%", preferences.exportOptions == ExportOptions())

            let controller = NSHostingController(rootView: SettingsView(model: harness.app))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            E2ESnapshot.park(window)
            window.setContentSize(NSSize(width: 560, height: 540))
            defer { window.close() }
            let root = try context.unwrap("settings window has content", window.contentView)
            await E2ESnapshot.settle(root)

            let tabs = [
                "general", "shortcuts", "capture", "export", "privacy", "text-recognition", "pins", "scrolling",
            ]
            if let tabView = EditorWindowController.first(NSTabView.self, in: root) {
                context.check(
                    "Settings has one tab per area", tabView.numberOfTabViewItems == tabs.count,
                    "\(tabView.numberOfTabViewItems) tabs")
                for (index, name) in tabs.enumerated() where index < tabView.numberOfTabViewItems {
                    tabView.selectTabViewItem(at: index)
                    if name == "text-recognition" {
                        let loaded = await E2EWait.until {
                            if case .loaded = harness.features.ocrLanguages.state { return true }
                            return false
                        }
                        context.check(
                            "OCR languages load at runtime", loaded, "\(harness.features.ocrLanguages.state)")
                    }
                    await E2ESnapshot.settle(root, for: .milliseconds(400))
                    // The tab's own content: outside the Settings scene the strip is a plain
                    // NSTabView whose selected label does not render offscreen.
                    context.snapshot(tabView.selectedTabViewItem?.view ?? root, shot: name)
                }
            } else {
                context.check("Settings exposes an AppKit tab view", false, "no NSTabView in the hosted hierarchy")
            }
        }
    }
#endif
