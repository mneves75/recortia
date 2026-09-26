import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// A store, renderer, and export pipeline wired together for one test.
struct ImagingHarness {
    let store = ImageStore()
    var renderer: PrivacyRenderer { PrivacyRenderer(store: store) }
    var pipeline: ExportPipeline { ExportPipeline(renderer: renderer) }

    func add(_ image: CGImage, origin: AssetOrigin = .imported) async throws -> ImageAssetInfo {
        let decoded = try ImageDecoder.canonicalize(image)
        return await store.insert(decoded, origin: origin)
    }

    func export(_ session: DocumentSession, _ options: ExportOptions = ExportOptions()) async throws -> ShareSnapshot {
        try await pipeline.snapshot(of: session, options: options, date: fixedExportDate)
    }
}

let fixedExportDate = Date(timeIntervalSince1970: 1_790_000_000)

func pixels(_ image: CGImage) throws -> DecodedPixels { try ContainerInspector.pixels(of: image) }

func decoded(_ snapshot: ShareSnapshot) throws -> DecodedPixels { try ContainerInspector.decodePixels(snapshot.bytes) }

extension FixtureRect {
    var documentRect: Rect<DocumentSpace> {
        Rect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }

    var sourceRect: Rect<SourcePixelSpace> {
        Rect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }
}

extension ChartFixture.Color {
    var rgba: RGBA { RGBA(r: r, g: g, b: b, a: a) }

    /// Channel-wise distance to another straight color.
    func distance(to other: ChartFixture.Color) -> Int {
        max(
            abs(Int(r) - Int(other.r)), abs(Int(g) - Int(other.g)), abs(Int(b) - Int(other.b)),
            abs(Int(a) - Int(other.a)))
    }
}

extension DecodedPixels {
    /// Straight-alpha color at a pixel (these buffers are premultiplied).
    func straight(x: Int, y: Int) -> ChartFixture.Color {
        let p = pixel(x: x, y: y)
        guard p.a > 0, p.a < 255 else { return p }
        func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + Int(p.a) / 2) / Int(p.a))) }
        return ChartFixture.Color(un(p.r), un(p.g), un(p.b), p.a)
    }
}

/// Distance helper for straight colors built from literals.
func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> ChartFixture.Color {
    ChartFixture.Color(r, g, b, a)
}
