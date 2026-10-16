import CoreGraphics
import Domain
import Foundation
import Imaging
import Testing

@testable import Features

// Failure modes (FR-08, OCR-02): recognized text copied without an explicit action; a no-text
// result clearing or replacing the clipboard; text "repaired" beyond whitespace modes; boxes not
// mapped back to document space for a region; QR payloads opened, copied, or followed
// automatically; non-web schemes (tel:, file:, javascript:, Wi-Fi, payment) opened on click;
// binary payloads copied as garbage text; unavailable languages assumed present.
@Suite("Editor OCR and QR (FR-08, OCR-02)")
@MainActor
struct EditorRecognitionTests {
    @Test("Recognized text offers raw, normalized, and line-preserving modes, copied only on request")
    func textModes() async {
        let h = EditorHarness()
        h.recognizer.lines = [
            OCRResult.Line(text: "  Olá,   café ", confidence: 0.9, box: Rect(x: 1, y: 2, width: 3, height: 4)),
            OCRResult.Line(text: "ação\tfinal", confidence: 0.8, box: Rect(x: 1, y: 8, width: 3, height: 4)),
        ]
        await h.model.recognizeText()
        #expect(h.textClipboard.writes.isEmpty)
        #expect(h.model.recognizedText(mode: .raw) == "  Olá,   café \nação\tfinal")
        #expect(h.model.recognizedText(mode: .preserveLineBreaks) == "Olá,   café\nação\tfinal")
        #expect(h.model.recognizedText(mode: .normalizedWhitespace) == "Olá, café ação final")
        #expect(h.model.copyRecognizedText(mode: .normalizedWhitespace))
        #expect(h.textClipboard.writes == ["Olá, café ação final"])
        #expect(h.model.notice == .textCopied)
    }

    @Test("English and Portuguese are requested when the system supports them")
    func languages() async {
        let h = EditorHarness()
        h.recognizer.lines = [OCRResult.Line(text: "x", confidence: 1, box: Rect(x: 0, y: 0, width: 1, height: 1))]
        await h.model.recognizeText()
        #expect(h.recognizer.requestedLanguages.last?.map(\.minimalIdentifier) == ["en", "pt"])
        #expect(h.model.unavailableRecognitionLanguages.isEmpty)
        h.recognizer.languages = [Locale.Language(identifier: "ja-JP")]
        await h.model.recognizeText()
        #expect(h.recognizer.requestedLanguages.last?.map(\.minimalIdentifier) == ["ja"])
        // FR-08: report unavailable language support instead of assuming it.
        #expect(h.model.unavailableRecognitionLanguages == ["en", "pt"])
        #expect(h.model.notice == .recognitionLanguagesUnavailable)
    }

    @Test("Region OCR crops the sanitized base and maps boxes back to document space")
    func regionBoxes() async throws {
        let h = EditorHarness()
        h.recognizer.lines = [OCRResult.Line(text: "id", confidence: 1, box: Rect(x: 10, y: 5, width: 20, height: 8))]
        await h.model.recognizeText(in: Rect(x: 100.5, y: 50, width: 60, height: 40))
        #expect(h.recognizer.recognizedSizes == [PixelSize(width: 61, height: 40)])
        guard case .recognized(let lines, _) = h.model.recognition else {
            Issue.record("not recognized")
            return
        }
        #expect(lines.map(\.box) == [Rect(x: 110, y: 55, width: 20, height: 8)])
    }

    @Test("With a crop set, OCR reads only the cropped area")
    func ocrUsesCrop() async {
        let h = EditorHarness()
        h.model.setCrop(Rect(x: 20, y: 30, width: 100, height: 50))
        await h.model.recognizeText()
        #expect(h.recognizer.recognizedSizes == [PixelSize(width: 100, height: 50)])
    }

    @Test("No text leaves the clipboard untouched and shows a nonblocking notice")
    func noText() async {
        let h = EditorHarness()
        h.recognizer.lines = [OCRResult.Line(text: "  ", confidence: 0.1, box: Rect(x: 0, y: 0, width: 1, height: 1))]
        await h.model.recognizeText()
        #expect(h.model.recognition == .noText)
        #expect(h.model.notice == .noTextFound)
        #expect(!h.model.copyRecognizedText(mode: .raw))
        #expect(h.textClipboard.writes.isEmpty)
    }

    @Test("A failed clipboard write reports failure")
    func copyFailure() async {
        let h = EditorHarness()
        h.recognizer.lines = [OCRResult.Line(text: "abc", confidence: 1, box: Rect(x: 0, y: 0, width: 1, height: 1))]
        await h.model.recognizeText()
        h.textClipboard.fails = true
        #expect(!h.model.copyRecognizedText(mode: .raw))
        #expect(h.model.notice == .copyFailed)
    }

    @Test(
        "Completed OCR and QR results expire on edits, undo, and redo",
        arguments: ["crop", "annotation", "blur", "undo", "redo"])
    func completedResultsRequireCurrentRevision(change: String) async {
        let h = EditorHarness()
        if change == "undo" || change == "redo" {
            h.model.setCrop(Rect(x: 20, y: 20, width: 100, height: 100))
            if change == "redo" { h.model.undo() }
        }
        h.recognizer.lines = [
            OCRResult.Line(text: "old text", confidence: 1, box: Rect(x: 0, y: 0, width: 4, height: 4))
        ]
        h.qr.payloads = [Self.payloads[1]]
        await h.model.recognizeText()
        await h.model.decodeQR()
        #expect(h.model.recognizedText(mode: .raw) == "old text")
        #expect(h.model.canOpenQRPayload(at: 0))
        let epoch = h.model.session.privacyEpoch
        switch change {
        case "crop": h.model.setCrop(Rect(x: 20, y: 20, width: 100, height: 100))
        case "annotation":
            h.model.selectTool(.arrow)
            h.drag((10, 10), (90, 90))
        case "blur":
            h.model.selectTool(.blur)
            h.drag((10, 10), (90, 90))
        case "undo": h.model.undo()
        default: h.model.redo()
        }
        #expect(h.model.session.privacyEpoch == epoch, "ordinary edits must not pretend to change secure masks")
        #expect(h.model.recognition == .idle)
        #expect(h.model.qrPayloads.isEmpty)
        #expect(!h.model.copyRecognizedText(mode: .raw))
        #expect(!h.model.copyQRPayload(at: 0))
        #expect(!h.model.openQRPayload(Self.payloads[1], at: 0))
        #expect(h.textClipboard.writes.isEmpty)
        #expect(h.links.opened.isEmpty)
    }

    @Test("Recognition failure is reported without touching the clipboard")
    func recognitionFailure() async {
        let h = EditorHarness()
        h.recognizer.fails = true
        await h.model.recognizeText()
        #expect(h.model.recognition == .failed)
        #expect(h.model.notice == .recognitionFailed)
        #expect(h.textClipboard.writes.isEmpty)
    }

    nonisolated static let payloads: [QRPayload] = [
        QRPayload(bytes: Data("hello".utf8), string: "hello", kind: .text),
        QRPayload(
            bytes: Data("https://example.com/a".utf8), string: "https://example.com/a",
            kind: .webURL(URL(string: "https://example.com/a")!)),
        QRPayload(bytes: Data("tel:123".utf8), string: "tel:123", kind: .otherScheme("tel")),
        QRPayload(bytes: Data("WIFI:S:x;;".utf8), string: "WIFI:S:x;;", kind: .wifi),
        QRPayload(bytes: Data("bitcoin:abc".utf8), string: "bitcoin:abc", kind: .payment),
        QRPayload(bytes: Data([0, 1, 2]), string: nil, kind: .binary),
        // A mislabeled "web" payload with a non-web scheme is still refused by the policy.
        QRPayload(
            bytes: Data("file:///etc/hosts".utf8), string: "file:///etc/hosts",
            kind: .webURL(URL(string: "file:///etc/hosts")!)),
    ]

    @Test("Decoding QR shows payloads and opens, copies, or follows nothing by itself")
    func qrDecodeIsPassive() async {
        let h = EditorHarness()
        h.qr.payloads = Self.payloads
        await h.model.decodeQR()
        #expect(h.model.qrPayloads == Self.payloads)
        #expect(h.links.opened.isEmpty)
        #expect(h.textClipboard.writes.isEmpty)
    }

    @Test("Only an http(s) payload opens, and only through the explicit open call")
    func qrOpenPolicy() async {
        let h = EditorHarness()
        h.qr.payloads = Self.payloads
        await h.model.decodeQR()
        let openable = Self.payloads.indices.filter { h.model.canOpenQRPayload(at: $0) }
        #expect(openable == [1])
        for index in Self.payloads.indices where index != 1 {
            #expect(!h.model.openQRPayload(Self.payloads[index], at: index))
            #expect(h.model.notice == .linkNotAllowed)
        }
        #expect(h.links.opened.isEmpty)
        #expect(h.model.openQRPayload(Self.payloads[1], at: 1))
        #expect(h.links.opened == [URL(string: "https://example.com/a")!])
        #expect(!h.model.openQRPayload(Self.payloads[1], at: 99))
    }

    @Test("Open Link opens only the payload that was displayed; replaced or cleared payloads open nothing")
    func qrOpenRequiresDisplayedPayload() async {
        let h = EditorHarness()
        h.qr.payloads = Self.payloads
        await h.model.decodeQR()
        let displayed = h.model.qrPayloads[1]

        // A new decode replaces the payload at the clicked index before the click lands.
        let replacement = QRPayload(
            bytes: Data("https://evil.example/".utf8), string: "https://evil.example/",
            kind: .webURL(URL(string: "https://evil.example/")!))
        h.qr.payloads = [Self.payloads[0], replacement]
        await h.model.decodeQR()
        #expect(h.model.canOpenQRPayload(at: 1))
        #expect(!h.model.openQRPayload(displayed, at: 1))
        #expect(h.model.notice == .linkNotAllowed)

        // Cleared results open nothing either.
        h.model.clearQR()
        #expect(!h.model.openQRPayload(displayed, at: 1))
        #expect(h.links.opened.isEmpty)
    }

    @Test("Copying a payload copies its text; binary payloads are not copied")
    func qrCopy() async {
        let h = EditorHarness()
        h.qr.payloads = Self.payloads
        await h.model.decodeQR()
        #expect(h.model.copyQRPayload(at: 2))
        #expect(!h.model.copyQRPayload(at: 5))
        #expect(h.textClipboard.writes == ["tel:123"])
        #expect(h.links.opened.isEmpty)
    }

    @Test("No QR code yields a notice and no state change elsewhere")
    func noQRCode() async {
        let h = EditorHarness()
        await h.model.decodeQR()
        #expect(h.model.qr == .noCode)
        #expect(h.model.notice == .noQRCodeFound)
        #expect(!h.model.canUndo)
    }
}
