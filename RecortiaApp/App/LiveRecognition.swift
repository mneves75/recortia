import CoreGraphics
import Features
import Foundation
import Imaging

/// On-device Vision OCR (FR-08) and QR decoding. Recognition runs off the main actor inside
/// `TextRecognizer`; QR payloads are decoded as untrusted data, and nothing here opens or follows
/// them (OCR-02).
final class LiveRecognition: TextRecognitionService, QRDecodingService {
    private let recognizer = TextRecognizer()
    private let decoder = QRDecoder()

    func supportedLanguages() async -> [Locale.Language] {
        await recognizer.supportedLanguages()
    }

    func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
        try await recognizer.recognize(image, languages: languages)
    }

    func decode(_ image: CGImage) async throws -> [QRPayload] {
        try await decoder.decode(image)
    }
}
