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
    private let store: ImageStore
    private let pipeline: ExportPipeline

    /// A white image with `secrets` painted red, or another color when `green` is above 0.
    init(width: Int = 400, height: Int = 300, secrets: [FixtureRect], green: UInt8 = 0) async throws {
        let store = ImageStore()
        let info = await store.insert(
            try ImageDecoder.canonicalize(Self.image(width: width, height: height, secrets: secrets, green: green)),
            origin: .imported)
        self.store = store
        harness = EditorHarness(session: DocumentSession(document: Document(asset: info)))
        harness.assets.store = store
        pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
    }

    private init(harness: EditorHarness, store: ImageStore) {
        self.harness = harness
        harness.assets.store = store
        self.store = store
        pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
    }

    /// The same document in a new editor with no history, so Undo cannot reach its setup.
    func withoutHistory() -> SecretExport {
        SecretExport(harness: EditorHarness(session: DocumentSession(document: harness.model.document)), store: store)
    }

    init(width: Int = 400, height: Int = 300, secret: FixtureRect) async throws {
        try await self.init(width: width, height: height, secrets: [secret])
    }

    static func image(width: Int, height: Int, secrets: [FixtureRect], green: UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for secret in secrets {
            for y in secret.y..<secret.y + secret.height {
                for x in secret.x..<secret.x + secret.width {
                    let i = (y * width + x) * 4
                    bytes[i + 1] = green
                    bytes[i + 2] = 0
                }
            }
        }
        return try ChartFixture.image(width: width, height: height, premultipliedRGBA: bytes)
    }

    /// Adds an image layer on top, as a paste does, in one undo step.
    @discardableResult
    func addLayer(width: Int = 400, height: Int = 300, secrets: [FixtureRect], green: UInt8 = 0) async throws
        -> LayerID
    {
        let image = try Self.image(width: width, height: height, secrets: secrets, green: green)
        let info = await store.insert(try ImageDecoder.canonicalize(image), origin: .imported)
        let layer = ImageLayer(assetID: info.id)
        _ = harness.model.edit("Paste") { document in
            document.assets[info.id] = info
            document.layers.append(layer)
        }
        return layer.id
    }

    /// Imports an image through the editor's real import path (as a drop or paste does): it is
    /// decoded into this store and placed by `addImageLayer`.
    @discardableResult
    func importLayer(width: Int, height: Int, secrets: [FixtureRect], green: UInt8 = 0) async throws -> Bool {
        let png = try ContainerCrafting.pngData(
            Self.image(width: width, height: height, secrets: secrets, green: green))
        return await harness.model.addImageLayer(from: .droppedData(png))
    }

    /// Exported pixels anywhere that still show the secret's red.
    func secretPixels(in pixels: DecodedPixels) -> Int {
        secretPixels(in: pixels, FixtureRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
    }

    /// Exported pixels in `rect` that are not the black mask fill.
    func uncoveredPixels(in pixels: DecodedPixels, _ rect: FixtureRect) -> Int {
        var count = 0
        for y in max(0, rect.y)..<min(pixels.height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(pixels.width, rect.x + rect.width) {
                let p = pixels.pixel(x: x, y: y)
                if max(p.r, p.g, p.b) > 30 { count += 1 }
            }
        }
        return count
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
