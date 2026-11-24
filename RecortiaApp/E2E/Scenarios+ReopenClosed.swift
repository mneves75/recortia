#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging

    /// Reopen Closed Capture (B-6): closing an edited editor keeps its document in memory, and the
    /// command reopens it in a new editor as it was and empties the slot. The 10-minute lifetime is
    /// skipped on the runner's clock: then the command is disabled and the pixels are released. A
    /// capture whose automatic masking is still pending is not kept.
    @MainActor
    enum ReopenClosedScenarios {
        static func reopenClosed(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let app = harness.app
            let slot = harness.features.closedCapture
            let clock = harness.sensitiveText.clock
            let store = try context.unwrap(
                "the live image store", (harness.services.assets as? LiveImageAssets)?.store)
            context.check("Reopen Closed Capture is disabled with nothing closed", !app.isEnabled(.reopenClosedCapture))
            let item = try context.unwrap(
                "the menu bar has File › Reopen Closed Capture",
                EditorToolbarScenarios.viewCommand(AppCommand.reopenClosedCapture.title))
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            context.check(
                "Reopen Closed Capture shows ⇧⌘T",
                item.keyEquivalent.lowercased() == "t" && modifiers.contains(.command)
                    && (modifiers.contains(.shift) || item.keyEquivalent == "T"),
                "\(item.keyEquivalent.debugDescription) \(modifiers.rawValue)")

            // An edited image with a secure mask, closed through the discard question.
            let controller = try await harness.openImported(harness.desktop, name: "reopen-closed.png")
            let model = controller.model
            E2EActions.drag(model, .arrow, from: E2EActions.point(100, 700), to: E2EActions.point(500, 420))
            E2EActions.drag(model, .redact, from: E2EActions.point(600, 200), to: E2EActions.point(900, 320))
            try context.require(
                "the edits make the document dirty and add a secure mask",
                model.isDirty && !model.document.masks.isEmpty)
            let closed = model.session
            try await discard(controller, harness, "the edited editor", context, checksWording: true)
            context.check(
                "closing keeps the document and enables the command",
                !slot.isEmpty && app.isEnabled(.reopenClosedCapture))
            let held = await settledCount(store)

            // Reopen: a new editor with the document as it was; the slot is empty again.
            let before = harness.editors.controllers.count
            app.perform(.reopenClosedCapture)
            let reopened = try await E2EActions.waitForNewEditor(harness, after: before, context)
            context.check("one editor opened", harness.editors.controllers.count == before + 1)
            context.check(
                "the reopened document matches the closed one, masks included",
                reopened.model.document == closed.document && !reopened.model.document.masks.isEmpty)
            context.check(
                "its edits are still unexported and its undo history is gone",
                reopened.model.isDirty && !reopened.model.canUndo && !reopened.model.canRedo)
            context.check(
                "the privacy epoch carries over",
                reopened.model.session.privacyEpoch == closed.privacyEpoch && closed.privacyEpoch > 0)
            context.check(
                "reopening empties the slot and disables the command",
                slot.isEmpty && !app.isEnabled(.reopenClosedCapture))
            let reopenedCount = await settledCount(store)
            context.check(
                "the reopened editor uses the kept pixels; nothing was copied", reopenedCount == held,
                "\(reopenedCount) of \(held)")
            if let root = reopened.contentRoot {
                await E2ESnapshot.settle(root, for: .milliseconds(350))
                context.snapshot(root, shot: "reopened")
            }

            // Closed again, the document expires after 10 minutes of the runner's clock.
            try await discard(reopened, harness, "the reopened editor", context, checksWording: false)
            try context.require("closing the reopened editor keeps it again", !slot.isEmpty)
            clock.advance(by: ClosedCaptureSlot.lifetime - .seconds(5))
            try? await Task.sleep(for: .milliseconds(400))
            context.check(
                "shortly before 10 minutes it can still be reopened", app.isEnabled(.reopenClosedCapture))
            clock.advance(by: .seconds(5))
            context.check(
                "after 10 minutes the command is disabled",
                await E2EWait.until(timeout: .seconds(3)) { slot.isEmpty && !app.isEnabled(.reopenClosedCapture) })
            let assets = closed.document.assets.count
            let released = await waitForCount(store, held - assets)
            let remaining = await store.count
            context.check(
                "the expired document's pixels are released", released, "\(remaining), expected \(held - assets)")

            // Masking still pending: closing releases the capture and keeps nothing.
            defer { harness.settings.update { $0.autoRedactsSensitiveText = false } }
            harness.settings.update { $0.autoRedactsSensitiveText = true }
            harness.sensitiveText.holds = true
            let pending = try await captureNotes(harness, context)
            try context.require(
                "detection holds the new capture", await E2EWait.until { harness.sensitiveText.isWaiting })
            context.check("the capture's masking is pending", pending.model.isMaskingPending)
            pending.window?.performClose(nil)
            context.check(
                "a capture with pending masking is not kept",
                await E2EWait.until(timeout: .seconds(3)) { pending.model.isClosed }
                    && slot.isEmpty && !app.isEnabled(.reopenClosedCapture))
            harness.sensitiveText.release()
        }

        /// Closes `controller`'s edited editor and answers Discard to the sheet it asks.
        private static func discard(
            _ controller: EditorWindowController, _ harness: E2EHarness, _ label: String, _ context: ScenarioContext,
            checksWording: Bool
        ) async throws {
            let window = try context.unwrap("\(label) has a window", controller.window)
            window.ignoresMouseEvents = true
            PresenceScenarios.show(window, AppPresence.shared)
            window.performClose(nil)
            let sheet = try context.unwrap(
                "closing \(label) asks first",
                await E2EWait.until(timeout: .seconds(5)) { window.attachedSheet != nil } ? window.attachedSheet : nil)
            if checksWording {
                let expected =
                    context.output.language.hasPrefix("pt")
                    ? "Esta imagem tem alterações que não foram copiadas nem salvas; depois de fechá-la, você pode reabri-la por 10 minutos, até encerrar o Recortia."
                    : "This image has changes that were not copied or saved; after closing, you can reopen it for 10 minutes, until you quit."
                let texts = sheet.contentView.map { EditorWindowController.all(NSTextField.self, in: $0) } ?? []
                context.check(
                    "the close question says the image can be reopened for 10 minutes",
                    texts.contains { $0.stringValue == expected }, texts.map(\.stringValue).joined(separator: " | "))
            }
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            try context.require(
                "Discard closes \(label)",
                await E2EWait.until(timeout: .seconds(3)) { controller.model.isClosed && !window.isVisible })
        }

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
