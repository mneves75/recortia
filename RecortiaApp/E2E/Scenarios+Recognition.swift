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

        static func ocrAndQR(_ harness: E2EHarness, _ context: ScenarioContext) async throws {
            let generalBefore = NSPasteboard.general.changeCount
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
            context.check("Copy Text succeeds", model.copyRecognizedText(mode: .preserveLineBreaks))
            context.check(
                "copied text went to the private text pasteboard",
                harness.textPasteboard.string(forType: .string)?.contains("Relatório") == true)
            await E2EActions.scrollInspector(controller, to: 0.55)
            await E2EActions.snapshotEditor(controller, context, shot: "ocr")

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
            await E2EActions.scrollInspector(qrController, to: 0.55)
            await E2EActions.snapshotEditor(qrController, context, shot: "qr")
            context.check(
                "the general pasteboard was never written", NSPasteboard.general.changeCount == generalBefore,
                "changeCount \(generalBefore) → \(NSPasteboard.general.changeCount)")
        }
    }
#endif
