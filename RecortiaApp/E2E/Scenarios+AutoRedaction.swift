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

        /// The secret line's pale-yellow background (`SyntheticDesktop.image`), found nowhere else.
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
            harness.settings.update { $0.autoRedactsSensitiveText = false }
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
            harness.settings.update { $0.autoRedactsSensitiveText = true }
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
