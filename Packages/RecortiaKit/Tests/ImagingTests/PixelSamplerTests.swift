import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("PIX-01: nearest-pixel sRGB color sampling")
struct PixelSamplerTests {

    @Test("Area picks clip at corners rather than padding or shifting the neighborhood")
    func clippedAreaColors() async throws {
        let rows: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]
        let image = try ChartFixture.image(
            width: 3, height: 3,
            premultipliedRGBA: rows.flatMap { row in
                Array(repeating: row, count: 3).flatMap { $0 }
            })
        #expect(await PixelSampler.averageColor(atX: 0, y: 0, in: image, radius: 1) == RGBA(r: 128, g: 128, b: 0))
        #expect(await PixelSampler.averageColor(atX: 2, y: 2, in: image, radius: 1) == RGBA(r: 0, g: 128, b: 128))
        #expect(await PixelSampler.averageColor(atX: 0, y: 0, in: image, radius: 2) == RGBA(r: 85, g: 85, b: 85))
    }

    @Test("Premultiplied area means weight RGB by alpha and average alpha separately")
    func areaAlphaWeighting() async throws {
        let pixels: [[UInt8]] = [
            [255, 0, 0, 255], [0, 0, 128, 128], [0, 0, 0, 0],
            [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0],
            [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0],
        ]
        let image = try ChartFixture.image(width: 3, height: 3, premultipliedRGBA: pixels.flatMap { $0 })
        #expect(await PixelSampler.averageColor(atX: 1, y: 1, in: image, radius: 1) == RGBA(r: 170, g: 0, b: 85, a: 43))
    }

    @Test("Hidden transparent RGB never changes an area mean or survives transparent output")
    func transparentAreaColors() async throws {
        var secretPixels = Array(repeating: [UInt8](arrayLiteral: 255, 31, 127, 0), count: 9)
        secretPixels[4] = [255, 0, 0, 255]
        var clearPixels = Array(repeating: [UInt8](arrayLiteral: 0, 0, 0, 0), count: 9)
        clearPixels[4] = [255, 0, 0, 255]
        for pixels in [secretPixels, clearPixels] {
            let image = try ChartFixture.image(width: 3, height: 3, straightRGBA: pixels.flatMap { $0 })
            #expect(
                await PixelSampler.averageColor(atX: 1, y: 1, in: image, radius: 1) == RGBA(r: 255, g: 0, b: 0, a: 28))
        }
        var faintPixels = Array(repeating: [UInt8](arrayLiteral: 0, 0, 0, 0), count: 25)
        faintPixels[12] = [1, 0, 0, 1]
        let faint = try ChartFixture.image(width: 5, height: 5, premultipliedRGBA: faintPixels.flatMap { $0 })
        #expect(await PixelSampler.averageColor(atX: 2, y: 2, in: faint, radius: 2) == RGBA(r: 0, g: 0, b: 0, a: 0))
    }

    @Test("Invalid area coordinates and unsupported or extreme radii return nil")
    func invalidAreas() async throws {
        let image = try ChartFixture.checkerboard(width: 3, height: 3)
        for radius in [-1, 3, Int.min, Int.max] {
            #expect(await PixelSampler.averageColor(atX: 1, y: 1, in: image, radius: radius) == nil)
        }
        for (x, y) in [(-1, 0), (0, -1), (3, 0), (0, 3), (Int.max, Int.min)] {
            #expect(await PixelSampler.averageColor(atX: x, y: y, in: image, radius: 2) == nil)
        }
        #expect(await PixelSampler.averageColor(atX: 1, y: 1, in: image, radius: 0) == RGBA.black)
    }

    @Test("Nearest-neighbor sampling never interpolates a one-pixel checkerboard")
    func noInterpolation() throws {
        let board = try ChartFixture.checkerboard(width: 17, height: 11)
        for y in 0..<11 {
            for x in 0..<17 {
                let sampled = try #require(PixelSampler.color(atX: x, y: y, in: board))
                #expect(sampled == ((x + y) % 2 == 0 ? RGBA.black : RGBA.white))
            }
        }
    }

    /// White pixels with `marks` (x, y, straight RGBA) painted over them.
    private static func marked(width: Int, height: Int, _ marks: [(Int, Int, [UInt8])]) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for (x, y, color) in marks {
            bytes.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4, with: color)
        }
        return try ChartFixture.image(width: width, height: height, straightRGBA: bytes)
    }

    @Test("Darkest sampling returns the lowest Rec. 709 luminance in the box, not the lowest channel mean")
    func darkestPixel() async throws {
        // Blue (luminance 0.0722) is darker than green 0x5A (0.0731) although its channels sum higher;
        // the black pixel lies outside the 20-pixel box around (10, 10), which spans 0..<20.
        let image = try Self.marked(
            width: 30, height: 30, [(3, 4, [0, 90, 0, 255]), (17, 12, [0, 0, 255, 255]), (25, 25, [0, 0, 0, 255])])
        #expect(await PixelSampler.darkestColor(centerX: 10, y: 10, in: image, side: 20) == RGBA(r: 0, g: 0, b: 255))
        #expect(await PixelSampler.darkestColor(centerX: 22, y: 22, in: image, side: 20) == RGBA.black)
        // Clipped at the corner: the box around (0, 0) covers 0..<10 and finds the green pixel.
        #expect(await PixelSampler.darkestColor(centerX: 0, y: 0, in: image, side: 20) == RGBA(r: 0, g: 90, b: 0))
        let white = try ChartFixture.solid(width: 4, height: 4, color: ChartFixture.Color(255, 255, 255))
        #expect(await PixelSampler.darkestColor(centerX: 1, y: 1, in: white, side: 20) == RGBA.white)
    }

    @Test("Darkest sampling skips transparent pixels, whose hidden RGB would read as black")
    func darkestSkipsTransparent() async throws {
        let image = try Self.marked(width: 8, height: 8, [(2, 2, [0, 0, 0, 0]), (5, 5, [255, 0, 0, 51])])
        #expect(
            await PixelSampler.darkestColor(centerX: 4, y: 4, in: image, side: 8) == RGBA(r: 255, g: 0, b: 0, a: 51)
        )
        let clear = try ChartFixture.image(
            width: 3, height: 3,
            straightRGBA: Array(repeating: [UInt8](arrayLiteral: 9, 9, 9, 0), count: 9).flatMap { $0 })
        #expect(await PixelSampler.darkestColor(centerX: 1, y: 1, in: clear, side: 3) == RGBA.clear)
    }

    @Test("Darkest sampling rejects sides outside 1...80 and points off the image")
    func darkestBounds() async throws {
        let image = try ChartFixture.checkerboard(width: 4, height: 4)
        for side in [0, -1, 81, Int.max, Int.min] {
            #expect(await PixelSampler.darkestColor(centerX: 1, y: 1, in: image, side: side) == nil)
        }
        for (x, y) in [(-1, 0), (4, 0), (0, 4), (Int.min, Int.max)] {
            #expect(await PixelSampler.darkestColor(centerX: x, y: y, in: image, side: 20) == nil)
        }
        #expect(await PixelSampler.darkestColor(centerX: 1, y: 0, in: image, side: 1) == RGBA.white)
        #expect(await PixelSampler.darkestColor(centerX: 1, y: 1, in: image, side: 80) == RGBA.black)
    }

    @Test("A Display P3 image is sampled in sRGB, not as its raw P3 values")
    func displayP3IsConvertedToSRGB() async throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: p3,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let space = try #require(ChartFixture.sRGB)
        let srgb = try #require(CGColor(colorSpace: space, components: [200 / 255, 60 / 255, 20 / 255, 1]))
        context.setFillColor(srgb)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let raw = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect((raw[0], raw[1], raw[2]) != (200, 60, 20), "control: the stored P3 values differ from sRGB")
        let sampled = try #require(PixelSampler.color(atX: 0, y: 0, in: image))
        #expect(abs(Int(sampled.r) - 200) <= 1 && abs(Int(sampled.g) - 60) <= 1 && abs(Int(sampled.b) - 20) <= 1)
        let darkest = try #require(await PixelSampler.darkestColor(centerX: 0, y: 0, in: image, side: 20))
        #expect(darkest == sampled)
    }

}
