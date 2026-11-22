#if DEBUG
    import AppKit
    import Domain
    import Features
    import ImageIO
    import Imaging
    import MacPlatform
    import RecortiaFixtures

    /// Real Vision by default, with a one-shot failure or late callback for Copy Text.
    @MainActor
    final class SyntheticRecognitionGate: TextRecognitionService {
        enum Interception { case failure, delay }

        var next: Interception?
        private let recognition: any TextRecognitionService
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var lateCompletions = 0

        var isWaiting: Bool { waiter != nil }

        init(recognition: any TextRecognitionService) { self.recognition = recognition }

        func supportedLanguages() async -> [Locale.Language] { await recognition.supportedLanguages() }

        func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
            let interception = next
            next = nil
            switch interception {
            case .failure:
                throw E2EAbort("scripted recognition failure")
            case .delay:
                await withCheckedContinuation { waiter = $0 }
                lateCompletions += 1
                let stale = OCRResult.Line(
                    text: "Resultado atrasado", confidence: 1, box: Rect(x: 0, y: 0, width: 1, height: 1))
                return OCRResult(lines: [stale], revision: 3, languages: [])
            case nil:
                return try await recognition.recognize(image, languages: languages)
            }
        }

        func release() {
            waiter?.resume()
            waiter = nil
        }

        func reset() {
            next = nil
            release()
        }
    }

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
                ("saveOptimized", String(localized: "Save Optimized Copy…")),
                ("edit", String(localized: "Open in Editor")),
                ("pin", String(localized: "Pin", table: "Editor")),
                ("preview", String(localized: "Preview")),
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
            try await checkPreview(harness, panel, root, context)

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
            try await checkReplacement(harness, context)
            try await checkOptimizedSave(harness, context)
            try await checkOptimizedSaveDuringSelection(harness, context)
            try await checkPreviewReplacement(harness, context)
            try await checkMaskedPreview(harness, store, context)
            try await checkCopyText(harness, store, context)
            try await checkAutomaticPin(harness, store, context)
        }

        private static func checkAutomaticPin(
            _ harness: E2EHarness, _ store: ImageStore, _ context: ScenarioContext
        ) async throws {
            let previous = harness.settings.preferences
            let pinsUI = PinsUIController(model: harness.features.pins)
            defer {
                harness.app.perform(.closeAllPins)
                harness.exportGate.holdNextSnapshot = false
                harness.exportGate.release()
                harness.settings.update { $0 = previous }
                withExtendedLifetime(pinsUI) {}
            }
            let baseline = await settledCount(store)
            let copies = harness.clipboard.writeCount
            let editors = harness.editors.controllers.count
            harness.settings.update {
                $0.afterCapture = .pin
                $0.autoCopy = true
            }
            harness.exportGate.holdNextSnapshot = true
            try commitNotesRegion(harness, context)
            try context.require(
                "the automatic copy is suspended before any pin opens",
                await E2EWait.until { harness.exportGate.isWaiting } && harness.features.pins.pins.isEmpty)
            let foreground = try await E2EForegroundFixture.start(context)
            defer { foreground.requestStop() }
            // Let a mistaken activation request succeed even when macOS requires cooperation.
            try await foreground.yieldToRunner()
            try context.require(
                "the owned host is foreground before the pending pin can open",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier
                    && !NSApp.isActive)
            E2ERunner.log("quick-actions: releasing automatic Pin export")
            harness.exportGate.release()
            try context.require(
                "the capture opens a native pin",
                await E2EWait.until { NSApp.windows.contains { $0 is PinPanel && $0.isVisible } })
            let panel = try context.unwrap(
                "visible pin window", NSApp.windows.first(where: { $0 is PinPanel && $0.isVisible }))
            E2ERunner.log("quick-actions: automatic Pin window \(panel.windowNumber) is visible")
            await E2ESnapshot.settle(panel.contentView)
            context.check(
                "automatic Pin uses the ordinary all-Spaces panel and keeps Recortia switchable",
                AppPresence.isSwitchable(panel) && panel.level == .normal
                    && panel.collectionBehavior == SpacePolicy.joinsAllSpaces
                    && NSApp.activationPolicy() == .regular && panel.isOnActiveSpace)
            context.check(
                "the owned host stays foreground while the automatic pin opens",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier
                    && !NSApp.isActive)
            context.check("the automatic pin does not take the keyboard", !panel.isKeyWindow)
            context.check(
                "Pin shows no editor or thumbnail and Copy runs once",
                harness.editors.controllers.count == editors && harness.quickActionsUI.panel == nil
                    && harness.features.pins.pins.count == 1 && harness.clipboard.writeCount == copies + 1)
            context.check("automatic Pin releases the capture's source pixels", await waitForCount(store, baseline))
            let pin = try context.unwrap("the visible automatic Pin model", harness.features.pins.pins.first)
            let originalWidth = panel.frame.width
            harness.features.pins.setZoom(pin.zoom * 1.5, for: pin.id)
            context.check(
                "zoom grows the live pin while the foreground host keeps the keyboard",
                await E2EWait.until { panel.frame.width > originalWidth }
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier
                    && !panel.isKeyWindow)
            harness.app.perform(.closeAllPins)
            context.check("closing the pin orders its panel out", await E2EWait.until { !panel.isVisible })
            await foreground.stop(context)
        }

        private static func checkPreview(
            _ harness: E2EHarness, _ thumbnail: HostingPanel, _ root: NSView, _ context: ScenarioContext
        ) async throws {
            let screen = try context.unwrap("a display for the thumbnail", ScreenChoice.screen())
            let originalFrame = thumbnail.frame
            thumbnail.ignoresMouseEvents = true
            defer {
                thumbnail.setFrame(originalFrame, display: false)
                thumbnail.ignoresMouseEvents = false
            }
            thumbnail.center(on: screen)
            let foreground = try await E2EForegroundFixture.start(context)
            defer { foreground.requestStop() }
            defer { harness.features.capture.cancel() }

            let model = harness.features.quickActions
            let ui = harness.quickActionsUI
            let capture = try context.unwrap("the current capture", model.capture)
            try await model.openPreview()
            try context.require(
                "the expanded raster is ready before its native window opens",
                model.expandedPreview != nil && ui.previewPanel == nil)
            harness.app.perform(.captureRegion)
            try context.require("selection starts before presentation", harness.features.capture.state == .selecting)
            harness.features.capture.cancel()
            try context.require(
                "a preview that had not opened stays closed after canceling selection",
                await E2EWait.until { model.canOpenPreview && thumbnail.isVisible && ui.previewPanel == nil })
            await E2ESnapshot.settle(root)

            try E2EAccessibilityControl.pressCheckingEffect("quickActions.preview", in: root, context)
            try context.require(
                "Preview opens a visible panel", await E2EWait.until { ui.previewPanel?.isVisible == true })
            let panel = try context.unwrap("the expanded preview panel", ui.previewPanel)
            panel.ignoresMouseEvents = true
            panel.appearance = NSAppearance(named: .aqua)
            let previewRoot = try context.unwrap("expanded preview content", panel.contentView)
            await E2ESnapshot.settle(previewRoot)
            let (image, raster) = try previewRaster(in: previewRoot, context)
            let small = try context.unwrap("the thumbnail raster for comparison", capture.preview)
            context.check(
                "the expanded raster is larger without upsampling",
                raster.width > small.width && raster.height > small.height
                    && raster.width == Int(SyntheticDesktop.notesWindow.width * 2)
                    && raster.height == Int(SyntheticDesktop.notesWindow.height * 2)
                    && max(raster.width, raster.height) <= 1600)
            context.check(
                "the panel fits the thumbnail display and keeps its window policy",
                panel.screen == thumbnail.screen && screen.visibleFrame.contains(panel.frame)
                    && panel.styleMask.contains(.nonactivatingPanel)
                    && panel.collectionBehavior == thumbnail.collectionBehavior && panel.level == thumbnail.level)
            context.check(
                "the full image fits inside the preview chrome",
                previewRoot.bounds.insetBy(dx: 1, dy: 1).contains(previewRoot.convert(image.bounds, from: image)))
            checkPreviewForeground(panel, thumbnail, foreground, context)

            let closeName = try E2EAccessibilityControl.name(for: "quickActions.closePreview", in: previewRoot, context)
            context.check(
                "the preview has a labelled Close action", closeName == String(localized: "Close", table: "Editor"))
            context.snapshot(previewRoot, shot: "expanded-preview")
            await context.darkCompanion(
                previewRoot, in: panel, shot: "expanded-preview", surface: "expanded capture preview",
                excluding: [image])

            harness.app.perform(.captureRegion)
            try context.require(
                "starting a capture hides both surfaces",
                harness.features.capture.state == .selecting && !panel.isVisible && !thumbnail.isVisible,
                "selecting=\(harness.features.capture.state == .selecting) "
                    + "previewVisible=\(panel.isVisible) thumbnailVisible=\(thumbnail.isVisible)")
            harness.features.capture.cancel()
            try context.require(
                "cancel restores the same preview and thumbnail",
                await E2EWait.until { panel.isVisible && thumbnail.isVisible && ui.previewPanel === panel })
            checkPreviewForeground(panel, thumbnail, foreground, context)
            panel.makeKey()
            try context.require(
                "the preview can be focused while the owned app stays foreground",
                await E2EWait.until { panel.isKeyWindow })
            try pressEscape(in: panel, foreground, context)
            try context.require(
                "Escape from the preview closes only the expanded panel",
                await E2EWait.until { ui.previewPanel == nil && thumbnail.isVisible && model.capture?.id == capture.id }
            )
            context.check(
                "closing the focused preview leaves the owned app foreground",
                !panel.isKeyWindow
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier,
                previewFocusDetail(panel, thumbnail, foreground))

            if !thumbnail.isKeyWindow { thumbnail.makeKey() }
            try context.require(
                "the thumbnail can be focused while the owned app stays foreground",
                await E2EWait.until {
                    thumbnail.isKeyWindow
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier
                })
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.preview", in: root, context)
            try context.require(
                "the same capture can be previewed again", await E2EWait.until { ui.previewPanel != nil })
            context.check(
                "opening the preview leaves key focus in the thumbnail",
                thumbnail.isKeyWindow && ui.previewPanel?.isKeyWindow == false)
            try pressEscape(in: thumbnail, foreground, context)
            try context.require(
                "Escape from the thumbnail closes only the expanded panel",
                await E2EWait.until { ui.previewPanel == nil && thumbnail.isVisible && model.capture?.id == capture.id }
            )
            context.check(
                "Escape keeps the thumbnail key and the other app foreground",
                thumbnail.isKeyWindow
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier,
                previewFocusDetail(panel, thumbnail, foreground))
            await foreground.stop(context)
        }

        private static func previewRaster(in root: NSView, _ context: ScenarioContext) throws -> (NSImageView, CGImage)
        {
            let image = try context.unwrap(
                "expanded preview image view", EditorWindowController.first(NSImageView.self, in: root))
            let raster = try context.unwrap(
                "the expanded preview raster", image.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return (image, raster)
        }

        private static func checkMaskedPreview(
            _ harness: E2EHarness, _ store: ImageStore, _ context: ScenarioContext
        ) async throws {
            let secret = FixtureRect(x: 160, y: 140, width: 720, height: 100)
            let pair = try SecretPairFixture.make(width: 1200, height: 500, secret: secret, seed: 17)
            let mask = Rect<DocumentSpace>(
                x: Double(secret.x), y: Double(secret.y), width: Double(secret.width), height: Double(secret.height))
            let model = harness.features.quickActions
            let ui = harness.quickActionsUI
            let plan = harness.features.export.automaticExportPlan()
            defer {
                harness.features.capture.cancel()
                ui.dismiss()
            }

            func preview(_ image: CGImage, masked: Bool, duringSelection: Bool = false) async throws -> DecodedPixels {
                let input = try ImageDecoder.decode(E2EDrawing.png(image))
                let asset = await store.insert(input, origin: .pasted)
                var document = Document(asset: asset)
                document.presentation = Presentation(padding: 280, aspect: .landscape16x9)
                var session = DocumentSession(document: document)
                if masked { try session.addSecureMask(covering: mask) }
                if duringSelection {
                    harness.app.perform(.captureRegion)
                    try context.require("a new region selection starts", harness.features.capture.state == .selecting)
                }
                _ = await model.present(session, after: plan)
                if duringSelection {
                    await E2ESnapshot.settle(nil)
                    context.check(
                        "a thumbnail completed during selection stays hidden", model.isShown && ui.panel == nil)
                    harness.features.capture.cancel()
                }
                try context.require(
                    "a framed fixture shows its thumbnail outside selection",
                    await E2EWait.until { ui.panel?.isVisible == true })
                let root = try context.unwrap("framed thumbnail content", ui.panel?.contentView)
                await E2ESnapshot.settle(root)
                try E2EAccessibilityControl.pressCheckingEffect("quickActions.preview", in: root, context)
                try context.require(
                    "the framed preview opens", await E2EWait.until { ui.previewPanel?.isVisible == true })
                let panel = try context.unwrap("the framed preview panel", ui.previewPanel)
                panel.ignoresMouseEvents = true
                let content = try context.unwrap("framed preview content", panel.contentView)
                await E2ESnapshot.settle(content)
                let (_, raster) = try previewRaster(in: content, context)
                let pixels = try E2EActions.decode(E2EDrawing.png(raster), "expanded framed preview", context)
                try E2EAccessibilityControl.pressCheckingEffect("quickActions.closePreview", in: content, context)
                try context.require(
                    "the Close control preserves the thumbnail",
                    await E2EWait.until { ui.previewPanel == nil && ui.panel?.isVisible == true })
                ui.dismiss()
                return pixels
            }

            let maskedA = try await preview(pair.a, masked: true, duringSelection: true)
            let maskedB = try await preview(pair.b, masked: true)
            let unmaskedA = try await preview(pair.a, masked: false)
            let unmaskedB = try await preview(pair.b, masked: false)
            context.check("RED-01 control: the unmasked preview rasters differ", unmaskedA != unmaskedB)
            context.check("RED-01: both masked preview rasters have identical pixels", maskedA == maskedB)
            context.check(
                "framing triggers the longest-side budget and keeps its ratio",
                maskedA.width >= 1500 && maskedA.width <= 1600 && maskedA.width * 9 == maskedA.height * 16,
                "\(maskedA.width)×\(maskedA.height)")
        }

        private static func pressEscape(
            in panel: HostingPanel, _ foreground: E2EForegroundFixture, _ context: ScenarioContext
        ) throws {
            try context.require(
                "Escape goes to the key panel while the owned app stays foreground",
                panel.isKeyWindow
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier)
            NSApp.sendEvent(
                try CaptureVisibilityScenarios.keyEvent(53, characters: "\u{1b}", windowNumber: panel.windowNumber))
        }

        private static func checkPreviewForeground(
            _ panel: HostingPanel, _ thumbnail: HostingPanel, _ foreground: E2EForegroundFixture,
            _ context: ScenarioContext
        ) {
            context.check(
                "the owned foreground app retains activation and Recortia does not take key",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier
                    && !NSApp.isActive && !panel.isKeyWindow && !thumbnail.isKeyWindow,
                previewFocusDetail(panel, thumbnail, foreground))
        }

        private static func previewFocusDetail(
            _ panel: HostingPanel, _ thumbnail: HostingPanel, _ foreground: E2EForegroundFixture
        ) -> String {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            return "foregroundMatches=\(frontmost == foreground.processIdentifier) recortiaActive=\(NSApp.isActive) "
                + "previewKey=\(panel.isKeyWindow) thumbnailKey=\(thumbnail.isKeyWindow) "
                + "hasKeyWindow=\(NSApp.keyWindow != nil)"
        }

        private static func checkPreviewReplacement(
            _ harness: E2EHarness, _ context: ScenarioContext
        ) async throws {
            let model = harness.features.quickActions
            let ui = harness.quickActionsUI
            defer { ui.dismiss() }
            let root = try await showThumbnail(harness, context)
            let held = try context.unwrap("the capture to replace", model.capture?.id)
            let thumbnail = try context.unwrap("the thumbnail to replace", ui.panel)
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.preview", in: root, context)
            try context.require(
                "the preview to replace is visible", await E2EWait.until { ui.previewPanel?.isVisible == true })
            let preview = try context.unwrap("the preview to replace", ui.previewPanel)
            preview.ignoresMouseEvents = true
            // A successful capture also retires the prior preview when it routes to an editor.
            harness.settings.update { $0.afterCapture = .openEditor }
            defer {
                harness.settings.update { $0.afterCapture = .showQuickActions }
                harness.editors.closeAll()
            }
            _ = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check(
                "a successful replacement never restores the old panels",
                !thumbnail.isVisible && !preview.isVisible && ui.panel == nil && ui.previewPanel == nil
                    && model.capture?.id != held && model.expandedPreview == nil)
        }

        /// The thumbnail's Save under Automatic with report.png and report.jpg both present: the
        /// question names the file Automatic resolved to (its name only), Cancel keeps both, and
        /// Replace replaces exactly that file.
        private static func checkReplacement(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let ui = harness.quickActionsUI
            let folder = harness.output.workDirectory.appending(path: "thumbnail-replace", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let reportPNG = folder.appending(path: "report.png")
            let reportJPEG = folder.appending(path: "report.jpg")
            let originals = [reportPNG: Data("existing png".utf8), reportJPEG: Data("existing jpg".utf8)]
            for (url, bytes) in originals { try bytes.write(to: url) }
            let bookmark = harness.settings.preferences.preferredSaveFolderBookmark
            harness.settings.update { $0.preferredSaveFolderBookmark = nil }
            defer {
                harness.settings.update { $0.preferredSaveFolderBookmark = bookmark }
                ui.chooseSaveDestination = { nil }
                ui.confirmReplacement = { _ in false }
            }
            ui.chooseSaveDestination = { (reportPNG, .automatic) }
            var asked: [URL] = []
            var answer = false
            ui.confirmReplacement = {
                asked.append($0)
                return answer
            }
            _ = try await showThumbnail(harness, context)
            _ = await ui.save()
            let named = try context.unwrap("the thumbnail's Save asked about one file", asked.first)
            let question = MessagePresenter.makeReplacement(of: named).messageText
            context.check(
                "the thumbnail's question names the resolved file and no folder",
                asked.count == 1 && [reportPNG, reportJPEG].contains(named)
                    && question.contains("“\(named.lastPathComponent)”") && !question.contains(folder.path),
                question)
            context.check(
                "Cancel keeps both report files",
                originals.allSatisfy { (try? Data(contentsOf: $0.key)) == $0.value })
            answer = true
            asked = []
            _ = await ui.save()
            let kept = named == reportPNG ? reportJPEG : reportPNG
            context.check(
                "Replace replaces exactly the named file",
                asked == [named] && (try? Data(contentsOf: named)) != originals[named]
                    && (try? Data(contentsOf: kept)) == originals[kept],
                "\(asked.map(\.lastPathComponent))")
            harness.features.quickActions.dismiss()
        }

        private static func checkOptimizedSave(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let folder = harness.output.workDirectory.appending(
                path: "thumbnail-optimized", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let urls = ["png", "jpg"].map { folder.appending(path: "report.\($0)").standardizedFileURL }
            let original = Data("existing image".utf8)
            for url in urls { try original.write(to: url) }
            defer { harness.quickActionsUI.optimizedSaveDialogs = nil }

            var offered: OptimizedSaveDetails?
            var replacements: [URL] = []
            func answerReplacement(_ approved: Bool) {
                harness.quickActionsUI.optimizedSaveDialogs = (
                    chooseDestination: {
                        offered = $0
                        return folder.appending(path: "report.heic")
                    },
                    confirmReplacement: {
                        replacements.append($0)
                        return approved
                    }
                )
            }
            answerReplacement(false)
            let root = try await showThumbnail(harness, context)
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.saveOptimized", in: root, context)
            let model = harness.features.quickActions
            context.check(
                "the optimized replacement prompt can be declined",
                await E2EWait.until { replacements.count == 1 && !model.isActing })
            context.check(
                "declining optimized Replace keeps both files and the thumbnail",
                model.isShown && urls.allSatisfy { (try? Data(contentsOf: $0)) == original })

            answerReplacement(true)
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.saveOptimized", in: root, context)
            context.check(
                "optimized save finishes through the native thumbnail control",
                await E2EWait.until { replacements.count == 2 && model.capture == nil })
            let details = try context.unwrap("the prepared file's displayed details", offered)
            let destination = folder.appending(path: "report.\(details.format.fileExtension)").standardizedFileURL
            let encoded = try Data(contentsOf: destination)
            let source = try context.unwrap(
                "the written optimized image", CGImageSourceCreateWithData(encoded as CFData, nil))
            let image = try context.unwrap(
                "the decoded optimized image", CGImageSourceCreateImageAtIndex(source, 0, nil))
            context.check(
                "only the exact name confirmed in the optimized dialog was replaced",
                urls.contains(destination) && replacements == [destination, destination]
                    && urls.filter { $0 != destination }.allSatisfy { (try? Data(contentsOf: $0)) == original })
            context.check(
                "the optimized file matches the advertised codec, dimensions and byte count",
                CGImageSourceGetType(source) as String? == (details.format == .png ? "public.png" : "public.jpeg")
                    && image.width == details.pixelSize.width && image.height == details.pixelSize.height
                    && encoded.count == details.byteCount)
        }

        private static func checkOptimizedSaveDuringSelection(_ harness: E2EHarness, _ context: ScenarioContext)
            async throws
        {
            let export = harness.features.export
            let capture = harness.features.capture
            let model = harness.features.quickActions
            let ui = harness.quickActionsUI
            let gate = harness.exportGate
            let folder = harness.output.workDirectory.appending(
                path: "suspended-optimized", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer {
                gate.holdNextSnapshot = false
                gate.release()
                capture.cancel()
                ui.optimizedSaveDialogs = nil
                ui.dismiss()
            }

            let root = try await showThumbnail(harness, context)
            let thumbnail = try context.unwrap("the original thumbnail", ui.panel)
            let screen = try context.unwrap("a display for the thumbnail", ScreenChoice.screen())
            thumbnail.ignoresMouseEvents = true
            thumbnail.center(on: screen)
            let heldID = try context.unwrap("the original capture ID", model.capture?.id)
            var dialogsPresented = 0
            ui.optimizedSaveDialogs = (
                chooseDestination: { _ in
                    dialogsPresented += 1
                    return folder.appending(path: "late-save.png")
                },
                confirmReplacement: { _ in
                    dialogsPresented += 1
                    return true
                }
            )
            gate.holdNextSnapshot = true
            try E2EAccessibilityControl.pressCheckingEffect("quickActions.saveOptimized", in: root, context)
            try context.require("optimized encoding starts", await E2EWait.until { gate.isWaiting && model.isActing })

            harness.app.perform(.captureRegion)
            try context.require(
                "the new selection hides the original thumbnail while encoding waits",
                capture.state == .selecting && model.capture?.id == heldID && !thumbnail.isVisible)

            gate.release()
            try context.require(
                "the suspended optimized save releases its export slot",
                await E2EWait.until { !model.isActing && !export.isBusy })
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            context.check(
                "the suspended optimized save presents no dialog and writes no file",
                dialogsPresented == 0 && files.isEmpty)
            context.check(
                "the original capture remains held during selection",
                capture.state == .selecting && model.capture?.id == heldID)
        }

        private static func checkCopyText(_ harness: E2EHarness, _ store: ImageStore, _ context: ScenarioContext)
            async throws
        {
            let sample = try TextCorpus.render(
                id: "quick-actions-text", language: .portugueseBrazil, category: .prose,
                theme: .light, pointSize: 20, scale: 2, lines: RecognitionScenarios.ocrLines)
            // Warm up Vision before the thumbnail's timeout starts, as in the editor OCR scenario.
            _ = await RecognitionScenarios.visionDiagnosis(sample.image)
            let model = harness.features.quickActions
            let ui = harness.quickActionsUI
            let capture = harness.features.capture
            let recognition = harness.recognitionGate
            let board = harness.textPasteboard
            let originalMode = harness.settings.preferences.ocrTextMode
            defer {
                ui.dismiss()
                capture.cancel()
                recognition.reset()
                board.clearContents()
                harness.settings.update { $0.ocrTextMode = originalMode }
            }
            harness.settings.update { $0.ocrTextMode = .preserveLineBreaks }
            let asset = await store.insert(try ImageDecoder.decode(E2EDrawing.png(sample.image)), origin: .pasted)
            let session = DocumentSession(document: Document(asset: asset))
            _ = await model.present(session, after: harness.features.export.automaticExportPlan())
            try context.require(
                "the OCR fixture has a visible thumbnail", await E2EWait.until { ui.panel?.isVisible == true })
            let thumbnail = try context.unwrap("the OCR thumbnail", ui.panel)
            let root = try context.unwrap("the OCR thumbnail content", thumbnail.contentView)
            let screen = try context.unwrap("a display for the OCR thumbnail", ScreenChoice.screen())
            thumbnail.ignoresMouseEvents = true
            thumbnail.center(on: screen)
            await E2ESnapshot.settle(root)
            let control = "quickActions.copyText"
            let status = "quickActions.status"
            let heldID = model.capture?.id
            let expectedLabel = context.output.language == "pt-BR" ? "Copiar texto" : "Copy Text"
            let label = try E2EAccessibilityControl.name(for: control, in: root, context)
            context.check("Copy Text exposes the localized accessible name", label == expectedLabel, label)

            let earlier = "Conteúdo anterior"
            _ = harness.features.textClipboard.writePlainText(earlier)
            recognition.next = .failure
            try E2EAccessibilityControl.pressCheckingEffect(control, in: root, context)
            try context.require(
                "a failed Copy Text reports a status and keeps the previous clipboard",
                await E2EWait.until { !model.isActing && E2EAccessibilityControl.isPresent(status, in: root) }
                    && board.string(forType: .string) == earlier && model.capture?.id == heldID)

            let previousCompletions = recognition.lateCompletions
            recognition.next = .delay
            try E2EAccessibilityControl.pressCheckingEffect(control, in: root, context)
            try context.require("the Copy Text request waits in OCR", await E2EWait.until { recognition.isWaiting })
            harness.app.perform(.captureRegion)
            try context.require(
                "a new selection hides the OCR thumbnail", capture.state == .selecting && !thumbnail.isVisible)
            capture.cancel()
            try context.require(
                "canceling the selection restores the same thumbnail with an idle action slot",
                await E2EWait.until { thumbnail.isVisible && !model.isActing && model.capture?.id == heldID })
            recognition.release()
            try context.require(
                "the canceled Copy Text receives a late result",
                await E2EWait.until { recognition.lateCompletions == previousCompletions + 1 && model.canCopyText })
            await E2ESnapshot.settle(root)
            context.check(
                "a canceled Copy Text changes neither the clipboard nor status",
                board.string(forType: .string) == earlier && !E2EAccessibilityControl.isPresent(status, in: root))

            try E2EAccessibilityControl.pressCheckingEffect(control, in: root, context)
            try context.require(
                "native Copy Text writes real on-device recognition to the private pasteboard",
                await E2EWait.until(timeout: .seconds(40)) {
                    !model.isActing && board.string(forType: .string) != earlier
                })
            let copied = try context.unwrap("the recognized clipboard text", board.string(forType: .string))
            let lines = copied.split(separator: "\n")
            context.check(
                "Copy Text keeps the order, line breaks and Brazilian Portuguese accents",
                lines.count == 3 && lines[0].contains("Quarterly report") && lines[1].contains("Relatório trimestral")
                    && lines[2].contains("coração e informação"), copied)
            context.check(
                "the same thumbnail stays available after Copy Text", thumbnail.isVisible && model.capture?.id == heldID
            )
        }

        /// Captures the notes window and waits for its thumbnail; returns the panel's content.
        private static func showThumbnail(_ harness: E2EHarness, _ context: ScenarioContext) async throws -> NSView {
            try commitNotesRegion(harness, context)
            try context.require(
                "the thumbnail shows",
                await E2EWait.until { harness.features.quickActions.isShown && harness.quickActionsUI.panel != nil })
            let root = try context.unwrap("thumbnail content", harness.quickActionsUI.panel?.contentView)
            await E2ESnapshot.settle(root)
            return root
        }

        private static func commitNotesRegion(_ harness: E2EHarness, _ context: ScenarioContext) throws {
            let coordinator = harness.features.capture
            harness.app.perform(.captureRegion)
            try context.require(
                "Capture Region starts selecting", coordinator.state == .selecting, "\(coordinator.state)")
            try context.require(
                "committing the region is accepted",
                coordinator.commitRegion(
                    E2EActions.desktopRect(SyntheticDesktop.notesWindow), on: harness.capture.display))
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
