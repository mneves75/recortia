#if DEBUG
    import AppKit
    import Domain
    import Features
    import Imaging
    import RecortiaFixtures
    import Vision

    /// Local OCR with real Vision and QR decoding as untrusted data (FR-08, OCR-01/02).
    @MainActor
    enum RecognitionScenarios {
        /// Runs the recognizer's Vision request directly (warm-up, and to record why recognition
        /// failed: the app's recognizer maps every Vision error to one failure state).
        @concurrent
        static func visionDiagnosis(_ image: CGImage) async -> String {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR")]
            do {
                let observations = try await request.perform(on: image)
                return "succeeded with \(observations.count) lines"
            } catch {
                return "\(error)"
            }
        }

        static let ocrLines = [
            "Quarterly report ready for review",
            "Relatório trimestral pronto para revisão",
            "Ação, coração e informação",
        ]

        /// The text format chosen in the inspector belongs to this editor: switching tabs keeps the
        /// picker, and Copy Text copies that format, not the preference.
        private static func formatSurvivesTabs(
            _ harness: E2EHarness, _ controller: EditorWindowController, _ context: ScenarioContext
        ) async throws {
            let model = controller.model
            let root = try context.unwrap("OCR editor content", controller.contentRoot)
            let preferred = harness.settings.preferences.ocrTextMode
            let chosen = try context.unwrap(
                "a text format other than the preference",
                OCRTextMode.allCases.first {
                    $0 != preferred && model.recognizedText(mode: $0) != model.recognizedText(mode: preferred)
                })
            func showPicker() async -> Bool {
                await E2EActions.scrollInspector(controller, to: 1)
                await E2ESnapshot.settle(root)
                return E2EAccessibilityControl.isPresent("recognition.format", in: root)
            }
            try context.require("the inspector shows the text format picker", await showPicker())
            let offered = try await E2EAccessibilityControl.chooseFromMenu(
                EditorStrings.name(chosen), opening: "recognition.format", in: root, context)
            context.check(
                "the format picker offers every text format",
                offered.map(\.title) == OCRTextMode.allCases.map { EditorStrings.name($0) }, "\(offered)")
            await E2ESnapshot.settle(root)
            for tab in [0, 1] {
                try InspectorScenarios.chooseTab(tab, controller, root, context)
                await E2ESnapshot.settle(root)
            }
            try context.require("the format picker returns with the Image tab", await showPicker())
            let reopened = try await E2EAccessibilityControl.chooseFromMenu(
                nil, opening: "recognition.format", in: root, context)
            context.check(
                "the chosen text format survives switching tabs",
                reopened.filter(\.checked).map(\.title) == [EditorStrings.name(chosen)], "\(reopened)")
            await E2ESnapshot.settle(root)
            harness.textPasteboard.clearContents()
            try E2EAccessibilityControl.pressCheckingEffect("recognition.copyText", in: root, context)
            _ = await E2EWait.until(timeout: .seconds(2)) { harness.textPasteboard.string(forType: .string) != nil }
            context.check(
                "Copy Text copies the chosen format after switching tabs",
                harness.textPasteboard.string(forType: .string) == model.recognizedText(mode: chosen),
                "\(String(describing: harness.textPasteboard.string(forType: .string)?.debugDescription))")
        }

        static func ocrAndQR(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let sample: TextCorpus.Sample
            do {
                sample = try TextCorpus.render(
                    id: "e2e-ocr", language: .portugueseBrazil, category: .prose, theme: .light, pointSize: 20,
                    scale: 2, lines: ocrLines)
            } catch { throw E2EAbort("text corpus render: \(error)") }
            let controller = try await harness.openImported(sample.image, name: "ocr-en-pt.png")
            let model = controller.model
            // Vision loads its recognition models on first use, which on a busy machine has taken
            // 25-40 s and once failed outright; warm it up so the app path is measured warm.
            let warmStart = ContinuousClock.now
            let warmUp = await visionDiagnosis(sample.image)
            let warmElapsed = ContinuousClock.now - warmStart
            let started = ContinuousClock.now
            await model.recognizeText()
            let elapsed = ContinuousClock.now - started
            guard case .recognized(let lines, let languages) = model.recognition else {
                let cause = await visionDiagnosis(sample.image)
                try context.require(
                    "text is recognized", false,
                    "\(model.recognition) after \(elapsed); warm-up: \(warmUp) in \(warmElapsed); retry: \(cause)")
                return
            }
            context.check(
                "text is recognized", true,
                "app recognition \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds]))); Vision warm-up \(warmUp) in \(warmElapsed.formatted(.units(allowed: [.seconds, .milliseconds])))"
            )
            let text = lines.map(\.text).joined(separator: "\n")
            context.check(
                "Vision recognized \(lines.count) lines", lines.count == ocrLines.count, text.debugDescription)
            for word in [
                "Quarterly", "report", "review", "Relatório", "trimestral", "revisão", "coração", "informação",
            ] {
                context.check("recognized text contains “\(word)”", text.contains(word), text.debugDescription)
            }
            context.check(
                "English and Portuguese were requested",
                languages.contains { $0.hasPrefix("en") }
                    && languages.contains { $0.hasPrefix("pt") }, languages.joined(separator: ", "))
            let copiedText = model.copyRecognizedText(mode: .preserveLineBreaks)
            context.check("Copy Text succeeds", copiedText)
            context.check(
                "copied text went to the private text pasteboard",
                harness.textPasteboard.string(forType: .string)?.contains("Relatório") == true)
            await E2EActions.scrollInspector(controller, to: 1)
            await E2EActions.snapshotEditor(controller, context, shot: "ocr")
            try await formatSurvivesTabs(harness, controller, context)

            let fixtures: [QRFixture]
            do { fixtures = try QRFixture.all() } catch { throw E2EAbort("QR fixtures: \(error)") }
            let https = try context.unwrap("https fixture", fixtures.first { $0.name == "https" })
            let wifi = try context.unwrap("wifi fixture", fixtures.first { $0.name == "wifi" })
            let board = try E2EDrawing.row([https.image, wifi.image], margin: 48)
            let qrController = try await harness.openImported(board, name: "qr-https-wifi.png")
            let qrModel = qrController.model
            await qrModel.decodeQR()
            let payloads = qrModel.qrPayloads
            context.check("two QR payloads decode", payloads.count == 2, "\(payloads.count)")
            let expectedURL = URL(string: "https://example.com/path?q=1&r=two")
            context.check(
                "first payload is the https link",
                payloads.first.map { expectedURL.map(QRPayload.Kind.webURL) == $0.kind } == true,
                "\(payloads.first.map { "\($0.kind)" } ?? "none")")
            context.check(
                "second payload is Wi-Fi", payloads.last?.kind == .wifi,
                "\(payloads.last.map { "\($0.kind)" } ?? "none")")
            context.check(
                "payload bytes are exact",
                payloads.map(\.bytes) == https.expectedPayloads + wifi.expectedPayloads)
            context.check("the https link could be opened on request", qrModel.canOpenQRPayload(at: 0))
            context.check("the Wi-Fi payload cannot be opened", !qrModel.canOpenQRPayload(at: 1))
            context.check(
                "opening Wi-Fi is refused", payloads.count > 1 && !qrModel.openQRPayload(payloads[1], at: 1))
            context.check(
                "nothing was opened automatically", harness.links.requests.isEmpty, "\(harness.links.requests)")
            await E2EActions.scrollInspector(qrController, to: 1)
            await E2EActions.snapshotEditor(qrController, context, shot: "qr")
            // Reading the general pasteboard cannot show which app wrote it; assert the injected sink.
            context.check(
                "Copy Text used a private pasteboard, never the general one", harness.textPasteboard.name != .general,
                harness.textPasteboard.name.rawValue)
        }
    }
#endif
