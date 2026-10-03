import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// FR-10 and SPEC §172: matching is luma-only, so content that moves while its luminance repeats
/// (every second row alike) must not be reported as standing still. Color has to agree too.
@Suite("SCR-02: color agreement before stationarity")
struct ScrollChromaTests {
    static let width = 64
    static let viewportHeight = 200
    static let pageHeight = 400

    /// Row `y` of a page whose luminance alternates between two levels (120 and 40) with period
    /// two, while every row has its own red level. Green compensates so that luma stays on the
    /// level: a shift by an even number of rows leaves the luma plane unchanged.
    static func pageRow(_ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let red = Double((y * 37) % 130)
        let target = y % 2 == 0 ? 120.0 : 40.0
        let green = ((target - 0.299 * red) / 0.587).rounded()
        return (UInt8(red), UInt8(green), 0)
    }

    static func buffer(offset: Int, patch: Bool = false) -> ScrollPageBuffer {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * viewportHeight * 4)
        for row in 0..<viewportHeight {
            let color = pageRow(offset + row)
            for _ in 0..<width { pixels += [color.r, color.g, color.b, 255] }
        }
        var frame = ScrollPageBuffer(width: width, height: viewportHeight, pixels: pixels)
        if patch {
            // A small color-only blink with the same luma, such as an indicator changing hue.
            for y in 90..<94 {
                for x in 20..<24 {
                    let i = (y * width + x) * 4
                    let color = pageRow(y + offset)
                    frame.pixels[i] = color.r &+ 60
                    frame.pixels[i + 1] = UInt8(max(0, Int(color.g) - Int((60 * 0.299 / 0.587).rounded())))
                }
            }
        }
        return frame
    }

    static func image(offset: Int, patch: Bool = false) throws -> CGImage {
        try #require(ScrollPageFixture.image(from: buffer(offset: offset, patch: patch)))
    }

    @Test("Premise: even-row shifts keep luma within tolerance while the colors differ a lot")
    func premise() throws {
        let a = try #require(ScrollFrame(image: try Self.image(offset: 0)))
        let b = try #require(ScrollFrame(image: try Self.image(offset: 2)))
        let lumaDifference = zip(a.luma, b.luma).map { abs($0 - $1) }.max() ?? 0
        #expect(lumaDifference < ScrollMatcher.Thresholds.calibrated.pixelTolerance)
        #expect(b.colorChangedFraction(comparedTo: a, tolerance: 16) > 0.9)
    }

    @Test("Chromatic motion with repeating luminance does not count toward end of page")
    func chromaticMotionDoesNotDeclarePageEnd() throws {
        var stitcher = ScrollStitcher()
        var results: [ScrollAppendResult] = []
        for (index, offset) in [0, 2, 4, 6].enumerated() {
            results.append(
                stitcher.append(try Self.image(offset: offset), elapsed: .milliseconds(index * 100)))
        }
        #expect(results[0] == .accepted(offset: 0))
        #expect(!results.contains(.stationary), "\(results)")
        #expect(stitcher.consecutiveStationaryFrames == 0)
        #expect(!stitcher.endOfPageDetected)
        // The first frame stays the partial output; nothing was stitched from ambiguous frames.
        #expect(stitcher.acceptedFrameCount == 1)
    }

    @Test("Control: identical frames still detect stationarity and end of page")
    func identicalFramesStayStationary() throws {
        var stitcher = ScrollStitcher()
        var results: [ScrollAppendResult] = []
        for index in 0..<4 {
            results.append(stitcher.append(try Self.image(offset: 0), elapsed: .milliseconds(index * 100)))
        }
        #expect(results == [.accepted(offset: 0), .stationary, .stationary, .stationary])
        #expect(stitcher.endOfPageDetected)
    }

    @Test("Control: ±1 capture noise and a small local color blink are still stationary")
    func noiseAndLocalBlinkStayStationary() throws {
        var stitcher = ScrollStitcher()
        _ = stitcher.append(try Self.image(offset: 0), elapsed: .zero)
        var noisy = Self.buffer(offset: 0)
        for i in stride(from: 0, to: noisy.pixels.count, by: 4) { noisy.pixels[i] = noisy.pixels[i] &+ 1 }
        let noise = try #require(ScrollPageFixture.image(from: noisy))
        #expect(stitcher.append(noise, elapsed: .milliseconds(100)) == .stationary)
        #expect(stitcher.append(try Self.image(offset: 0, patch: true), elapsed: .milliseconds(200)) == .stationary)
        #expect(stitcher.append(try Self.image(offset: 0), elapsed: .milliseconds(300)) == .stationary)
        #expect(stitcher.endOfPageDetected)
    }
}
