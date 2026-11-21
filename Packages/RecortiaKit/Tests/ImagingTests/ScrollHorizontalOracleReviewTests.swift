import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// Independent review of B-9b: the horizontal fixtures in `ScrollHorizontalTests` are the vertical
/// ones transposed, the same convention the stitcher uses, so a shared axis mistake would pass
/// both. Here the page is built wide from the start, with a fixed sidebar at the left and a fixed
/// strip at the right, and the expectation is cut from it column by column with no transposition.
@Suite("Review: a page scrolling right, checked against an untransposed oracle")
struct ScrollHorizontalOracleReviewTests {
    static let height = 150
    static let leftWidth = 28
    static let rightWidth = 18
    static let contentWidth = 240

    /// Random 3×3 blocks: no two columns of the page repeat, so every displacement is unique.
    static func noise(width: Int, height: Int, seed: UInt64) -> ScrollPageBuffer {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for by in stride(from: 0, to: height, by: 3) {
            for bx in stride(from: 0, to: width, by: 3) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let r = UInt8(truncatingIfNeeded: state >> 56)
                let g = UInt8(truncatingIfNeeded: state >> 40)
                let b = UInt8(truncatingIfNeeded: state >> 24)
                for y in by..<min(by + 3, height) {
                    for x in bx..<min(bx + 3, width) {
                        let i = (y * width + x) * 4
                        pixels[i] = r
                        pixels[i + 1] = g
                        pixels[i + 2] = b
                    }
                }
            }
        }
        return ScrollPageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Columns `range` of `buffer`, every row.
    static func columns(_ buffer: ScrollPageBuffer, _ range: Range<Int>) -> ScrollPageBuffer {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(range.count * buffer.height * 4)
        for y in 0..<buffer.height {
            let start = (y * buffer.width + range.lowerBound) * 4
            pixels += buffer.pixels[start..<(start + range.count * 4)]
        }
        return ScrollPageBuffer(width: range.count, height: buffer.height, pixels: pixels)
    }

    /// Side by side, left to right.
    static func join(_ parts: [ScrollPageBuffer]) -> ScrollPageBuffer {
        let width = parts.reduce(0) { $0 + $1.width }
        var pixels: [UInt8] = []
        for y in 0..<parts[0].height {
            for part in parts { pixels += part.rows(y..<(y + 1)) }
        }
        return ScrollPageBuffer(width: width, height: parts[0].height, pixels: pixels)
    }

    static func image(_ buffer: ScrollPageBuffer) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(buffer.pixels) as CFData))
        return try #require(
            CGImage(
                width: buffer.width, height: buffer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: buffer.width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    struct Page {
        let left: ScrollPageBuffer
        let right: ScrollPageBuffer
        let content: ScrollPageBuffer

        init(seed: UInt64, contentLength: Int) {
            left = ScrollHorizontalOracleReviewTests.noise(
                width: ScrollHorizontalOracleReviewTests.leftWidth, height: ScrollHorizontalOracleReviewTests.height,
                seed: seed &+ 1)
            right = ScrollHorizontalOracleReviewTests.noise(
                width: ScrollHorizontalOracleReviewTests.rightWidth, height: ScrollHorizontalOracleReviewTests.height,
                seed: seed &+ 2)
            content = ScrollHorizontalOracleReviewTests.noise(
                width: contentLength, height: ScrollHorizontalOracleReviewTests.height, seed: seed)
        }

        /// What the viewport shows after the page scrolled `offset` columns to the right.
        func frame(offset: Int) throws -> CGImage {
            let visible = ScrollHorizontalOracleReviewTests.columns(
                content, offset..<(offset + ScrollHorizontalOracleReviewTests.contentWidth))
            return try ScrollHorizontalOracleReviewTests.image(
                ScrollHorizontalOracleReviewTests.join([left, visible, right]))
        }

        /// The sidebar once, the page from its first column to the last one seen, the strip once.
        func expected(lastOffset: Int) -> ScrollPageBuffer {
            ScrollHorizontalOracleReviewTests.join([
                left,
                ScrollHorizontalOracleReviewTests.columns(
                    content, 0..<(lastOffset + ScrollHorizontalOracleReviewTests.contentWidth)),
                right,
            ])
        }
    }

    @Test(
        "Every column of a page scrolling right lands once, in order, between the fixed columns",
        arguments: [UInt64(11), 29, 101])
    func matchesOracle(seed: UInt64) throws {
        let page = Page(seed: seed, contentLength: 1_100)
        let offsets = [0, 23, 61, 130, 131, 190, 260, 333, 420, 500, 590, 700, 790, 860]
        var stitcher = ScrollStitcher(direction: .horizontal)
        var previous = 0
        for (index, offset) in offsets.enumerated() {
            let result = stitcher.append(try page.frame(offset: offset), elapsed: .milliseconds(100 * index))
            let expected: ScrollAppendResult = index == 0 ? .accepted(offset: 0) : .accepted(offset: offset - previous)
            #expect(result == expected, "frame \(index) at \(offset)")
            previous = offset
        }
        let expected = page.expected(lastOffset: offsets.last!)
        #expect(stitcher.outputSize == PixelSize(width: expected.width, height: expected.height))
        #expect(stitcher.outputSize.height == Self.height, "the output stays one viewport tall")
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        #expect(output == expected)

        // The full-size preview is the assembled image itself, also in its own orientation.
        let preview = try #require(stitcher.preview(maxLength: expected.width))
        #expect(ScrollHarness.rgba(preview) == expected)
    }

    @Test("Scrolling back to the left never re-adds a column")
    func leftwardMovePauses() throws {
        let page = Page(seed: 7, contentLength: 800)
        var stitcher = ScrollStitcher(direction: .horizontal)
        _ = stitcher.append(try page.frame(offset: 0), elapsed: .zero)
        _ = stitcher.append(try page.frame(offset: 120), elapsed: .milliseconds(100))
        let before = stitcher.outputSize
        let back = stitcher.append(try page.frame(offset: 60), elapsed: .milliseconds(200))
        if case .accepted = back { Issue.record("a leftward move was appended: \(back)") }
        #expect(stitcher.outputSize == before)
        _ = stitcher.append(try page.frame(offset: 200), elapsed: .milliseconds(300))
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        #expect(output == page.expected(lastOffset: 200))
    }
}
