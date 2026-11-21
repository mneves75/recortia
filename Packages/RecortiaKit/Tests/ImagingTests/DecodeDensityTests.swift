import CoreGraphics
import Foundation
import ImageIO
import RecortiaFixtures
import Testing

@testable import Imaging

/// An opened or pasted image's pixels per point come from its own file (FR-06 automatic masking
/// sweeps at it), so the declared density is untrusted input read in the single decode.
@Suite("IO-01: declared pixel density")
struct DecodeDensityTests {
    private func png(dpi: Double?) throws -> Data {
        let image = try ChartFixture.colorChart(cell: 6)
        let properties: [CFString: Any] =
            dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] } ?? [:]
        return try ContainerCrafting.pngData(image, properties: properties)
    }

    @Test(
        "A PNG's declared density becomes its pixels per point, clamped to 1...3",
        arguments: [(144.0 as Double?, 2.0), (72, 1), (nil, 1), (10_000, 3)])
    func declaredDensity(dpi: Double?, expected: Double) throws {
        #expect(try ImageDecoder.decode(try png(dpi: dpi)).pointPixelScale == expected)
    }

    @Test("A density that is not a finite positive number reads as 1")
    func invalidDensity() {
        #expect(ImageDecoder.pointPixelScale(dpi: Double.nan) == 1)
        #expect(ImageDecoder.pointPixelScale(dpi: Double.infinity) == 1)
        #expect(ImageDecoder.pointPixelScale(dpi: -144.0) == 1)
        #expect(ImageDecoder.pointPixelScale(dpi: "144") == 1)
    }
}
