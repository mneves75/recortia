import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("PIX-01: nearest-pixel sRGB color sampling")
struct PixelSamplerTests {
    @Test("Bounded 3×3 and 5×5 picks average encoded sRGB instead of the center pixel")
    func areaColorsAreExact() async throws {
        let rows: [[UInt8]] = [
            [255, 0, 0, 255], [0, 255, 0, 255], [0, 255, 0, 255],
            [0, 0, 255, 255], [0, 0, 255, 255],
        ]
        let image = try ChartFixture.image(
            width: 5, height: 5,
            premultipliedRGBA: rows.flatMap { row in
                Array(repeating: row, count: 5).flatMap { $0 }
            })
        #expect(PixelSampler.color(atX: 2, y: 2, in: image) == RGBA(r: 0, g: 255, b: 0))
        #expect(await PixelSampler.averageColor(atX: 2, y: 2, in: image, radius: 1) == RGBA(r: 0, g: 170, b: 85))
        #expect(await PixelSampler.averageColor(atX: 2, y: 2, in: image, radius: 2) == RGBA(r: 51, g: 102, b: 102))
    }

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

    @Test("A known sRGB chart returns exact RGB and HEX for every cell, including cell edges")
    func chartColorsAreExact() throws {
        let cell = 5
        // Through the real import path: PNG bytes -> ImageDecoder -> sampler.
        let decoded = try ImageDecoder.decode(try ContainerCrafting.pngData(try ChartFixture.colorChart(cell: cell)))
        for (index, expected) in ChartFixture.chartColors.enumerated() {
            let x0 = (index % ChartFixture.chartColumns) * cell, y0 = (index / ChartFixture.chartColumns) * cell
            for (x, y) in [(x0, y0), (x0 + cell - 1, y0 + cell - 1), (x0 + 2, y0 + 3)] {
                let sampled = try #require(PixelSampler.color(atX: x, y: y, in: decoded.image))
                #expect(sampled == expected.rgba)
                #expect(sampled.hex == expected.hex)
            }
        }
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

    @Test("Out-of-range coordinates return nil")
    func outOfRange() throws {
        let board = try ChartFixture.checkerboard(width: 4, height: 3)
        for (x, y) in [(-1, 0), (0, -1), (4, 0), (0, 3), (Int.max, Int.min)] {
            #expect(PixelSampler.color(atX: x, y: y, in: board) == nil)
        }
    }

    @Test("Translucent pixels are reported un-premultiplied")
    func unpremultiplied() throws {
        let image = try ChartFixture.solid(width: 2, height: 2, color: color(200, 100, 50, 128))
        let sampled = try #require(PixelSampler.color(atX: 1, y: 1, in: image))
        #expect(sampled.a == 128)
        #expect(sampled.distance(to: RGBA(r: 200, g: 100, b: 50, a: 128)) <= 2)
    }

    @Test("Top-left addressing: (0, 0) is the top-left pixel")
    func topLeftOrigin() throws {
        let chart = try ChartFixture.geometryChart(width: 10, height: 10)
        #expect(PixelSampler.color(atX: 0, y: 0, in: chart) == ChartFixture.quadrantColors[0].rgba)
        #expect(PixelSampler.color(atX: 9, y: 9, in: chart) == ChartFixture.quadrantColors[3].rgba)
    }
}

extension RGBA {
    fileprivate func distance(to other: RGBA) -> Int {
        max(
            abs(Int(r) - Int(other.r)), abs(Int(g) - Int(other.g)), abs(Int(b) - Int(other.b)),
            abs(Int(a) - Int(other.a)))
    }
}
