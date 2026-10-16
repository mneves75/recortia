import CoreGraphics
import Domain
import Foundation
import Testing

@testable import Imaging

@Suite("RenderRaster: bounded pixel access")
struct RenderRasterTests {
    /// A 4x4 raster whose pixel at (x, y) is (x, y, x + y, 255), so every byte is traceable.
    private func gradient() throws -> RenderRaster {
        var raster = try RenderRaster(width: 4, height: 4)
        let full = raster.bounds
        var pixels = [UInt8]()
        for y in 0..<4 {
            for x in 0..<4 { pixels += [UInt8(x), UInt8(y), UInt8(x + y), 255] }
        }
        raster.replace(full, from: pixels, regionRect: full)
        return raster
    }

    @Test("A rect reaching past the raster is clipped to its bounds instead of reading out of range")
    func pixelsAreClippedToBounds() throws {
        let raster = try gradient()
        let inside = raster.pixels(in: PixelRect(x: 2, y: 1, width: 2, height: 3))
        #expect(inside.count == 2 * 3 * 4)
        #expect(Array(inside.prefix(4)) == [2, 1, 3, 255])

        #expect(raster.pixels(in: PixelRect(x: 2, y: 1, width: 50, height: 50)) == inside)
        #expect(
            raster.pixels(in: PixelRect(x: -3, y: -2, width: 5, height: 4))
                == raster.pixels(in: .init(x: 0, y: 0, width: 2, height: 2)))
        #expect(raster.pixels(in: PixelRect(x: 9, y: 9, width: 2, height: 2)).isEmpty)
        #expect(raster.pixels(in: PixelRect(x: 0, y: 0, width: 0, height: 3)).isEmpty)
    }
}
