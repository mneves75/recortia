import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// A wide viewport whose only scrolling content is a narrow column between static side margins
/// (a centred article in a wide window), under a full-width fixed header and footer. The header
/// carries the fixture's animated spinner and, optionally, a wider animated badge, both outside
/// the column. Every content row changes at most `column.count / width` of its pixels.
struct NarrowColumnPage {
    let width: Int
    let column: Range<Int>
    /// Full-width header, footer, and spinner box; its own page is unused.
    let chrome: ScrollPageFixture
    /// Column-width content.
    let page: ScrollPageBuffer
    /// Animated boxes in header coordinates: the fixture's spinner and the optional badge.
    let animated: [(x: Range<Int>, y: Range<Int>)]
    let seed: UInt64

    var viewportHeight: Int { chrome.viewportHeight }
    var headerHeight: Int { chrome.headerHeight }
    var footerHeight: Int { chrome.footerHeight }
    var contentHeight: Int { chrome.contentHeight }
    var maxOffset: Int { page.height - contentHeight }

    static let margin: UInt8 = 238
    static let border: UInt8 = 200

    init(
        seed: UInt64, width: Int = 1000, column: Range<Int> = 400..<600, viewportHeight: Int = 360,
        headerHeight: Int = 40, footerHeight: Int = 24, pageHeight: Int = 1600, badge: Bool = false
    ) {
        self.seed = seed
        self.width = width
        self.column = column
        chrome = ScrollPageFixture(
            seed: seed, width: width, viewportHeight: viewportHeight, headerHeight: headerHeight,
            footerHeight: footerHeight, pageHeight: viewportHeight - headerHeight - footerHeight, noisy: false)
        page =
            ScrollPageFixture(
                seed: seed &+ 7, width: column.count, viewportHeight: viewportHeight - headerHeight - footerHeight,
                headerHeight: 0, footerHeight: 0, pageHeight: pageHeight, animated: false, noisy: false
            ).page
        var animated = chrome.spinnerBox.map { [(x: $0.x..<($0.x + $0.width), y: $0.y..<($0.y + $0.height))] } ?? []
        if badge { animated.append((x: 40..<136, y: 8..<32)) }
        self.animated = animated
    }

    /// One content row: margins, a one-pixel border on each side of the column, and page row `y`.
    private func contentRow(_ y: Int) -> [UInt8] {
        var row = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let gray = x == column.lowerBound - 1 || x == column.upperBound ? Self.border : Self.margin
            row[x * 4] = gray
            row[x * 4 + 1] = gray
            row[x * 4 + 2] = gray
        }
        row.replaceSubrange((column.lowerBound * 4)..<(column.upperBound * 4), with: page.row(y))
        return row
    }

    private func buffer(contentRows: Range<Int>) -> ScrollPageBuffer {
        var pixels = chrome.header.pixels
        pixels.reserveCapacity(width * (headerHeight + contentRows.count + footerHeight) * 4)
        for y in contentRows { pixels += contentRow(y) }
        pixels += chrome.footer.pixels
        return ScrollPageBuffer(
            width: width, height: headerHeight + contentRows.count + footerHeight, pixels: pixels)
    }

    func scrollFrame(offset: Int, index: Int) throws -> ScrollFrame {
        let image = try #require(frame(offset: offset, index: index))
        return try #require(ScrollFrame(image: image))
    }

    func frame(offset: Int, index: Int) -> CGImage? {
        var frame = buffer(contentRows: offset..<(offset + contentHeight))
        for box in animated {
            for y in box.y {
                for x in box.x {
                    let i = (y * width + x) * 4
                    let gray = UInt8(truncatingIfNeeded: index * 37 + x * 13 + y * 7)
                    frame.pixels[i] = gray
                    frame.pixels[i + 1] = gray
                    frame.pixels[i + 2] = gray
                }
            }
        }
        var rng = ScrollPageRandom(seed: seed &* 0x1000_0000_01B3 &+ UInt64(index) &+ 1)
        var i = 0
        while i < frame.pixels.count {
            let bits = rng.next()
            for c in 0..<3 {
                frame.pixels[i + c] = UInt8(clamping: Int(frame.pixels[i + c]) + Int((bits >> (UInt64(c) * 8)) % 3) - 1)
            }
            i += 4
        }
        return ScrollPageFixture.image(from: frame)
    }

    /// `header + column page[0 ..< lastOffset + contentHeight] (with margins) + footer`.
    func expectedOutput(lastOffset: Int) -> ScrollPageBuffer {
        buffer(contentRows: 0..<(lastOffset + contentHeight))
    }

    func isAnimated(x: Int, y: Int) -> Bool {
        animated.contains { $0.x.contains(x) && $0.y.contains(y) }
    }

    /// Rows differing from `expected` by more than the ±1 noise, ignoring animated header pixels.
    func mismatchedRows(output: ScrollPageBuffer, expected: ScrollPageBuffer) -> [Int] {
        guard output.width == expected.width, output.height == expected.height else { return [-1] }
        return (0..<output.height).filter { y in
            (0..<output.width).contains { x in
                guard !isAnimated(x: x, y: y) else { return false }
                let i = (y * output.width + x) * 4
                return (0..<3).contains { abs(Int(output.pixels[i + $0]) - Int(expected.pixels[i + $0])) > 1 }
            }
        }
    }
}

@Suite("SCR-01: a narrow scrolling column between static margins")
struct ScrollNarrowColumnTests {
    @Test("A narrow textured column in a wide viewport stitches exactly", arguments: [false, true])
    func narrowColumnStitches(badge: Bool) throws {
        let page = NarrowColumnPage(seed: 71, badge: badge)
        var rng = ScrollPageRandom(seed: 71)
        var offsets = [0]
        while offsets.last! < page.maxOffset {
            offsets.append(min(page.maxOffset, offsets.last! + Int.random(in: 12...120, using: &rng)))
        }
        offsets += [page.maxOffset, page.maxOffset, page.maxOffset]
        var stitcher = ScrollStitcher()
        var results: [ScrollAppendResult] = []
        for (index, offset) in offsets.enumerated() {
            results.append(stitcher.append(try #require(page.frame(offset: offset, index: index)), elapsed: .zero))
        }
        var expected: [ScrollAppendResult] = [.accepted(offset: 0)]
        for index in 1..<offsets.count {
            let step = offsets[index] - offsets[index - 1]
            expected.append(step == 0 ? .stationary : .accepted(offset: step))
        }
        #expect(results == expected)
        #expect(stitcher.endOfPageDetected)
        #expect(stitcher.outputSize == PixelSize(width: page.width, height: page.viewportHeight + page.maxOffset))
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let bad = page.mismatchedRows(output: output, expected: page.expectedOutput(lastOffset: page.maxOffset))
        #expect(bad.isEmpty, "\(bad.count) mismatched rows, first \(bad.prefix(5))")
    }

    @Test("Band detection finds the full-width header and footer around a narrow moving column")
    func bandsAroundNarrowColumn() throws {
        let page = NarrowColumnPage(seed: 72, badge: true)
        let previous = try page.scrollFrame(offset: 0, index: 0)
        let current = try page.scrollFrame(offset: 60, index: 1)
        let bands = ScrollStitcher.detectBands(
            previous: previous, current: current, tolerance: ScrollMatcher.Thresholds.calibrated.pixelTolerance)
        // Blank content rows next to a band may join it (harmless); real content must not.
        #expect(bands.top >= page.headerHeight && bands.top <= page.headerHeight + 16, "\(bands)")
        #expect(bands.bottom >= page.footerHeight && bands.bottom <= page.footerHeight + 16, "\(bands)")
    }

    @Test("Control: header animation alone is confined to its own rows and is stationary, not motion")
    func animationAloneIsStationary() throws {
        let page = NarrowColumnPage(seed: 73, badge: true)
        let previous = try page.scrollFrame(offset: 0, index: 0)
        let current = try page.scrollFrame(offset: 0, index: 1)
        let bands = ScrollStitcher.detectBands(
            previous: previous, current: current, tolerance: ScrollMatcher.Thresholds.calibrated.pixelTolerance)
        // Only header rows can be unfixed: the animation never pulls content rows into a region.
        let regionEnd = page.viewportHeight - bands.bottom
        #expect(bands.top >= regionEnd || regionEnd <= page.headerHeight, "\(bands)")

        var stitcher = ScrollStitcher()
        var results: [ScrollAppendResult] = []
        for index in 0..<5 {
            results.append(stitcher.append(try #require(page.frame(offset: 0, index: index)), elapsed: .zero))
        }
        #expect(results == [.accepted(offset: 0), .stationary, .stationary, .stationary, .stationary])
        #expect(stitcher.endOfPageDetected)
    }

    @Test("Control: full-width content keeps its header and footer bands")
    func fullWidthBandsUnchanged() throws {
        let fixture = ScrollPageFixture(seed: 74, headerHeight: 40, footerHeight: 24, pageHeight: 1200)
        let first = try #require(fixture.frame(offset: 0, index: 0))
        let second = try #require(fixture.frame(offset: 60, index: 1))
        let previous = try #require(ScrollFrame(image: first))
        let current = try #require(ScrollFrame(image: second))
        let bands = ScrollStitcher.detectBands(
            previous: previous, current: current, tolerance: ScrollMatcher.Thresholds.calibrated.pixelTolerance)
        #expect(bands.top >= 40 && bands.top <= 40 + 16, "\(bands)")
        #expect(bands.bottom >= 24 && bands.bottom <= 24 + 16, "\(bands)")
    }
}
