import Accelerate
import CoreGraphics
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Failure modes (SCR-04): a measure over a whole region or overlap allocating full-plane
// temporaries (about 160 MB each near the permitted frame size); chunk boundaries that drop or
// double-count pixels; a last partial chunk; slices whose indices do not start at zero; texture
// pairs that straddle chunk or row edges; a stitcher path (band detection, stationarity) that
// bypasses the chunked measures. Each is covered below.
@Suite("SCR-04: matching scratch memory is bounded by chunks, whatever the frame size")
struct ScrollMatcherMemoryTests {
    static let tolerance = ScrollMatcher.Thresholds.calibrated.pixelTolerance

    // MARK: Reference: the unchunked math the chunked measures must reproduce exactly

    static func referenceChangedFraction(_ differences: [Float], tolerance: Float) -> Double {
        guard !differences.isEmpty else { return 0 }
        let signs = vDSP.threshold(vDSP.absolute(differences), to: tolerance, with: .signedConstant(1))
        let n = Double(differences.count)
        return (Double(vDSP.sum(signs)) + n) / (2 * n)
    }

    static func referenceError(
        previous: ScrollFrame, current: ScrollFrame, rows: Range<Int>, displacement d: Int, tolerance: Float
    ) -> Double {
        guard !rows.isEmpty, rows.lowerBound + d >= 0, rows.upperBound + d <= previous.height else { return 1 }
        let a = current.lumaRows(rows)
        let b = previous.lumaRows((rows.lowerBound + d)..<(rows.upperBound + d))
        return referenceChangedFraction(vDSP.subtract(a, b), tolerance: tolerance)
    }

    static func referenceTexture(_ frame: ScrollFrame, rows: Range<Int>, tolerance: Float) -> Double {
        let plane = frame.lumaRows(rows)
        guard plane.count > frame.width else { return 0 }
        let horizontal = vDSP.subtract(plane.dropFirst(), plane.dropLast())
        let vertical = vDSP.subtract(plane.dropFirst(frame.width), plane.dropLast(frame.width))
        return
            (referenceChangedFraction(horizontal, tolerance: tolerance)
            + referenceChangedFraction(vertical, tolerance: tolerance)) / 2
    }

    /// Two seeded random frames: `current` is `previous` with about half its pixels shifted by up
    /// to ±40 levels, so every tolerance sees a mix of changed and unchanged pixels.
    static func randomPair(width: Int, height: Int, seed: UInt64) throws -> (ScrollFrame, ScrollFrame) {
        var rng = ScrollPageRandom(seed: seed)
        var a = [UInt8](repeating: 255, count: width * height * 4)
        var b = a
        for i in stride(from: 0, to: a.count, by: 4) {
            let bits = rng.next()
            for c in 0..<3 {
                a[i + c] = UInt8(truncatingIfNeeded: bits >> (UInt64(c) * 8))
                let shift = bits >> 40 & 1 == 0 ? 0 : Int((bits >> (UInt64(c) * 5 + 44)) % 81) - 40
                b[i + c] = UInt8(clamping: Int(a[i + c]) + shift)
            }
        }
        let previous = try #require(
            ScrollPageFixture.image(from: ScrollPageBuffer(width: width, height: height, pixels: a)))
        let current = try #require(
            ScrollPageFixture.image(from: ScrollPageBuffer(width: width, height: height, pixels: b)))
        return (try #require(ScrollFrame(image: previous)), try #require(ScrollFrame(image: current)))
    }

    // MARK: Equivalence

    @Test("Chunked changed counts equal a direct count for every chunk size and slice offset")
    func changedCountEquivalence() {
        var rng = ScrollPageRandom(seed: 91)
        let n = 5_000
        let a = (0..<(n + 9)).map { _ in Float(rng.next() % 256) }
        let b = (0..<(n + 9)).map { _ in Float(rng.next() % 256) }
        for tolerance: Float in [0.5, 16, 100] {
            for (start, count) in [(0, n), (3, n), (9, n - 1), (5, 1), (0, 0)] {
                let x = a[start..<(start + count)]
                let y = b[(start + 1)..<(start + 1 + count)]
                let expected = zip(x, y).filter { abs($0 - $1) >= tolerance }.count
                for chunk in [1, 2, 3, 7, 64, 1000, count - 1, count, count + 1, ScrollMatcher.scratchElements]
                where chunk > 0 {
                    #expect(
                        ScrollMatcher.changedCount(x, y, tolerance: tolerance, chunkElements: chunk) == expected,
                        "tolerance \(tolerance), slice \(start)+\(count), chunk \(chunk)")
                }
            }
        }
    }

    @Test("error and texture are bit-identical to the unchunked math on random frames spanning many chunks")
    func measuresEquivalence() throws {
        // 700 x 400 = 280,000 luma values: several default chunks, with boundaries inside rows.
        let (previous, current) = try Self.randomPair(width: 700, height: 400, seed: 92)
        #expect(previous.width * previous.height > 4 * ScrollMatcher.scratchElements)
        for tolerance: Float in [1, Self.tolerance, 40] {
            for (rows, d) in [
                (0..<400, 0), (0..<300, 100), (100..<400, -100), (37..<361, 13), (5..<6, 0), (0..<1, 399),
                (399..<400, -399), (200..<200, 0), (0..<400, 1),
            ] {
                #expect(
                    ScrollMatcher.error(
                        previous: previous, current: current, rows: rows, displacement: d, tolerance: tolerance)
                        == Self.referenceError(
                            previous: previous, current: current, rows: rows, displacement: d, tolerance: tolerance),
                    "rows \(rows), d \(d), tolerance \(tolerance)")
            }
            for rows in [0..<400, 1..<399, 94..<95, 94..<96, 123..<311] {
                #expect(
                    ScrollMatcher.texture(current, rows: rows, tolerance: tolerance)
                        == Self.referenceTexture(current, rows: rows, tolerance: tolerance),
                    "rows \(rows), tolerance \(tolerance)")
            }
        }
    }

    // MARK: Bound

    /// A tall, wide textured viewport: its scrolling region holds far more luma values than one chunk.
    static let large = ScrollPageFixture(
        seed: 93, width: 1024, viewportHeight: 1000, headerHeight: 40, footerHeight: 24, pageHeight: 1400)

    static func largeFrame(offset: Int, index: Int) throws -> ScrollFrame {
        let image = try #require(large.frame(offset: offset, index: index))
        return try #require(ScrollFrame(image: image))
    }

    @Test("decide over a region many chunks tall keeps every temporary within the working budget")
    func decideIsBounded() throws {
        let previous = try Self.largeFrame(offset: 0, index: 0)
        let current = try Self.largeFrame(offset: 90, index: 1)
        let region = Self.large.headerHeight..<(Self.large.viewportHeight - Self.large.footerHeight)
        #expect(region.count * Self.large.width > 10 * ScrollMatcher.scratchElements)
        let probe = ScrollMatcher.ScratchProbe()
        let decision = ScrollMatcher.$scratchProbe.withValue(probe) {
            ScrollMatcher.decide(previous: previous, current: current, region: region)
        }
        #expect(decision == .displacement(90))
        #expect(probe.chunkCount > 0, "the probe must observe the measures")
        #expect(probe.largestChunk <= ScrollMatcher.scratchElements, "largest chunk \(probe.largestChunk)")
        #expect(
            ScrollMatcher.scratchTemporaries * probe.largestChunk * MemoryLayout<Float>.stride
                <= ScrollStitcher.workingBudgetBytes)
    }

    @Test("Every stitcher path (bands, stationarity, motion before bands, decide) stays within the budget")
    func stitcherPathsAreBounded() throws {
        let probe = ScrollMatcher.ScratchProbe()
        try ScrollMatcher.$scratchProbe.withValue(probe) {
            // Motion evidence before any band is known: textures and errors over long runs of rows.
            let previous = try Self.largeFrame(offset: 0, index: 0)
            let moved = try Self.largeFrame(offset: 90, index: 1)
            #expect(!ScrollMatcher.changedRowsAreStationary(previous: previous, current: moved))
            #expect(
                ScrollMatcher.texture(moved, rows: 0..<Self.large.viewportHeight, tolerance: Self.tolerance) > 0)

            var stitcher = ScrollStitcher()
            var results: [ScrollAppendResult] = []
            for (index, offset) in [0, 0, 90, 90, 200].enumerated() {
                let image = try #require(Self.large.frame(offset: offset, index: index))
                results.append(stitcher.append(image, elapsed: .zero))
            }
            #expect(
                results == [
                    .accepted(offset: 0), .stationary, .accepted(offset: 90), .stationary, .accepted(offset: 110),
                ])
        }
        #expect(probe.chunkCount > 0)
        #expect(probe.largestChunk <= ScrollMatcher.scratchElements, "largest chunk \(probe.largestChunk)")
    }
}
