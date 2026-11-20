import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

/// An editor over a real `ImageStore` image: white, with one pure-red secret patch. Exports go
/// through the real `ExportPipeline`, so a test can check that the secret stays covered in the
/// exported pixels, not only in the model.
@MainActor
struct SecretExport {
    let harness: EditorHarness
    private let pipeline: ExportPipeline

    init(width: Int = 400, height: Int = 300, secret: FixtureRect) async throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in secret.y..<secret.y + secret.height {
            for x in secret.x..<secret.x + secret.width {
                let i = (y * width + x) * 4
                bytes[i + 1] = 0
                bytes[i + 2] = 0
            }
        }
        let image = try ChartFixture.image(width: width, height: height, premultipliedRGBA: bytes)
        let store = ImageStore()
        let info = await store.insert(try ImageDecoder.canonicalize(image), origin: .imported)
        harness = EditorHarness(session: DocumentSession(document: Document(asset: info)))
        pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
    }

    func exported() async throws -> DecodedPixels {
        let snapshot = try await pipeline.snapshot(
            of: harness.model.session, options: ExportOptions(scale: 1), date: Date(timeIntervalSince1970: 0))
        return try ContainerInspector.decodePixels(snapshot.bytes)
    }

    /// Exported pixels in `rect` that still show the secret's red.
    func secretPixels(in pixels: DecodedPixels, _ rect: FixtureRect) -> Int {
        var count = 0
        for y in max(0, rect.y)..<min(pixels.height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(pixels.width, rect.x + rect.width) {
                let p = pixels.pixel(x: x, y: y)
                if p.r > 200 && p.g < 60 && p.b < 60 { count += 1 }
            }
        }
        return count
    }
}
