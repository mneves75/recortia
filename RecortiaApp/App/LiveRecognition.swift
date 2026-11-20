import CoreGraphics
import Domain
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

/// Automatic masking's detector (FR-06 amendment): the pattern sweep over a stored capture. The
/// pixels are read inside Imaging; this adapter sees only the rectangles it returns.
final class LiveSensitiveText: SensitiveTextService {
    private let store: ImageStore
    private let scanner = SensitiveTextScanner()
    private static let languages = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR")]

    init(store: ImageStore) {
        self.store = store
    }

    func sensitiveRegions(in asset: ImageAssetInfo) async throws -> [PixelRect] {
        let pixelsPerPoint: Double =
            if case .captured(let geometry) = asset.origin { geometry.pointPixelScale } else { 1 }
        let regions = try await scanner.sensitiveRegions(
            of: asset.id, in: store, pixelsPerPoint: pixelsPerPoint, languages: Self.languages)
        // The scanner returns whole-pixel rectangles; rounding only drops floating-point noise.
        return regions.map {
            PixelRect(
                x: Int($0.rect.minX.rounded()), y: Int($0.rect.minY.rounded()), width: Int($0.rect.width.rounded()),
                height: Int($0.rect.height.rounded()))
        }
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
    static func live(settings: SettingsStore) -> AppServices {
        let store = ImageStore()
        let capture = LiveCaptureService()
        let github = LiveGitHubUpload()
        let scrollFrames = LiveScrollFrames()
        let recognition = LiveRecognition()
        return AppServices(
            githubUpload: github, githubCredentials: github,
            capture: capture, screenPermission: LiveScreenPermission(), accessibility: LiveAccessibilityPermission(),
            assets: LiveImageAssets(store: store), input: LiveImageInput(), renderer: LiveRenderer(store: store),
            exporter: LiveExporter(store: store), clipboard: LiveClipboard(), files: LiveFiles(), drag: LiveDragSink(),
            folders: LiveSaveFolders.storing(in: settings), textRecognition: recognition,
            qrDecoder: recognition, sensitiveText: LiveSensitiveText(store: store),
            scrollFrames: scrollFrames, stitcher: LiveStitcher(), autoScroller: LiveAutoScroll(frames: scrollFrames),
            loginItem: LiveLoginItem(), clock: SystemClock())
    }
}
