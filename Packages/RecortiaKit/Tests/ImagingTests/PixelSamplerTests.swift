import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("PIX-01: nearest-pixel sRGB color sampling")
struct PixelSamplerTests {
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
