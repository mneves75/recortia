import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("SCR-04: limits and bounded memory")
struct ScrollLimitsTests {
    static func blankFrame(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test("Default limits are the FR-10 values")
    func defaults() {
        let limits = ScrollStitcher().limits
        #expect(limits == ScrollLimits.default)
        #expect(limits.maxDuration == .seconds(120))
        #expect(limits.maxAcceptedFrames == 200)
        #expect(limits.maxOutputArea == 40_000_000)
        #expect(limits.maxSide == 32_768)
        #expect(limits.defaultMaxHeight == 20_000)
        #expect(limits.maxWorkingBytes == 512 * 1024 * 1024)
    }

    @Test("120 s: a frame after the duration budget ends collection, and the limit is sticky")
    func duration() throws {
        let fixture = ScrollPageFixture(seed: 51, pageHeight: 900)
        var stitcher = ScrollStitcher()
        #expect(
            stitcher.append(try #require(fixture.frame(offset: 0, index: 0)), elapsed: .zero) == .accepted(offset: 0))
        #expect(
            stitcher.append(try #require(fixture.frame(offset: 40, index: 1)), elapsed: .seconds(120))
                == .accepted(offset: 40))
        let late = try #require(fixture.frame(offset: 80, index: 2))
        #expect(stitcher.append(late, elapsed: .seconds(120) + .milliseconds(1)) == .limitReached(.duration))
        #expect(stitcher.append(late, elapsed: .seconds(1)) == .limitReached(.duration))
        #expect(stitcher.acceptedFrameCount == 2)
        #expect(stitcher.outputSize.height == fixture.viewportHeight + 40)
    }

    @Test("200 frames: the 201st accepted frame is refused; retained frames stay bounded throughout")
    func frames() throws {
        let fixture = ScrollPageFixture(
            seed: 52, width: 120, viewportHeight: 220, headerHeight: 20, footerHeight: 10, pageHeight: 6400)
        var stitcher = ScrollStitcher()
        var rng = ScrollPageRandom(seed: 52)
        var offset = 0, previous = 0
        let frameBytes = fixture.width * fixture.viewportHeight * 4
        for index in 0..<201 {
            let result = stitcher.append(try #require(fixture.frame(offset: offset, index: index)), elapsed: .zero)
            if index < 200 {
                #expect(result == .accepted(offset: offset - previous), "frame \(index): \(result)")
            } else {
                #expect(result == .limitReached(.frames))
            }
            #expect(stitcher.retainedFullFrameCount <= 2)
            let outputBytes = stitcher.outputSize.width * stitcher.outputSize.height * 4
            #expect(
                stitcher.retainedByteCount
                    <= outputBytes + 2 * frameBytes + ScrollStitcher.workingBudgetBytes)
            previous = offset
            offset += Int.random(in: 8...30, using: &rng)
        }
        #expect(stitcher.acceptedFrameCount == 200)
    }

    @Test("40 MP: a viewport whose output would exceed the area budget is refused before decoding")
    func area() throws {
        var stitcher = ScrollStitcher()
        #expect(stitcher.append(try Self.blankFrame(width: 8000, height: 5001), elapsed: .zero) == .limitReached(.area))
        #expect(stitcher.retainedByteCount == 0)
        #expect(throws: ScrollStitchError.noFrames) { try stitcher.assemble() }
    }

    @Test("Working budget: even the first frame is refused when its own planes cannot fit")
    func firstFrameExceedingWorkingBudget() throws {
        var stitcher = ScrollStitcher(limits: ScrollLimits(maxWorkingBytes: 100_000))
        let frame = try Self.blankFrame(width: 100, height: 200)
        #expect(stitcher.append(frame, elapsed: .zero) == .limitReached(.memory))
        #expect(stitcher.retainedByteCount == 0)
        #expect(throws: ScrollStitchError.noFrames) { try stitcher.assemble() }
    }

    @Test("Working budget arithmetic: the 4,000x10,000 viewport fits once and then breaks 512 MiB")
    func peakEstimateForLargeViewport() throws {
        let size = PixelSize(width: 4000, height: 10_000)
        let budget = ScrollLimits.default.maxWorkingBytes
        let firstPeak = try #require(
            ScrollStitcher.peakWorkingBytes(frameSize: size, retainedBytes: 0, appending: false))
        #expect(firstPeak <= budget)
        // After the first frame: output rows plus the previous frame's luma are retained.
        let retained = 4000 * 10_000 * 4 + 4000 * 10_000 * 4
        let secondPeak = try #require(
            ScrollStitcher.peakWorkingBytes(frameSize: size, retainedBytes: retained, appending: true))
        #expect(secondPeak >= 640_000_000)
        #expect(secondPeak > budget)
        // Overflow-checked: absurd dimensions report no estimate instead of wrapping.
        #expect(
            ScrollStitcher.peakWorkingBytes(
                frameSize: PixelSize(width: Int.max / 2, height: 4), retainedBytes: 0, appending: false) == nil)
        #expect(
            ScrollStitcher.peakWorkingBytes(
                frameSize: PixelSize(width: 10, height: 10), retainedBytes: Int.max, appending: true) == nil)
    }

    @Test(
        "Each limit ends collection independently mid-session", arguments: [ScrollLimit.area, .side, .height])
    func independentLimits(limit: ScrollLimit) throws {
        let huge = ScrollLimits(
            maxDuration: .seconds(10_000), maxAcceptedFrames: 10_000, maxOutputArea: 1 << 40, maxSide: 1 << 30,
            defaultMaxHeight: 1 << 30)
        var limits = huge
        let fixture = ScrollPageFixture(
            seed: 54, width: 100, viewportHeight: 200, headerHeight: 20, footerHeight: 10, pageHeight: 1200)
        switch limit {
        case .area: limits.maxOutputArea = 100 * 330
        case .side: limits.maxSide = 330
        case .height: limits.defaultMaxHeight = 330
        case .frames: limits.maxAcceptedFrames = 4
        case .duration, .memory: break  // time and working memory have their own tests
        }
        var stitcher = ScrollStitcher(limits: limits)
        var results: [ScrollAppendResult] = []
        for (index, offset) in [0, 40, 80, 120, 160, 200].enumerated() {
            results.append(stitcher.append(try #require(fixture.frame(offset: offset, index: index)), elapsed: .zero))
        }
        // Heights after each frame: 200, 240, 280, 320, 360: the 360-row frame crosses 330.
        #expect(results.prefix(4).allSatisfy { $0.isAccepted }, "\(results)")
        #expect(results[4] == .limitReached(limit))
        #expect(results[5] == .limitReached(limit))
        #expect(stitcher.outputSize.height == 320)
        #expect(try stitcher.assemble().height == 320)
    }

    @Test("A budget covering planes, growth and scratch still refuses an append without bookkeeping")
    func appendRefusesMissingBookkeepingBudget() throws {
        let fixture = ScrollPageFixture(
            seed: 156, width: 100, viewportHeight: 200, headerHeight: 20, footerHeight: 10, pageHeight: 800)
        let first = try #require(fixture.frame(offset: 0, index: 0))
        let next = try #require(fixture.frame(offset: 40, index: 1))
        // Full-frame planes, a retained viewport, worst-case output growth, and declared scratch.
        // This exact budget has no room for the matcher bookkeeping.
        var stitcher = ScrollStitcher(limits: ScrollLimits(maxWorkingBytes: 1_346_432))
        #expect(stitcher.append(first, elapsed: .zero) == .accepted(offset: 0))
        let retained = stitcher.retainedByteCount
        let size = stitcher.outputSize
        let probe = ScrollMatcher.ScratchProbe()
        ScrollMatcher.$scratchProbe.withValue(probe) {
            #expect(stitcher.append(next, elapsed: .zero) == .limitReached(.memory))
            #expect(stitcher.append(next, elapsed: .zero) == .limitReached(.memory))
        }
        #expect(probe.chunkCount == 0, "admission must refuse before any pixel comparisons")
        #expect(stitcher.acceptedFrameCount == 1)
        #expect(stitcher.retainedByteCount == retained)
        #expect(stitcher.outputSize == size)
        let output = try #require(ScrollHarness.rgba(stitcher.assemble()))
        #expect(output == fixture.frameBuffer(offset: 0, index: 0))

        // At the complete declared peak, the same append is admitted and actually matched.
        let peak = try #require(
            ScrollStitcher.peakWorkingBytes(frameSize: size, retainedBytes: retained, appending: true))
        var admitted = ScrollStitcher(limits: ScrollLimits(maxWorkingBytes: peak))
        #expect(admitted.append(first, elapsed: .zero) == .accepted(offset: 0))
        let control = ScrollMatcher.ScratchProbe()
        ScrollMatcher.$scratchProbe.withValue(control) {
            #expect(admitted.append(next, elapsed: .zero) == .accepted(offset: 40))
        }
        #expect(control.chunkCount > 0)
    }

}
