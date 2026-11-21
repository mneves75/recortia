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

    // An independent oracle for the row writers: a 5 × 3 raster whose 60 bytes are 1...60, checked
    // byte for byte against `bytes` after each write, so a write outside its region, a skipped
    // pixel or a swapped channel cannot pass. Every expected region below is written out by hand.
    private static let width = 5, height = 3
    private static let seed = (0..<(width * height * 4)).map { UInt8($0 + 1) }

    private func seeded() throws -> RenderRaster {
        var raster = try RenderRaster(width: Self.width, height: Self.height)
        raster.replace(raster.bounds, from: Self.seed, regionRect: raster.bounds)
        #expect(Array(raster.bytes) == Self.seed)
        return raster
    }

    /// `model` with `pixel` at every listed (x, y).
    private func painted(_ points: [(Int, Int)], _ pixel: [UInt8], over model: [UInt8] = seed) -> [UInt8] {
        var out = model
        for (x, y) in points {
            out.replaceSubrange((y * Self.width + x) * 4..<((y * Self.width + x) * 4 + 4), with: pixel)
        }
        return out
    }

    /// The seed bytes of the listed pixels, in order.
    private func seedPixels(_ points: [(Int, Int)]) -> [UInt8] {
        points.flatMap { x, y in Self.seed[((y * Self.width + x) * 4)..<((y * Self.width + x) * 4 + 4)] }
    }

    @Test("fill writes exactly the clipped region, including a 1 × 1 corner, in RGBA order")
    func fillMatchesOracle() throws {
        let opaque = RGBA(r: 200, g: 100, b: 50, a: 255)
        let cases: [(PixelRect, [(Int, Int)])] = [
            (PixelRect(x: -2, y: -1, width: 3, height: 2), [(0, 0)]),
            (PixelRect(x: 3, y: 1, width: 5, height: 1), [(3, 1), (4, 1)]),
            (PixelRect(x: 4, y: 2, width: 9, height: 9), [(4, 2)]),
            (PixelRect(x: 1, y: 1, width: 3, height: 9), [(1, 1), (2, 1), (3, 1), (1, 2), (2, 2), (3, 2)]),
            (PixelRect(x: -9, y: -9, width: 30, height: 30), (0..<3).flatMap { y in (0..<5).map { ($0, y) } }),
        ]
        for (rect, points) in cases {
            var raster = try seeded()
            raster.fill(rect, with: opaque)
            #expect(Array(raster.bytes) == painted(points, [200, 100, 50, 255]), "fill \(rect)")
        }
        var raster = try seeded()
        raster.fill(PixelRect(x: 4, y: 2, width: 1, height: 1), with: RGBA(r: 200, g: 100, b: 50, a: 128))
        #expect(Array(raster.bytes) == painted([(4, 2)], [100, 50, 25, 128]), "premultiplied corner")
        raster.fill(PixelRect(x: 5, y: 0, width: 2, height: 2), with: opaque)
        #expect(Array(raster.bytes) == painted([(4, 2)], [100, 50, 25, 128]), "disjoint fill writes nothing")
    }

    @Test("replace copies the clipped part of a packed region with its own stride and origin")
    func replaceMatchesOracle() throws {
        // Region pixel (x, y) relative to its rect is (100 + x, 110 + y, 120 + x + y, 77).
        func region(_ rect: PixelRect) -> [UInt8] {
            (0..<rect.height).flatMap { y in
                (0..<rect.width).flatMap { x in [UInt8(100 + x), UInt8(110 + y), UInt8(120 + x + y), 77] }
            }
        }
        // Target past every edge, clipped to a 3 × 3 region starting at column 1.
        var raster = try seeded()
        let interior = PixelRect(x: 1, y: 0, width: 3, height: 3)
        raster.replace(PixelRect(x: -1, y: -1, width: 7, height: 5), from: region(interior), regionRect: interior)
        var expected = Self.seed
        for y in 0..<3 {
            for x in 0..<3 {
                expected = painted(
                    [(1 + x, y)], [UInt8(100 + x), UInt8(110 + y), 120 + UInt8(x + y), 77], over: expected)
            }
        }
        #expect(Array(raster.bytes) == expected, "interior region")

        // A region hanging past the bottom-right corner: later, partial rows 1 and 2, columns 3 and 4.
        raster = try seeded()
        let corner = PixelRect(x: 3, y: 1, width: 4, height: 3)
        raster.replace(raster.bounds, from: region(corner), regionRect: corner)
        expected = painted([(3, 1)], [100, 110, 120, 77])
        expected = painted([(4, 1)], [101, 110, 121, 77], over: expected)
        expected = painted([(3, 2)], [100, 111, 121, 77], over: expected)
        expected = painted([(4, 2)], [101, 111, 122, 77], over: expected)
        #expect(Array(raster.bytes) == expected, "corner region")

        // A 1 × 1 write at the bottom-right pixel only.
        raster = try seeded()
        let last = PixelRect(x: 4, y: 2, width: 1, height: 1)
        raster.replace(PixelRect(x: 4, y: 2, width: 3, height: 3), from: [9, 8, 7, 6], regionRect: last)
        #expect(Array(raster.bytes) == painted([(4, 2)], [9, 8, 7, 6]), "corner pixel")
    }

    @Test("pixels(in:) returns the clipped region row by row from the seeded bytes")
    func pixelsMatchOracle() throws {
        let raster = try seeded()
        #expect(raster.pixels(in: PixelRect(x: -1, y: -1, width: 3, height: 2)) == seedPixels([(0, 0), (1, 0)]))
        #expect(
            raster.pixels(in: PixelRect(x: 3, y: 1, width: 9, height: 9))
                == seedPixels([(3, 1), (4, 1), (3, 2), (4, 2)]))
        #expect(raster.pixels(in: PixelRect(x: 4, y: 2, width: 1, height: 1)) == seedPixels([(4, 2)]))
        #expect(
            raster.pixels(in: PixelRect(x: 1, y: 1, width: 2, height: 5))
                == seedPixels([(1, 1), (2, 1), (1, 2), (2, 2)]))
        #expect(raster.pixels(in: raster.bounds) == Self.seed)
    }
}
