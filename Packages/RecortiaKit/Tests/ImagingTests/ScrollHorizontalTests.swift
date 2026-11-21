import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

/// B-9b: a page that scrolls to the right is stitched by the same matcher on transposed frames.
/// The fixtures are the vertical ones transposed, so a fixed header and footer become fixed
/// columns at the left and right, and every expectation is checked in the output's own orientation.
@Suite("SCR-01/02/04: horizontal scrolling capture")
struct ScrollHorizontalTests {
    /// FNV-1a over the assembled bytes.
    static func digest(_ buffer: ScrollPageBuffer) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in buffer.pixels { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    @Test(
        "Vertical stitching stays byte-identical to the stitcher before horizontal support",
        arguments: [(UInt64(3), UInt64(0xcddb_a5fb_5ec2_7dab)), (41, 0xade0_9bc2_70de_7093)])
    func verticalUnchanged(seed: UInt64, digest expected: UInt64) throws {
        // Digests recorded on c638bb8, before the stitcher learned a direction.
        let fixture = ScrollPageFixture(seed: seed, pageHeight: 1600)
        var stitcher = ScrollStitcher()
        let offsets = fixture.forwardOffsets(steps: 40...150)
        _ = ScrollHarness.run(fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        #expect(output.width == 240 && output.height == 1664)
        #expect(Self.digest(output) == expected, "digest \(String(Self.digest(output), radix: 16))")
    }

    @Test("Exact overlap: a page scrolling right is stitched column for column, fixed columns once")
    func exactOverlap() throws {
        let fixture = ScrollPageFixture(
            seed: 14, headerHeight: 48, footerHeight: 32, pageHeight: 1000, animated: false, noisy: false)
        var stitcher = ScrollStitcher(direction: .horizontal)
        let offsets = [0, 37, 81, 150, 222, 300, 377, 460, 540, 620, 700, fixture.maxOffset]
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty && log.pauses.isEmpty, "\(log.falseAccepts) \(log.pauses)")
        let expected = fixture.expectedHorizontalOutput(lastOffset: fixture.maxOffset)
        #expect(stitcher.outputSize == PixelSize(width: expected.width, height: expected.height))
        #expect(expected.width > expected.height, "the result is wide")
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        // Noise-free frames: bit-identical output rules out blending, resampling and flips.
        #expect(output == expected)
    }

    @Test("Noisy, animated pages scrolling right lose and repeat no column", arguments: [UInt64(1), 2, 5])
    func noisySessions(seed: UInt64) throws {
        let fixture = ScrollPageFixture(seed: seed, pageHeight: 1400)
        let offsets = fixture.forwardOffsets(steps: 30...140)
        var stitcher = ScrollStitcher(direction: .horizontal)
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        #expect(log.retainedFrameViolations.isEmpty)
        let last = try #require(log.lastAcceptedOffset)
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let bad = ScrollHarness.mismatchedColumns(
            output: output, expected: fixture.expectedHorizontalOutput(lastOffset: last), fixture: fixture)
        #expect(bad.isEmpty, "\(bad.count) bad columns, first \(bad.prefix(5))")
    }

    @Test("No overlap: a jump past the viewport pauses with low confidence, as vertically")
    func noOverlap() {
        let fixture = ScrollPageFixture(seed: 41, pageHeight: 2000)
        let content = fixture.contentHeight
        for jump in [content - 8, content, content + 150] {
            var stitcher = ScrollStitcher(direction: .horizontal)
            let offsets = [0, 60, 60 + jump, 60 + jump + 40]
            let log = ScrollHarness.run(
                fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
            #expect(log.falseAccepts.isEmpty, "jump \(jump): \(log.falseAccepts)")
            #expect(log.results[2] == .ambiguous(.lowConfidence), "jump \(jump): \(log.results)")
        }
    }

    @Test("Repeated columns are an ambiguous match, never a guess")
    func repeatedContent() throws {
        let fixture = ScrollPageFixture(seed: 31, kind: .repeatedRows, pageHeight: 1600)
        let period = try #require(fixture.repeatPeriod)
        let offsets = fixture.forwardOffsets(steps: 5...80, stationaryChance: 0)
        var stitcher = ScrollStitcher(direction: .horizontal)
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        let unexplained = log.movedButStationary.filter { index in
            guard let last = log.lastAcceptedOffset else { return true }
            return (offsets[index] - last) % period != 0
        }
        #expect(unexplained.isEmpty)
        #expect(log.pauses.contains { $0.reason == .ambiguousMatch })
        #expect(log.acceptedCount == 1)
    }

    @Test("Scrolling back left pauses and never repeats a column")
    func reverse() throws {
        let fixture = ScrollPageFixture(seed: 43, pageHeight: 1600)
        var stitcher = ScrollStitcher(direction: .horizontal)
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: [0, 60, 130, 90, 130, 200]), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        #expect(log.results[3] == .ambiguous(.reversedDirection))
        #expect(log.results[5] == .accepted(offset: 70))
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let bad = ScrollHarness.mismatchedColumns(
            output: output, expected: fixture.expectedHorizontalOutput(lastOffset: 200), fixture: fixture)
        #expect(bad.isEmpty, "\(bad.prefix(5))")
    }

    @Test(
        "The length, side and area limits bound the stitched width and stop appending",
        arguments: [ScrollLimit.area, .side, .width])
    func sizeBound(limit: ScrollLimit) throws {
        var limits = ScrollLimits(
            maxDuration: .seconds(10_000), maxAcceptedFrames: 10_000, maxOutputArea: 1 << 40, maxSide: 1 << 30,
            defaultMaxHeight: 1 << 30)
        switch limit {
        case .area: limits.maxOutputArea = 100 * 330
        case .side: limits.maxSide = 330
        case .width: limits.defaultMaxHeight = 330
        case .duration, .frames, .height, .memory: break
        }
        let fixture = ScrollPageFixture(
            seed: 54, width: 100, viewportHeight: 200, headerHeight: 20, footerHeight: 10, pageHeight: 1200)
        var stitcher = ScrollStitcher(limits: limits, direction: .horizontal)
        var results: [ScrollAppendResult] = []
        for (index, offset) in [0, 40, 80, 120, 160, 200].enumerated() {
            let frame = try #require(fixture.horizontalFrame(offset: offset, index: index))
            results.append(stitcher.append(frame, elapsed: .zero))
        }
        // Widths after each frame: 200, 240, 280, 320, 360: the 360-column frame crosses 330.
        #expect(results.prefix(4).allSatisfy { $0.isAccepted }, "\(results)")
        #expect(results[4] == .limitReached(limit))
        #expect(results[5] == .limitReached(limit))
        #expect(stitcher.outputSize == PixelSize(width: 320, height: 100))
        let image = try stitcher.assemble()
        #expect(image.width == 320 && image.height == 100)
    }

    @Test("A frame tall enough for the height limit is not refused for it when the page scrolls right")
    func heightLimitFollowsTheDirection() throws {
        let limits = ScrollLimits(defaultMaxHeight: 300)
        let frame = try ScrollLimitsTests.blankFrame(width: 200, height: 400)
        var vertical = ScrollStitcher(limits: limits)
        #expect(vertical.append(frame, elapsed: .zero) == .limitReached(.height))
        var horizontal = ScrollStitcher(limits: limits, direction: .horizontal)
        #expect(horizontal.append(frame, elapsed: .zero) == .accepted(offset: 0))
        #expect(horizontal.outputSize == PixelSize(width: 200, height: 400))
    }

    @Test("Working memory: a horizontal frame whose planes cannot fit is refused before decoding")
    func memoryBound() throws {
        var stitcher = ScrollStitcher(limits: ScrollLimits(maxWorkingBytes: 100_000), direction: .horizontal)
        #expect(
            stitcher.append(try ScrollLimitsTests.blankFrame(width: 200, height: 100), elapsed: .zero)
                == .limitReached(.memory))
        #expect(stitcher.retainedByteCount == 0)
        #expect(throws: ScrollStitchError.noFrames) { try stitcher.assemble() }
    }

    @Test("The horizontal preview is bounded in width, keeps the aspect ratio, and shows columns in order")
    func preview() throws {
        var stitcher = ScrollStitcher(direction: .horizontal)
        #expect(stitcher.preview(maxLength: 100) == nil)
        let fixture = ScrollPageFixture(seed: 13, pageHeight: 1600, animated: false, noisy: false)
        for (index, offset) in [0, 100, 200, 300, 400, 500, 600, 700].enumerated() {
            _ = stitcher.append(try #require(fixture.horizontalFrame(offset: offset, index: index)), elapsed: .zero)
        }
        let size = stitcher.outputSize
        #expect(size.width > 512, "wide enough to be drawn in more than one chunk")
        let preview = try #require(stitcher.preview(maxLength: 300))
        #expect(preview.width <= 300)
        let expectedHeight = Double(size.height) * Double(preview.width) / Double(size.width)
        #expect(abs(Double(preview.height) - expectedHeight) <= 1)
        // The chunked preview matches one downscale of the whole stitch: a flipped, transposed
        // or misplaced chunk would not.
        let assembled = try stitcher.assemble()
        let reference = try #require(Self.downscale(assembled, width: preview.width, height: preview.height))
        let drawn = try #require(ScrollHarness.rgba(preview))
        let mean = Self.meanDifference(drawn, reference)
        #expect(mean < 6, "mean per-channel difference \(mean)")
        let full = try #require(stitcher.preview(maxLength: 100_000))
        #expect(full.width == size.width && full.height == size.height)
        #expect(stitcher.preview(maxLength: 0) == nil)
    }

    private static func downscale(_ image: CGImage, width: Int, height: Int) -> ScrollPageBuffer? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return ScrollHarness.rgba(scaled)
    }

    private static func meanDifference(_ first: ScrollPageBuffer, _ second: ScrollPageBuffer) -> Double {
        guard first.pixels.count == second.pixels.count, !first.pixels.isEmpty else { return .infinity }
        var total = 0
        for index in first.pixels.indices where index % 4 != 3 {
            total += abs(Int(first.pixels[index]) - Int(second.pixels[index]))
        }
        return Double(total) / Double(first.pixels.count / 4 * 3)
    }
}
