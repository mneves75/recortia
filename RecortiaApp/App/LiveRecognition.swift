import CoreGraphics
import Domain
import Features
import Foundation
import Imaging

/// On-device Vision OCR (FR-08). Recognition runs off the main actor inside `TextRecognizer`.
final class LiveTextRecognition: TextRecognitionService {
    private let recognizer = TextRecognizer()

    func supportedLanguages() async -> [Locale.Language] {
        await recognizer.supportedLanguages()
    }

    func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
        try await recognizer.recognize(image, languages: languages)
    }
}

/// QR payloads are decoded as untrusted data; nothing here opens or follows them (OCR-02).
final class LiveQRDecoding: QRDecodingService {
    private let decoder = QRDecoder()

    func decode(_ image: CGImage) async throws -> [QRPayload] {
        try await decoder.decode(image)
    }
}

/// Holds the value-type stitcher in an actor so frame matching runs off the main actor.
private actor StitchEngine {
    private var stitcher = ScrollStitcher()

    func reset() { stitcher = ScrollStitcher() }

    func append(_ frame: CGImage, elapsed: Duration) -> (ScrollAppendResult, Int, PixelSize, Bool) {
        let result = stitcher.append(frame, elapsed: elapsed)
        return (result, stitcher.acceptedFrameCount, stitcher.outputSize, stitcher.endOfPageDetected)
    }

    func preview(maxHeight: Int) -> CGImage? { stitcher.preview(maxHeight: maxHeight) }

    func assemble() throws -> CGImage { try stitcher.assemble() }
}

final class LiveStitcher: ScrollStitchService {
    private var engine = StitchEngine()
    private(set) var acceptedFrameCount = 0
    private(set) var outputSize = PixelSize(width: 0, height: 0)
    private(set) var endOfPageDetected = false

    func reset() {
        engine = StitchEngine()
        acceptedFrameCount = 0
        outputSize = PixelSize(width: 0, height: 0)
        endOfPageDetected = false
    }

    func append(_ frame: CGImage, elapsed: Duration) async -> ScrollAppendResult {
        let current = engine
        let (result, count, size, ended) = await current.append(frame, elapsed: elapsed)
        // A reset during the await replaced the engine; its counters no longer apply.
        guard current === engine else { return result }
        acceptedFrameCount = count
        outputSize = size
        endOfPageDetected = ended
        return result
    }

    func preview(maxHeight: Int) async -> CGImage? {
        await engine.preview(maxHeight: maxHeight)
    }

    func assemble() async throws -> CGImage {
        try await engine.assemble()
    }
}

extension AppServices {
    /// The production composition root: one image store shared by import, render, and export.
    static func live() -> AppServices {
        let store = ImageStore()
        let capture = LiveCaptureService()
        return AppServices(
            capture: capture, screenPermission: LiveScreenPermission(), accessibility: LiveAccessibilityPermission(),
            assets: LiveImageAssets(store: store), input: LiveImageInput(), renderer: LiveRenderer(store: store),
            exporter: LiveExporter(store: store), clipboard: LiveClipboard(), files: LiveFiles(), drag: LiveDragSink(),
            folders: LiveSaveFolders(), textRecognition: LiveTextRecognition(), qrDecoder: LiveQRDecoding(),
            scrollFrames: LiveScrollFrames(), stitcher: LiveStitcher(), autoScroller: LiveAutoScroll(),
            loginItem: LiveLoginItem(), clock: SystemClock())
    }
}
