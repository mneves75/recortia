#if DEBUG
    import AppKit
    import Domain
    import Features
    import Foundation
    import RecortiaFixtures

    /// Automatic masking of new captures (FR-06 amendment) through the real capture path,
    /// `AppModel`'s synchronous batch decision and the real editor window. Detection is scripted
    /// (`SyntheticSensitiveText`) over the synthetic desktop; nothing reads the screen.
    @MainActor
    enum AutoRedactionScenarios {
        /// The synthetic secret line in the captured notes window's document pixels.
        static var secretPixels: PixelRect {
            let (notes, secret, scale) = (
                SyntheticDesktop.notesWindow, SyntheticDesktop.secretRect, SyntheticDesktop.scale
            )
            return PixelRect(
                x: Int((secret.minX - notes.minX) * scale), y: Int((secret.minY - notes.minY) * scale),
                width: Int(secret.width * scale), height: Int(secret.height * scale))
        }

        /// The secret line's pale-yellow background (`SyntheticDesktop.image`), found nowhere else in
        /// the notes window. The whole desktop has look-alikes: 18 anti-aliased edge pixels of the white
        /// "4" on the bottom-right amber marker match too, so a full-desktop image is judged by
        /// `uncovered` over the planted rect instead.
        static func secretBackground(in pixels: DecodedPixels) -> Int {
            var count = 0
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let p = pixels.pixel(x: x, y: y)
                    if p.r > 245, (232...252).contains(p.g), (170...212).contains(p.b) { count += 1 }
                }
            }
            return count
        }

        static func autoRedaction(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let detection = harness.sensitiveText
            harness.settings.update {
                $0.afterCapture = .pin
                $0.autoRedactsSensitiveText = true
                $0.autoCopy = true
            }
            detection.regions = [secretPixels]
            detection.holds = true
            let copies = harness.clipboard.writeCount

            // Pending: the editor is open, shows no capture pixels and refuses exports.
            let editor = try await captureNotes(harness, context)
            let model = editor.model
            try context.require("detection runs on the new capture", await E2EWait.until { detection.isWaiting })
            context.check("the editor opens while masking is pending", model.isMaskingPending)
            // Decided at capture completion: this change belongs to the next capture.
            harness.settings.update {
                $0.autoRedactsSensitiveText = false
                $0.afterCapture = .openEditor
            }
            context.check(
                "the editor model holds no capture pixels while pending",
                model.baseImage == nil && model.calloutBaseImage == nil)
            let copy = await model.export(.copy)
            context.check(
                "Copy is refused while masking", copy == .failed(.maskingUnfinished) && !model.canStartExport, "\(copy)"
            )
            await model.pin()
            context.check("Pin is refused while masking", harness.features.pins.pins.isEmpty)
            model.setShowsOutputPreview(true)
            context.check("Output Preview is refused while masking", !model.showsOutputPreview)
            context.check("the automatic copy waits for the masks", harness.clipboard.writeCount == copies)
            let root = try context.unwrap("editor content", editor.contentRoot)
            let window = try context.unwrap("editor window", editor.window)
            let canvas = try context.unwrap("editor canvas", editor.canvasView)
            await E2ESnapshot.settle(root, for: .milliseconds(350))
            let shown = try E2EActions.decode(
                try E2ESnapshot.png(of: canvas, background: nil), "pending canvas", context)
            context.check(
                "the pending canvas shows none of the capture",
                secretBackground(in: shown) == 0 && shown.width > 0, "\(secretBackground(in: shown)) secret pixels")
            context.snapshot(root, shot: "pending")
            // The placeholder is app chrome, not user content, so the canvas is judged too.
            await context.darkCompanion(
                root, in: window, shot: "pending", surface: "masking placeholder", settle: .milliseconds(350))

            // Masked: one undo step, bound to the detected pixels; the frozen copy runs on it.
            detection.release()
            try context.require("masking finishes", await E2EWait.until { model.autoRedaction == .done })
            let asset = try context.unwrap("capture asset", model.document.layers.first?.assetID)
            context.check(
                "one opaque mask bound to the detected pixels, as one undo step",
                model.document.masks.map(\.sourceRegions) == [[asset: [secretPixels]]]
                    && model.document.masks.allSatisfy { $0.fill.isOpaque } && model.canUndo,
                "\(model.document.masks)")
            context.check(
                "the editor says how many items it masked", model.notice == .sensitiveTextMasked(1),
                "\(String(describing: model.notice))")
            try context.require(
                "the automatic copy ran after the masks landed",
                await E2EWait.until { harness.clipboard.writeCount == copies + 1 })
            context.check(
                "automatic masking success opens only the editor despite the Pin choice",
                harness.features.pins.pins.isEmpty && harness.quickActionsUI.panel == nil)
            let data = try context.unwrap("PNG on the pasteboard", harness.clipboard.pasteboard.data(forType: .png))
            let copied = try E2EActions.decode(data, "automatic copy", context)
            context.check(
                "the automatic copy is masked",
                secretBackground(in: copied) == 0 && copied.width == Int(SyntheticDesktop.notesWindow.width * 2),
                "\(secretBackground(in: copied)) secret pixels in \(copied.width)×\(copied.height)")
            await E2EActions.snapshotEditor(editor, context, shot: "masked")
            await E2EActions.darkEditor(editor, context, shot: "masked", surface: "masked capture")

            try context.require("the batch finished", await E2EWait.until { !harness.features.export.isBusy })
            let next = try await E2EActions.captureRegion(harness, SyntheticDesktop.notesWindow, context)
            context.check(
                "turning masking off during masking applies to the next capture",
                next.model.autoRedaction == .off && next.model.document.masks.isEmpty)
            try context.require(
                "the next capture's copy finished",
                await E2EWait.until { harness.clipboard.writeCount == copies + 2 && !harness.features.export.isBusy })

            // Failed: the capture is shown with a notice, its batch is skipped, manual export works.
            harness.settings.update {
                $0.autoRedactsSensitiveText = true
                $0.afterCapture = .pin
            }
            detection.holds = false
            detection.fails = true
            let messages = harness.messages.values.count
            let failed = try await captureNotes(harness, context)
            try context.require("masking fails closed", await E2EWait.until { failed.model.autoRedaction == .failed })
            context.check(
                "the skipped batch is reported in the editor",
                await E2EWait.until { failed.model.notice == .automaticExportFailed(.maskingUnfinished) },
                "\(String(describing: failed.model.notice))")
            context.check("no modal alert while the editor is open", harness.messages.values.count == messages)
            context.check(
                "nothing was masked or copied automatically",
                failed.model.document.masks.isEmpty && harness.clipboard.writeCount == copies + 2)
            context.check(
                "automatic masking failure opens only the editor despite the Pin choice",
                harness.features.pins.pins.isEmpty && harness.quickActionsUI.panel == nil)
            try await harness.editors.waitForBase(failed.model)
            await E2EActions.snapshotEditor(failed, context, shot: "failed")
            await E2EActions.darkEditor(failed, context, shot: "failed", surface: "failed masking notice")
            let manual = await failed.model.export(.copy)
            context.check(
                "manual export works after a failed masking",
                manual == .copied && harness.clipboard.writeCount == copies + 3, "\(manual)")
            // Positive control: the same capture unmasked does show the secret, so the masked
            // checks above can see it.
            let unmaskedData = try context.unwrap(
                "unmasked PNG on the pasteboard", harness.clipboard.pasteboard.data(forType: .png))
            let unmasked = try E2EActions.decode(unmaskedData, "manual copy", context)
            context.check(
                "the unmasked copy shows the secret", secretBackground(in: unmasked) > 0,
                "\(secretBackground(in: unmasked)) secret pixels")
        }

        /// A scrolling capture accepted from review and an image opened from a file get the same
        /// pending, masked and failed flow as a capture (FR-06 amendment, T2). Neither has an
        /// automatic export batch, so automatic copy stays untouched. Detection is scripted.
        static func sources(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let detection = harness.sensitiveText
            harness.settings.update {
                $0.autoRedactsSensitiveText = true
                $0.autoCopy = true
            }
            let copies = harness.clipboard.writeCount

            // Scrolling capture: a short synthetic page, stitched for real, then accepted.
            let fixture = ScrollPageFixture(seed: 0xA5C0, kind: .text, width: 480, viewportHeight: 360, pageHeight: 900)
            let offsets = fixture.forwardOffsets(steps: 90...170)
            let frames = offsets.enumerated().compactMap { fixture.frame(offset: $0.element, index: $0.offset) }
            try context.require("all fixture frames render", frames.count == offsets.count)
            harness.scrollFrames.load(frames, holdAfter: nil)
            let scroll = harness.features.scroll
            try context.require("the scrolling session begins", await scroll.begin(), "\(scroll.state)")
            let area = Rect<DesktopSpace>(x: 300, y: 160, width: 240, height: 180)
            scroll.chooseTarget(.region(area, display: harness.capture.display))
            scroll.start()
            try context.require(
                "every frame was offered",
                await E2EWait.until(timeout: .seconds(30)) {
                    harness.scrollFrames.isExhausted && harness.scrollFrames.isHolding
                })
            scroll.stop()
            try context.require(
                "the review shows the stitched page",
                await E2EWait.until(timeout: .seconds(10)) { scroll.state == .reviewing && scroll.preview != nil },
                "\(scroll.state)")
            let band = PixelRect(x: 0, y: 120, width: 480, height: 60)
            detection.regions = [band]
            detection.holds = true
            let scrolled = try await acceptPending(harness, context, "scrolling capture") { await scroll.accept() }
            let scrolledDocument = scrolled.model.document
            let scrollAsset = try context.unwrap(
                "stitched asset", scrolledDocument.layers.first.flatMap { scrolledDocument.assets[$0.assetID] })
            let recordedScale = if case .scrollCapture(_, let scale) = scrollAsset.origin { scale } else { 0.0 }
            context.check(
                "the stitched capture records its pixels per point", recordedScale == 2, "\(scrollAsset.origin)")
            try await settleMasked(scrolled, band: band, harness, context, "scrolling capture")
            let scrollCopy = try await copiedPixels(scrolled, harness, context, "scrolling capture")
            context.check(
                "the scrolling capture's copy is masked", uncovered(band, in: scrollCopy) == 0,
                "\(uncovered(band, in: scrollCopy)) uncovered pixels")
            scrolled.model.undo()
            try await harness.editors.waitForBase(scrolled.model)
            let undone = try await copiedPixels(scrolled, harness, context, "scrolling capture after Undo")
            context.check(
                "positive control: after Undo the band is exported", uncovered(band, in: undone) > 0,
                "\(uncovered(band, in: undone)) visible pixels")

            // Opened file: the synthetic desktop as a PNG, its secret line detected.
            let secret = PixelRect(
                x: Int(SyntheticDesktop.secretRect.minX * SyntheticDesktop.scale),
                y: Int(SyntheticDesktop.secretRect.minY * SyntheticDesktop.scale),
                width: Int(SyntheticDesktop.secretRect.width * SyntheticDesktop.scale),
                height: Int(SyntheticDesktop.secretRect.height * SyntheticDesktop.scale))
            let url = harness.output.workDirectory.appending(path: "auto-redaction-source.png")
            try E2EDrawing.png(try SyntheticDesktop.image()).write(to: url, options: .atomic)
            detection.regions = [secret]
            detection.holds = true
            let opened = try await acceptPending(harness, context, "opened image") {
                _ = await harness.features.importer.importImage(from: .file(url))
            }
            try await settleMasked(opened, band: secret, harness, context, "opened image")
            let openedCopy = try await copiedPixels(opened, harness, context, "opened image")
            // Every pixel of the planted line must be mask fill. The secret is drawn only inside
            // `secretRect` (its 3-pixel surround is the notes page's white).
            context.check(
                "the opened image's copy is masked", uncovered(secret, in: openedCopy) == 0,
                "\(uncovered(secret, in: openedCopy)) uncovered pixels of the planted line")
            await E2EActions.snapshotEditor(opened, context, shot: "opened-masked")

            // Failed: the opened image is shown with a notice and manual export shows the secret.
            detection.holds = false
            detection.fails = true
            let before = harness.editors.controllers.count
            _ = await harness.features.importer.importImage(from: .file(url))
            let failed = try await newEditor(harness, after: before, context, "failed opened image")
            try context.require(
                "masking the opened image fails closed", await E2EWait.until { failed.model.autoRedaction == .failed })
            context.check(
                "the editor says masking failed", failed.model.notice == .maskingFailed,
                "\(String(describing: failed.model.notice))")
            try await harness.editors.waitForBase(failed.model)
            let shown = try await copiedPixels(failed, harness, context, "failed opened image")
            context.check(
                "positive control: the unmasked copy shows the secret", uncovered(secret, in: shown) > 0,
                "\(uncovered(secret, in: shown)) visible pixels of the planted line")
            context.check(
                "neither source ran an automatic copy", harness.clipboard.writeCount == copies + 4,
                "\(harness.clipboard.writeCount - copies) copies, all manual")
        }

        /// Runs `open`, then requires the new editor to be pending with detection running and its
        /// exports refused.
        private static func acceptPending(
            _ harness: E2EHarness, _ context: ScenarioContext, _ name: String, _ open: () async -> Void
        ) async throws -> EditorWindowController {
            let before = harness.editors.controllers.count
            await open()
            let editor = try await newEditor(harness, after: before, context, name)
            let model = editor.model
            try context.require(
                "detection runs on the \(name)", await E2EWait.until { harness.sensitiveText.isWaiting })
            context.check(
                "the \(name) opens pending without its pixels", model.isMaskingPending && model.baseImage == nil)
            let copy = await model.export(.copy)
            context.check(
                "Copy of the \(name) is refused while masking", copy == .failed(.maskingUnfinished), "\(copy)")
            return editor
        }

        /// Releases detection and requires one opaque mask over `band`, bound to the asset.
        private static func settleMasked(
            _ editor: EditorWindowController, band: PixelRect, _ harness: E2EHarness, _ context: ScenarioContext,
            _ name: String
        ) async throws {
            let model = editor.model
            harness.sensitiveText.release()
            try context.require("masking the \(name) finishes", await E2EWait.until { model.autoRedaction == .done })
            let asset = try context.unwrap("\(name) asset", model.document.layers.first?.assetID)
            context.check(
                "the \(name) has one mask over the detected pixels, as one undo step",
                model.document.masks.map(\.sourceRegions) == [[asset: [band]]] && model.canUndo,
                "\(model.document.masks)")
            context.check(
                "the editor says how many items it masked in the \(name)", model.notice == .sensitiveTextMasked(1),
                "\(String(describing: model.notice))")
            try await harness.editors.waitForBase(model)
        }

        private static func newEditor(
            _ harness: E2EHarness, after count: Int, _ context: ScenarioContext, _ name: String
        ) async throws -> EditorWindowController {
            try context.require(
                "an editor opened for the \(name)", await E2EWait.until { harness.editors.controllers.count > count })
            return try context.unwrap("\(name) editor", harness.editors.controllers.last)
        }

        /// A manual Copy Image of `editor`, decoded from the pasteboard.
        private static func copiedPixels(
            _ editor: EditorWindowController, _ harness: E2EHarness, _ context: ScenarioContext, _ name: String
        ) async throws -> DecodedPixels {
            let outcome = await editor.model.export(.copy)
            try context.require("Copy of the \(name) succeeds", outcome == .copied, "\(outcome)")
            let data = try context.unwrap(
                "\(name) PNG on the pasteboard", harness.clipboard.pasteboard.data(forType: .png))
            return try E2EActions.decode(data, name, context)
        }

        /// Pixels in `rect` that are not the black mask fill.
        private static func uncovered(_ rect: PixelRect, in pixels: DecodedPixels) -> Int {
            var count = 0
            for y in max(0, rect.y)..<min(pixels.height, rect.y + rect.height) {
                for x in max(0, rect.x)..<min(pixels.width, rect.x + rect.width) {
                    let p = pixels.pixel(x: x, y: y)
                    if max(p.r, p.g, p.b) > 30 { count += 1 }
                }
            }
            return count
        }

        /// `E2EActions.captureRegion` without waiting for a base render, which a pending editor
        /// never starts.
        private static func captureNotes(_ harness: E2EHarness, _ context: ScenarioContext) async throws
            -> EditorWindowController
        {
            let coordinator = harness.features.capture
            let before = harness.editors.controllers.count
            harness.app.perform(.captureRegion)
            try context.require(
                "Capture Region starts selecting", coordinator.state == .selecting, "\(coordinator.state)")
            try context.require(
                "committing the region is accepted",
                coordinator.commitRegion(
                    E2EActions.desktopRect(SyntheticDesktop.notesWindow), on: harness.capture.display))
            try context.require(
                "an editor window opened", await E2EWait.until { harness.editors.controllers.count > before })
            return try context.unwrap("editor controller", harness.editors.controllers.last)
        }
    }
#endif
