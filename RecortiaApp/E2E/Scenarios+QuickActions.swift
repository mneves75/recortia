#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import MacPlatform

    /// The quick-action thumbnail (B-1, ADR-009) through the real capture path, `AppModel`'s
    /// synchronous follow-up decision, the product's thumbnail controller and its SwiftUI buttons.
    /// The image store's size shows when the capture's pixels are released.
    @MainActor
    enum QuickActionsScenarios {
        static func quickActions(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let model = harness.features.quickActions
            let ui = harness.quickActionsUI
            let store = try context.unwrap(
                "the live image store", (harness.services.assets as? LiveImageAssets)?.store)

            // Default: today's flow.
            context.check(
                "After a capture defaults to the editor",
                Preferences().afterCapture == .openEditor && harness.settings.preferences.afterCapture == .openEditor)
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check(
                "by default a capture opens the editor and no thumbnail", model.capture == nil && ui.panel == nil)
            harness.editors.closeAll()

            harness.settings.update {
                $0.afterCapture = .showQuickActions
                $0.autoCopy = true
            }
            let baseline = await settledCount(store)
            let copies = harness.clipboard.writeCount
            let editorCount = harness.editors.controllers.count
            let root = try await showThumbnail(harness, context)
            let panel = try context.unwrap("the thumbnail panel", ui.panel)
            context.check(
                "the automatic copy ran before the thumbnail showed", harness.clipboard.writeCount == copies + 1,
                "\(harness.clipboard.writeCount - copies) copies")
            context.check("no editor opened", harness.editors.controllers.count == editorCount)
            let holding = await store.count
            context.check("the image store holds the capture", holding == baseline + 1, "\(holding) of \(baseline)")
            context.check(
                "the thumbnail is a non-activating floating panel",
                panel.styleMask.contains(.nonactivatingPanel) && panel.level == .floating && panel.isFloatingPanel,
                "\(panel.styleMask.rawValue) level \(panel.level.rawValue)")
            let shownFrame = panel.frame
            await E2ESnapshot.settle(root, for: .milliseconds(400))
            context.check(
                "the thumbnail keeps the one size its content set",
                panel.frame.size == shownFrame.size && shownFrame.width > 0 && shownFrame.height > 0,
                "\(shownFrame.size) → \(panel.frame.size)")
            context.check(
                "the thumbnail joins all Spaces", panel.collectionBehavior == SpacePolicy.joinsAllSpaces,
                "\(panel.collectionBehavior.rawValue)")
            context.check(
                "the thumbnail is never a switchable window",
                panel.isVisible && !AppPresence.isSwitchable(panel) && !panel.isKeyWindow)
            let names: [(String, String)] = [
                ("copy", String(localized: "Copy", table: "Editor")),
                ("save", String(localized: "Save", table: "Editor")),
                ("edit", String(localized: "Open in Editor")),
                ("pin", String(localized: "Pin", table: "Editor")),
                ("dismiss", String(localized: "Dismiss", table: "Editor")),
            ]
            for (id, name) in names {
                let shown = try E2EAccessibilityControl.name(for: "quickActions.\(id)", in: root, context)
                context.check("the \(id) action is labelled “\(name)”", shown == name, shown)
            }
            context.check(
                "no Copy Link without an upload", !E2EAccessibilityControl.isPresent("quickActions.copyLink", in: root))
            let thumbnail = try context.unwrap(
                "the preview view", EditorWindowController.first(QuickActionsThumbnailView.self, in: root))
            context.check("the preview shows the sanitized render", model.capture?.preview != nil)
            context.snapshot(root, shot: "thumbnail")
            await context.darkCompanion(
                root, in: panel, shot: "thumbnail", surface: "quick-action thumbnail", excluding: [thumbnail])

            // Copy: through the export pipeline to the harness clipboard, then the capture goes.
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.copy", in: root, context)
            try context.require(
                "Copy writes the clipboard", await E2EWait.until { harness.clipboard.writeCount == copies + 2 })
            let data = try context.unwrap("PNG on the pasteboard", harness.clipboard.pasteboard.data(forType: .png))
            let copied = try E2EActions.decode(data, "quick-action copy", context)
            context.check(
                "the copy is the whole capture", copied.width == Int(SyntheticDesktop.notesWindow.width * 2),
                "\(copied.width)×\(copied.height)")
            context.check("Copy closes the thumbnail", await E2EWait.until { model.capture == nil && ui.panel == nil })
            context.check("Copy releases the capture", await waitForCount(store, baseline))

            // Dismiss: nothing is written and the capture is released.
            harness.settings.update { $0.autoCopy = false }
            let dismissRoot = try await showThumbnail(harness, context)
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.dismiss", in: dismissRoot, context)
            context.check(
                "Dismiss closes the thumbnail", await E2EWait.until { model.capture == nil && ui.panel == nil })
            context.check("Dismiss releases the capture", await waitForCount(store, baseline))
            context.check("Dismiss writes nothing", harness.clipboard.writeCount == copies + 2)

            // Copy Link: this capture's own automatic upload, as text; the thumbnail stays.
            let destination = GitHubDestination(owner: "fixture", repository: "private-captures")
            try harness.github.store(GitHubTokenStore.validatedToken("ghp_synthetic"), for: destination)
            harness.settings.update {
                $0.githubUpload = GitHubUploadPreferences(destination: destination, automatic: true)
            }
            let uploads = harness.github.snapshots.count
            let linkRoot = try await showThumbnail(harness, context)
            let uploadedCapture = try context.unwrap("the uploaded capture", model.capture)
            context.check(
                "the automatic upload ran before the thumbnail showed",
                harness.github.snapshots.count == uploads + 1
                    && harness.github.snapshots.last?.documentID == uploadedCapture.session.document.id)
            let link = try context.unwrap("this capture's upload link", uploadedCapture.uploadedURL)
            let linkName = try E2EAccessibilityControl.name(for: "quickActions.copyLink", in: linkRoot, context)
            context.check(
                "the Copy Link action is labelled “\(String(localized: "Copy Link"))”",
                linkName == String(localized: "Copy Link"), linkName)
            harness.textPasteboard.clearContents()
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.copyLink", in: linkRoot, context)
            try context.require(
                "Copy Link writes the link as text",
                await E2EWait.until { harness.textPasteboard.string(forType: .string) == link.absoluteString },
                harness.textPasteboard.string(forType: .string) ?? "nothing")
            context.check(
                "the link is a GitHub link for the fixture repository",
                link.absoluteString.hasPrefix("https://github.com/fixture/private-captures/"))
            await E2ESnapshot.settle(linkRoot)
            let linkHeld = await store.count
            context.check(
                "Copy Link keeps the thumbnail and the capture",
                model.capture?.id == uploadedCapture.id && model.isShown && linkHeld == baseline + 1,
                "\(linkHeld) of \(baseline)")
            context.check("Copy Link writes no image", harness.clipboard.writeCount == copies + 2)
            context.snapshot(linkRoot, shot: "copy-link")
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.dismiss", in: linkRoot, context)
            context.check("the uploaded capture is released", await waitForCount(store, baseline))
            harness.settings.update { $0.githubUpload = nil }

            // Open in Editor: the ordinary editor takes the capture, which stays in the store.
            let editRoot = try await showThumbnail(harness, context)
            let held = try context.unwrap("the held capture", model.capture?.session.document.id)
            context.check(
                "the next capture offers no link from the earlier upload",
                model.capture?.uploadedURL == nil
                    && !E2EAccessibilityControl.isPresent("quickActions.copyLink", in: editRoot))
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.edit", in: editRoot, context)
            try context.require(
                "Open in Editor opens an editor",
                await E2EWait.until { harness.editors.controllers.count == editorCount + 1 })
            let editor = try context.unwrap("the editor", harness.editors.controllers.last)
            context.check("the editor shows the held capture", editor.model.document.id == held)
            context.check(
                "the editor is an ordinary window that follows the active Space",
                editor.window?.collectionBehavior == SpacePolicy.followsActiveSpace && editor.window?.level == .normal)
            // The model lets go synchronously; the controller closes the panel on its next observation
            // pass, as after Copy and Dismiss.
            context.check(
                "the thumbnail closed", await E2EWait.until { model.capture == nil && ui.panel == nil },
                "capture \(model.capture == nil ? "released" : "held"), panel \(ui.panel == nil ? "closed" : "open")")
            let kept = await settledCount(store)
            context.check("the editor keeps the capture's pixels", kept == baseline + 1, "\(kept) of \(baseline)")
            harness.editors.closeAll()
            context.check("closing the editor releases them", await waitForCount(store, baseline))
        }

        /// Captures the notes window and waits for its thumbnail; returns the panel's content.
        private static func showThumbnail(_ harness: E2EHarness, _ context: ScenarioContext) async throws -> NSView {
            let coordinator = harness.features.capture
            harness.app.perform(.captureRegion)
            try context.require(
                "Capture Region starts selecting", coordinator.state == .selecting, "\(coordinator.state)")
            try context.require(
                "committing the region is accepted",
                coordinator.commitRegion(
                    E2EActions.desktopRect(SyntheticDesktop.notesWindow), on: harness.capture.display))
            try context.require(
                "the thumbnail shows",
                await E2EWait.until { harness.features.quickActions.isShown && harness.quickActionsUI.panel != nil })
            let root = try context.unwrap("thumbnail content", harness.quickActionsUI.panel?.contentView)
            await E2ESnapshot.settle(root)
            return root
        }

        /// The store's size once it has stopped changing (releases are asynchronous).
        private static func settledCount(_ store: ImageStore) async -> Int {
            var last = await store.count
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                let now = await store.count
                if now == last { return now }
                last = now
            }
            return last
        }

        private static func waitForCount(_ store: ImageStore, _ expected: Int) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while await store.count != expected {
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }
    }
#endif
