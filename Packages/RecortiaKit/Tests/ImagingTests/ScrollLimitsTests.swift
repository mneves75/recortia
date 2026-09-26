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
    }

    @Test("Scroll, render, and import pixel bounds stay coupled so none can drift silently")
    func limitsAreCoupled() {
        #expect(ScrollLimits.default.maxOutputArea == RenderLimits.maxOutputPixels)
        #expect(ScrollLimits.default.maxOutputArea == ImportLimits.maxPixelArea)
        #expect(RenderLimits.maxOutputPixels == ImportLimits.maxPixelArea)
        #expect(ScrollLimits.default.maxSide == RenderLimits.maxOutputSide)
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
                    <= outputBytes + 2 * frameBytes + ScrollStitcher.workingBudgetBytes(forFrameWidth: fixture.width))
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

    @Test("32,768 side: a wider viewport is refused under default limits")
    func side() throws {
        var stitcher = ScrollStitcher()
        #expect(stitcher.append(try Self.blankFrame(width: 32_769, height: 8), elapsed: .zero) == .limitReached(.side))
    }

    @Test("20,000 default height: collection stops before the output exceeds it, and the partial output is exact")
    func height() throws {
        let fixture = ScrollPageFixture(
            seed: 53, width: 40, viewportHeight: 420, headerHeight: 20, footerHeight: 12, pageHeight: 21_000,
            animated: false)
        var stitcher = ScrollStitcher()
        var offset = 0, index = 0
        var last = ScrollAppendResult.stationary
        var lastAccepted = 0
        while offset <= fixture.maxOffset {
            last = stitcher.append(try #require(fixture.frame(offset: offset, index: index)), elapsed: .zero)
            if case .limitReached = last { break }
            #expect(last.isAccepted, "frame \(index): \(last)")
            lastAccepted = offset
            offset += 190
            index += 1
        }
        #expect(last == .limitReached(.height))
        #expect(stitcher.outputSize.height <= 20_000)
        #expect(stitcher.outputSize.height + 190 > 20_000)
        let image = try stitcher.assemble()
        #expect(image.height == stitcher.outputSize.height)
        let output = try #require(ScrollHarness.rgba(image))
        let bad = ScrollHarness.mismatchedRows(
            output: output, expected: fixture.expectedOutput(lastOffset: lastAccepted), fixture: fixture)
        #expect(bad.isEmpty, "\(bad.prefix(5))")
    }

    @Test(
        "Each limit ends collection independently mid-session", arguments: [ScrollLimit.area, .side, .height, .frames])
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
        case .duration: break
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

    @Test("When one frame crosses several limits, the first in FR-10 order wins")
    func firstLimitWins() throws {
        let fixture = ScrollPageFixture(
            seed: 55, width: 100, viewportHeight: 200, headerHeight: 20, footerHeight: 10, pageHeight: 800)
        let limits = ScrollLimits(
            maxDuration: .seconds(1), maxAcceptedFrames: 1, maxOutputArea: 100 * 210, maxSide: 210,
            defaultMaxHeight: 210)
        var stitcher = ScrollStitcher(limits: limits)
        #expect(
            stitcher.append(try #require(fixture.frame(offset: 0, index: 0)), elapsed: .zero) == .accepted(offset: 0))
        #expect(
            stitcher.append(try #require(fixture.frame(offset: 40, index: 1)), elapsed: .seconds(2))
                == .limitReached(.duration))

        var framesFirst = ScrollStitcher(
            limits: ScrollLimits(maxAcceptedFrames: 1, maxOutputArea: 100 * 210, maxSide: 210, defaultMaxHeight: 210))
        _ = framesFirst.append(try #require(fixture.frame(offset: 0, index: 0)), elapsed: .zero)
        #expect(
            framesFirst.append(try #require(fixture.frame(offset: 40, index: 1)), elapsed: .zero)
                == .limitReached(.frames))
    }
}
