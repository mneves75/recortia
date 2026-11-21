import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform

// OCR and QR (FR-08, OCR-02). Both read a fresh sanitized base render, never raw assets. Results
// are accepted only for the exact request identity; a later edit or redaction discards them. Text
// reaches the clipboard only through the explicit copy calls, and a QR link opens only through
// `openQRPayload`, which the view calls from a button click with the payload it displayed.
extension EditorModel {
    /// Recognizes text in the sanitized base; within `region` (document space) when given, else
    /// within the crop when one is set, else the whole canvas.
    public func recognizeText(in region: Rect<DocumentSpace>? = nil) async {
        guard !isClosed else { return }
        guard admitsAction(explaining: true) else { return }
        let request = UUID()
        let started = environment.clock.uptime()
        recognitionRequest = request
        recognition = .running
        recognizedResult = nil
        let identity = session.requestIdentity()
        let document = session.document
        let area = region ?? (document.crop != nil ? document.contentRect : nil)
        let outcome: Result<(OCRResult, AffineMap<SourcePixelSpace, DocumentSpace>), any Error>
        var unavailable: [String]?
        do {
            let base = try await environment.renderer.renderBase(document, scale: 1)
            let (image, toDocument) = try Self.crop(base, to: area, canvas: document.canvasSize)
            let (languages, missing) = await preferredLanguages()
            unavailable = missing
            let result = try await environment.textRecognition.recognize(image, languages: languages)
            outcome = .success((result, toDocument))
        } catch {
            outcome = .failure(error)
        }
        guard !isClosed, recognitionRequest == request else { return }
        recognitionRequest = nil
        guard session.accepts(identity) else {
            droppedResultCount += 1
            recognition = .idle
            post(.recognitionDiscarded)
            return
        }
        if let unavailable {
            unavailableRecognitionLanguages = unavailable
            if !unavailable.isEmpty { post(.recognitionLanguagesUnavailable) }
        }
        let duration = environment.clock.uptime() - started
        switch outcome {
        case .success((let result, let toDocument)):
            environment.diagnostics?.record(.textRecognitionFinished(lines: result.lines.count, duration: duration))
            guard !result.isEmpty else {
                recognition = .noText
                post(.noTextFound)
                return
            }
            recognizedResult = result
            let lines = result.lines.map {
                EditorOCRLine(text: $0.text, confidence: $0.confidence, box: toDocument.apply($0.box))
            }
            recognition = .recognized(lines: lines, languages: result.languages)
        case .failure:
            environment.diagnostics?.record(.textRecognitionFailed(duration: duration))
            recognition = .failed
            post(.recognitionFailed)
        }
    }

    public func recognizedText(mode: OCRTextMode) -> String? {
        guard case .recognized = recognition, let result = recognizedResult else { return nil }
        let text = result.text(mode: mode)
        return text.isEmpty ? nil : text
    }

    /// Copies recognized text as plain text. With no text the clipboard is left untouched.
    @discardableResult
    public func copyRecognizedText(mode: OCRTextMode) -> Bool {
        guard let text = recognizedText(mode: mode) else {
            post(.noTextFound)
            return false
        }
        return copyText(text, success: .textCopied)
    }

    public func clearRecognition() {
        recognitionRequest = nil
        recognition = .idle
        recognizedResult = nil
    }

    /// English and Portuguese when the system offers them, else whatever it supports (FR-08),
    /// with the primary language from Settings first when the system still offers it, plus the
    /// preferred codes the system lacks. The caller publishes those only for a current request.
    func preferredLanguages() async -> (languages: [Locale.Language], unavailable: [String]) {
        let supported = await environment.textRecognition.supportedLanguages()
        let codes = Set(supported.compactMap { $0.languageCode?.identifier })
        let unavailable = Self.preferredRecognitionLanguages.filter { !codes.contains($0) }
        let preferred = supported.filter {
            Self.preferredRecognitionLanguages.contains($0.languageCode?.identifier ?? "")
        }
        let languages = preferred.isEmpty ? supported : preferred
        environment.settings.forgetUnsupportedPrimaryRecognitionLanguage(supported: supported)
        guard let primary = environment.settings.preferences.primaryRecognitionLanguage,
            let first = supported.first(where: { $0.maximalIdentifier == primary })
        else { return (languages, unavailable) }
        return ([first] + languages.filter { $0.maximalIdentifier != primary }, unavailable)
    }

    static let preferredRecognitionLanguages = ["en", "pt"]

    // MARK: QR

    /// Decodes QR codes in the sanitized base. Payloads are shown as untrusted data only.
    public func decodeQR() async {
        guard !isClosed else { return }
        guard admitsAction(explaining: true) else { return }
        let request = UUID()
        let started = environment.clock.uptime()
        qrRequest = request
        qr = .running
        let identity = session.requestIdentity()
        let document = session.document
        let outcome: Result<[QRPayload], any Error>
        do {
            let base = try await environment.renderer.renderBase(document, scale: 1)
            outcome = .success(try await environment.qrDecoder.decode(base))
        } catch {
            outcome = .failure(error)
        }
        guard !isClosed, qrRequest == request else { return }
        qrRequest = nil
        guard session.accepts(identity) else {
            droppedResultCount += 1
            qr = .idle
            post(.recognitionDiscarded)
            return
        }
        let duration = environment.clock.uptime() - started
        switch outcome {
        case .success(let payloads):
            environment.diagnostics?.record(.qrDecodingFinished(codes: payloads.count, duration: duration))
            if payloads.isEmpty {
                qr = .noCode
                post(.noQRCodeFound)
            } else {
                qr = .decoded(payloads)
            }
        case .failure:
            environment.diagnostics?.record(.qrDecodingFailed(duration: duration))
            qr = .failed
            post(.recognitionFailed)
        }
    }

    public var qrPayloads: [QRPayload] {
        if case .decoded(let payloads) = qr { return payloads }
        return []
    }

    /// Whether the payload at `index` is a web link the policy allows opening after a click.
    public func canOpenQRPayload(at index: Int) -> Bool {
        guard qrPayloads.indices.contains(index), case .webURL(let url) = qrPayloads[index].kind else { return false }
        return ExternalLinkPolicy.canOpen(url)
    }

    /// Copies a payload's text. Binary payloads have no text and are not copied.
    @discardableResult
    public func copyQRPayload(at index: Int) -> Bool {
        guard qrPayloads.indices.contains(index), let text = qrPayloads[index].string, !text.isEmpty else {
            post(.copyFailed)
            return false
        }
        return copyText(text, success: .payloadCopied)
    }

    /// Opens an http(s) payload; call only from an explicit click, passing the payload the view
    /// displayed. If the payloads changed since (a new decode, a clear), nothing opens, so a click
    /// can never follow a link the user did not see. Everything else is refused.
    @discardableResult
    public func openQRPayload(_ displayed: QRPayload, at index: Int) -> Bool {
        guard canOpenQRPayload(at: index), qrPayloads[index] == displayed,
            case .webURL(let url) = qrPayloads[index].kind
        else {
            post(.linkNotAllowed)
            return false
        }
        return environment.links.open(url)
    }

    public func clearQR() {
        qrRequest = nil
        qr = .idle
    }

    /// Completed results belong to one revision; in-flight requests reject edits on arrival.
    func invalidateCompletedRecognition() -> Bool {
        var cleared = false
        switch recognition {
        case .recognized, .noText:
            clearRecognition()
            cleared = true
        case .idle, .running, .failed:
            break
        }
        switch qr {
        case .decoded, .noCode:
            clearQR()
            cleared = true
        case .idle, .running, .failed:
            break
        }
        return cleared
    }

    // MARK: Helpers

    func copyText(_ text: String, success: EditorNotice) -> Bool {
        let ok = environment.textClipboard.writePlainText(text)
        post(ok ? success : .copyFailed)
        return ok
    }

    enum CropError: Error { case empty }

    /// Crops a canvas-sized base to `area` (document space), returning the image and the map from
    /// its pixels back to document space (recognized boxes use it).
    static func crop(_ image: CGImage, to area: Rect<DocumentSpace>?, canvas: Size<DocumentSpace>) throws
        -> (CGImage, AffineMap<SourcePixelSpace, DocumentSpace>)
    {
        let sx = canvas.width > 0 ? Double(image.width) / canvas.width : 1
        let sy = canvas.height > 0 ? Double(image.height) / canvas.height : 1
        guard let area else { return (image, .scale(x: 1 / sx, y: 1 / sy)) }
        let pixels = Rect<SourcePixelSpace>(
            x: area.minX * sx, y: area.minY * sy, width: area.width * sx, height: area.height * sy)
        guard let covered = try PixelRect.covering(pixels, within: PixelSize(width: image.width, height: image.height)),
            let cropped = image.cropping(
                to: CGRect(x: covered.x, y: covered.y, width: covered.width, height: covered.height))
        else { throw CropError.empty }
        let toDocument = AffineMap<SourcePixelSpace, SourcePixelSpace>
            .translation(dx: Double(covered.x), dy: Double(covered.y))
            .then(AffineMap<SourcePixelSpace, DocumentSpace>.scale(x: 1 / sx, y: 1 / sy))
        return (cropped, toDocument)
    }
}
