import CoreGraphics
import Domain
import Foundation
import ImageIO
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

private let visionAvailable = ConditionTrait.enabled(
    if: ProcessInfo.processInfo.environment["RECORTIA_VISION_UNAVAILABLE"] != "1",
    "Vision text recognition is declared unavailable on this runner")

/// An opened file's declared DPI is untrusted (decisions.md, T2): a 1× image that claims 216 dpi
/// would be swept as 3 pixels per point, scaled up less, and its small text missed. Opened and
/// pasted images are swept at 1 pixel per point whatever their metadata says.
@Suite("Automatic masking ignores an opened image's declared density (FR-06)")
@MainActor
struct OpenedDensityRedactionTests {
    /// Whether every pixel of `rect` has one color: no glyph is visible there.
    private func isUniform(_ pixels: DecodedPixels, _ rect: CGRect) -> Bool {
        let first = pixels.pixel(x: Int(rect.minX), y: Int(rect.minY))
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let p = pixels.pixel(x: x, y: y)
                if p.r != first.r || p.g != first.g || p.b != first.b { return false }
            }
        }
        return true
    }

    @Test("RED: a 1× image claiming 216 dpi is swept at 1 px/pt and its small address is masked", visionAvailable)
    func declaredDensityNeverLowersTheSweep() async throws {
        // Small text at 1×: found only when the sweep scales it up.
        let screen = try SensitiveScreen.renderItem(
            "ana.souza@example.com", kind: .email, widthPoints: 600, heightPoints: 200, scale: 1, pointSize: 10,
            x: 40, top: 80)
        let item = try #require(screen.planted.first).rect
        let file = try ContainerCrafting.pngData(
            screen.image, properties: [kCGImagePropertyDPIWidth: 216, kCGImagePropertyDPIHeight: 216])
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/claims-216-dpi.png")

        let store = ImageStore()
        let importer = ImportHarness()
        importer.assets.store = store
        importer.input.files[url] = .success(file)
        _ = try await importer.coordinator.importImage(from: .file(url)).get()
        let session = try #require(importer.imported.last)
        let origin = try #require(session.document.assets.values.first?.origin)
        #expect(LiveSensitiveText.pixelsPerPoint(of: origin) == 1, "\(origin)")

        let h = EditorHarness()
        h.assets.store = store
        h.exporter.pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        let environment = EditorEnvironment(
            renderer: h.renderer, export: h.export, folders: h.folders, textRecognition: h.recognizer,
            qrDecoder: h.qr, sensitiveText: LiveSensitiveText(store: store), assets: h.assets, input: h.input,
            pins: h.pins, textClipboard: h.textClipboard, links: h.links, settings: h.settings, clock: h.clock)
        let model = EditorModel(session: session, environment: environment, autoRedacts: true)
        defer { model.close() }
        // The deadline runs on the harness's manual clock, so only Vision decides here.
        let clock = ContinuousClock()
        let start = clock.now
        while model.isMaskingPending, clock.now - start < .seconds(60) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.autoRedaction == .done)
        let covered = model.document.masks.map {
            CGRect(
                x: $0.outputRect.minX, y: $0.outputRect.minY, width: $0.outputRect.width, height: $0.outputRect.height)
        }
        #expect(covered.contains { $0.contains(item) }, "no mask covers \(item): \(covered)")

        await model.settlePreviews()
        #expect(await model.export(.copy) == .copied)
        let copied = try ContainerInspector.decodePixels(try #require(h.clipboard.writes.last).bytes)
        #expect(isUniform(copied, item), "the exported address shows no glyph")
    }
}
