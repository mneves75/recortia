import CoreGraphics
import Domain
import Foundation
import FramepinFixtures
import Imaging
import MacPlatform
import Testing

@testable import Features

// Fakes for the editor's services. Like Fakes.swift, none of them touches the screen, the
// pasteboard, the file system, or the network; suspending fakes hand control to the test.

/// Returns a configurable sanitized base; optionally suspends each render until the test resolves it.
@MainActor
final class EditorFakeRenderer: RenderService {
    /// Base image to return; nil makes renders a solid canvas-sized image.
    var baseImage: CGImage?
    var pending: Pending<Result<CGImage, TestError>>?
    var fails = false
    private(set) var baseRenders: [Document] = []
    private(set) var fullRenders: [Document] = []

    func render(_ document: Document, scale: Double) async throws -> CGImage {
        fullRenders.append(document)
        return try await produce(document)
    }

    func renderBase(_ document: Document, scale: Double) async throws -> CGImage {
        baseRenders.append(document)
        return try await produce(document)
    }

    private func produce(_ document: Document) async throws -> CGImage {
        if let pending { return try await pending.wait().get() }
        if fails { throw TestError() }
        if let baseImage { return baseImage }
        let width = max(1, Int(document.canvasSize.width.rounded()))
        let height = max(1, Int(document.canvasSize.height.rounded()))
        guard let image = makeImage(width: width, height: height) else { throw TestError() }
        return image
    }
}

@MainActor
final class EditorFakeTextRecognition: TextRecognitionService {
    var languages: [Locale.Language] = [
        Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR"),
        Locale.Language(identifier: "fr-FR"),
    ]
    var lines: [OCRResult.Line] = []
    var pending: Pending<Void>?
    var fails = false
    private(set) var recognizedSizes: [PixelSize] = []
    private(set) var requestedLanguages: [[Locale.Language]] = []

    func supportedLanguages() async -> [Locale.Language] { languages }

    func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
        recognizedSizes.append(PixelSize(width: image.width, height: image.height))
        requestedLanguages.append(languages)
        if let pending { await pending.wait() }
        if fails { throw TestError() }
        return OCRResult(lines: lines, revision: 3, languages: languages.map(\.minimalIdentifier))
    }
}

@MainActor
final class EditorFakeQRDecoder: QRDecodingService {
    var payloads: [QRPayload] = []
    private(set) var decodeCount = 0

    func decode(_ image: CGImage) async throws -> [QRPayload] {
        decodeCount += 1
        return payloads
    }
}

@MainActor
final class FakeTextClipboard: TextClipboardService {
    var fails = false
    private(set) var writes: [String] = []

    func writePlainText(_ text: String) -> Bool {
        guard !fails else { return false }
        writes.append(text)
        return true
    }
}

@MainActor
final class FakeLinkOpener: ExternalLinkOpenerService {
    private(set) var opened: [URL] = []

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return true
    }
}

enum EditorFixtures {
    static func session(
        width: Int = 400, height: Int = 300, origin: AssetOrigin = .imported, undoLimit: Int = 200
    ) -> DocumentSession {
        let asset = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: width, height: height), origin: origin)
        return DocumentSession(document: Document(asset: asset), undoLimit: undoLimit)
    }

    static func captureGeometry(width: Int, height: Int, scale: Double) -> CaptureGeometry {
        CaptureGeometry(
            source: .region(displayID: 1),
            desktopBounds: Rect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale),
            pointPixelScale: scale, pixelSize: PixelSize(width: width, height: height),
            capturedAt: Date(timeIntervalSince1970: 0))
    }
}

/// An editor over fakes, plus pointer helpers that go through the viewport like the canvas does.
@MainActor
final class EditorHarness {
    let renderer = EditorFakeRenderer()
    let exporter = FakeExportService()
    let clipboard = FakeClipboard()
    let files = FakeFileSink()
    let drag = FakeDragSink()
    let folders = FakeSaveFolders()
    let clock = ManualClock()
    let settings = SettingsStore(storage: MemoryPreferenceStorage())
    let recognizer = EditorFakeTextRecognition()
    let qr = EditorFakeQRDecoder()
    let assets = FakeAssetService()
    let input = FakeImageInput()
    let textClipboard = FakeTextClipboard()
    let links = FakeLinkOpener()
    let export: ExportCoordinator
    let pins: PinsModel
    let model: EditorModel

    init(session: DocumentSession = EditorFixtures.session(), configure: (EditorHarness) -> Void = { _ in }) {
        export = ExportCoordinator(
            exporter: exporter, clipboard: clipboard, files: files, drag: drag, folders: folders, clock: clock,
            settings: settings)
        pins = PinsModel(renderer: renderer, settings: settings)
        let environment = EditorEnvironment(
            renderer: renderer, export: export, folders: folders, textRecognition: recognizer, qrDecoder: qr,
            assets: assets, input: input, pins: pins, textClipboard: textClipboard, links: links, settings: settings)
        // Configure before the model's first render request.
        model = EditorModel(session: session, environment: environment)
        configure(self)
    }

    /// A pointer gesture from `a` to `b` in document space with `steps` intermediate moves.
    func drag(
        _ a: (Double, Double), _ b: (Double, Double), steps: Int = 8, modifiers: EditorModifiers = []
    ) {
        let start = Point<DocumentSpace>(x: a.0, y: a.1), end = Point<DocumentSpace>(x: b.0, y: b.1)
        model.pointerDown(at: start, modifiers: modifiers)
        for i in 1...max(1, steps) {
            let t = Double(i) / Double(max(1, steps))
            model.pointerDragged(
                to: Point(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), modifiers: modifiers)
        }
        model.pointerUp(at: end, modifiers: modifiers)
    }

    /// The same gesture, starting from view points and converted through the viewport (EDIT-02).
    func dragInView(_ a: Point<ViewSpace>, _ b: Point<ViewSpace>, steps: Int = 8) {
        let viewport = model.viewport
        model.pointerDown(at: viewport.documentPoint(a))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            model.pointerDragged(to: viewport.documentPoint(Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        }
        model.pointerUp(at: viewport.documentPoint(b))
    }

    func click(_ x: Double, _ y: Double, modifiers: EditorModifiers = []) {
        model.pointerDown(at: Point(x: x, y: y), modifiers: modifiers)
        model.pointerUp(at: Point(x: x, y: y), modifiers: modifiers)
    }

    func settle() async {
        await model.settlePreviews()
        await drain()
    }
}

extension Document {
    /// Geometry and style only, without random IDs, for comparing documents built separately.
    var annotationShapes: [Annotation.Kind] { annotations.map(\.kind) }
}
