import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

/// The sanitizing renderer over a real store: the editor's base is what the person would export.
@MainActor
private final class SanitizingRenderer: RenderService {
    private let renderer: PrivacyRenderer

    init(store: ImageStore) { renderer = PrivacyRenderer(store: store) }

    func render(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.render(document, scale: scale)
    }

    func renderBase(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.renderBase(document, scale: scale)
    }
}

// Failure modes (FR-11, A-7): the copied text ignoring the chosen format or written without an
// explicit action; the format choice not remembered; darkest sampling reading outside its box,
// ignoring the capture's point scale, or reading the pixels a secure mask hides; contrast slots
// accepting translucent colours or surviving a redaction or close.
@Suite("Editor colour tools (FR-11, A-7)")
@MainActor
struct EditorColorToolsTests {
    /// A white image with `marks` (x, y, colour) as single opaque pixels.
    private static func marked(width: Int, height: Int, _ marks: [(Int, Int, RGBA)]) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for (x, y, color) in marks {
            let i = (y * width + x) * 4
            bytes.replaceSubrange(i..<i + 4, with: [color.r, color.g, color.b, 255])
        }
        return try ChartFixture.image(width: width, height: height, premultipliedRGBA: bytes)
    }

    private func harness(
        _ image: CGImage, origin: AssetOrigin = .imported, settings: SettingsStore? = nil
    ) async -> EditorHarness {
        let h = EditorHarness(
            session: EditorFixtures.session(width: image.width, height: image.height, origin: origin),
            settings: settings)
        h.renderer.baseImage = image
        await h.settle()
        h.model.selectTool(.colorPicker)
        return h
    }

    private func pick(_ h: EditorHarness, _ x: Double, _ y: Double) async {
        h.click(x, y)
        await h.model.colorPickTask?.value
    }

    @Test("Copy writes the picked colour in the preferred format, HEX by default, and the choice is remembered")
    func formatPreference() async throws {
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        let h = await harness(try ChartFixture.colorChart(cell: 8), settings: settings)
        #expect(!h.model.copyPickedColor(), "nothing picked")
        await pick(h, 28, 4)
        #expect(h.model.colorFormat == .hex)
        #expect(h.textClipboard.writes.isEmpty, "picking alone copies nothing")
        #expect(h.model.copyPickedColor())
        h.model.colorFormat = .swiftUI
        #expect(h.model.pickedColorText == "Color(red: 0.102, green: 0.169, blue: 0.235)")
        #expect(h.model.copyPickedColor())
        h.model.colorFormat = .android
        #expect(h.model.copyPickedColor())
        #expect(h.textClipboard.writes == ["#1A2B3C", "Color(red: 0.102, green: 0.169, blue: 0.235)", "0xFF1A2B3C"])
        #expect(h.model.notice == .colorCopied)
        #expect(settings.preferences.colorFormat == .android)
        let next = await harness(try ChartFixture.colorChart(cell: 8), settings: settings)
        #expect(next.model.colorFormat == .android, "a new editor uses the remembered format")

        h.model.close()
        h.model.colorFormat = .oklch
        #expect(settings.preferences.colorFormat == .android, "a closed editor changes no preference")
        #expect(!h.model.copyPickedColor())
    }

    @Test("Darkest sampling finds the darkest pixel in a 20-pixel box and leaves point sampling as it was")
    func darkestImported() async throws {
        let ink = RGBA(r: 16, g: 32, b: 48)
        let image = try Self.marked(width: 40, height: 40, [(14, 6, ink), (25, 10, .black)])
        let h = await harness(image)
        await pick(h, 10, 10)
        #expect(h.model.pickedColor?.color == .white)
        h.model.samplesDarkestPixel = true
        #expect(h.model.pickedColor == nil, "a different mode needs a new pick")
        await pick(h, 10, 10)
        // The box spans 0..<20: (14, 6) is inside, the black pixel at x 25 is not.
        #expect(h.model.pickedColor == EditorColorSample(x: 10, y: 10, color: ink))
        #expect(h.model.copyPickedColor())
        #expect(h.textClipboard.writes == ["#102030"])

        h.click(10, 10)
        let stale = h.model.colorPickTask
        h.model.samplesDarkestPixel = false
        await stale?.value
        #expect(h.model.pickedColor == nil, "a pick started in the old mode cannot install")
    }

    @Test("For a capture the darkest box is 20 points, so twice as many pixels at 2×")
    func darkestCapture() async throws {
        let image = try Self.marked(width: 40, height: 40, [(25, 10, .black)])
        let geometry = EditorFixtures.captureGeometry(width: 40, height: 40, scale: 2)
        let h = await harness(image, origin: .captured(geometry))
        h.model.samplesDarkestPixel = true
        await pick(h, 10, 10)
        #expect(h.model.pickedColor?.color == .black)
    }

    @Test("Contrast uses two opaque picks, and a redaction or close clears them")
    func contrastSlots() async throws {
        let grey = RGBA(r: 0x77, g: 0x77, b: 0x77)
        var bytes = [UInt8](repeating: 255, count: 20 * 10 * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) where (i / 4) % 20 < 10 {
            bytes.replaceSubrange(i..<i + 3, with: [grey.r, grey.g, grey.b])
        }
        bytes.replaceSubrange((5 * 20 + 19) * 4..<(5 * 20 + 19) * 4 + 4, with: [0, 0, 0, 0])
        let h = await harness(try ChartFixture.image(width: 20, height: 10, premultipliedRGBA: bytes))
        #expect(!h.model.usePickedColor(as: .text), "nothing picked")
        await pick(h, 2, 2)
        #expect(h.model.usePickedColor(as: .text))
        #expect(h.model.contrast == nil, "one colour is not a pair")
        await pick(h, 15, 2)
        #expect(h.model.usePickedColor(as: .background))
        #expect(h.model.contrastText == grey && h.model.contrastBackground == .white)
        let contrast = try #require(h.model.contrast)
        #expect(abs(contrast.ratio - 4.4781) < 0.0001)
        #expect(!contrast.passes(.aa, largeText: false) && contrast.passes(.aa, largeText: true))

        await pick(h, 19, 5)
        #expect(h.model.pickedColor?.color.a == 0)
        #expect(!h.model.usePickedColor(as: .background), "a transparent pick is refused")
        #expect(h.model.contrastBackground == .white)
        #expect(h.textClipboard.writes.isEmpty, "contrast never copies")

        h.model.selectTool(.redact)
        h.drag((0, 0), (4, 4))
        #expect(h.model.contrastText == nil && h.model.contrastBackground == nil)

        await h.settle()
        h.model.selectTool(.colorPicker)
        await pick(h, 15, 2)
        #expect(h.model.usePickedColor(as: .background))
        h.model.close()
        #expect(h.model.contrastBackground == nil && h.model.contrast == nil)
    }

    @Test("Point and darkest sampling over a secure mask read the mask's fill, never the hidden pixels")
    func samplingOverSecureMask() async throws {
        let store = ImageStore()
        let secret = FixtureRect(x: 15, y: 15, width: 10, height: 10)
        let info = await store.insert(
            try ImageDecoder.canonicalize(SecretExport.image(width: 40, height: 40, secrets: [secret], green: 0)),
            origin: .imported)
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        let renderer = SanitizingRenderer(store: store)
        let assets = FakeAssetService()
        assets.store = store
        let clock = ManualClock()
        let export = ExportCoordinator(
            exporter: FakeExportService(), clipboard: FakeClipboard(), files: FakeFileSink(), drag: FakeDragSink(),
            printer: FakePrinter(), folders: FakeSaveFolders(), clock: clock, settings: settings, upload: nil)
        let environment = EditorEnvironment(
            renderer: renderer, export: export, folders: FakeSaveFolders(),
            textRecognition: EditorFakeTextRecognition(), qrDecoder: EditorFakeQRDecoder(),
            sensitiveText: FakeSensitiveText(), assets: assets, input: FakeImageInput(),
            pins: PinsModel(renderer: renderer, settings: settings, export: export), textClipboard: FakeTextClipboard(),
            links: FakeLinkOpener(), settings: settings, clock: clock)
        let model = EditorModel(session: DocumentSession(document: Document(asset: info)), environment: environment)
        await model.settlePreviews()
        await drain()
        func pick(_ darkest: Bool) async -> RGBA? {
            model.samplesDarkestPixel = darkest
            model.selectTool(.colorPicker)
            model.pointerDown(at: Point(x: 20, y: 20))
            model.pointerUp(at: Point(x: 20, y: 20))
            await model.colorPickTask?.value
            return model.pickedColor?.color
        }
        let red = RGBA(r: 255, g: 0, b: 0)
        #expect(await pick(false) == red, "control: the secret is visible before the mask")
        #expect(await pick(true) == red, "control: the secret is the darkest pixel before the mask")

        let fill = RGBA(r: 200, g: 200, b: 200)
        model.setRedactionFill(fill)
        model.selectTool(.redact)
        model.pointerDown(at: Point(x: 5, y: 5))
        model.pointerDragged(to: Point(x: 35, y: 35))
        model.pointerUp(at: Point(x: 35, y: 35))
        #expect(model.document.masks.count == 1)
        await model.settlePreviews()
        await drain()
        #expect(model.isBaseCurrent)
        // The mask is lighter than the secret, so a darkest read of the raw pixels would find red.
        #expect(await pick(false) == fill)
        #expect(await pick(true) == fill)
        model.close()
    }
}
