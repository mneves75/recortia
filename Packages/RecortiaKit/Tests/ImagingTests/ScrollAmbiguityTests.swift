import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("SCR-02: ambiguous and partial results never report a false success")
struct ScrollAmbiguityTests {
    @Test("Low-texture page pauses instead of guessing", arguments: [UInt64(21), 22, 23])
    func lowTexture(seed: UInt64) {
        let fixture = ScrollPageFixture(seed: seed, kind: .lowTexture, pageHeight: 1600, animated: false)
        let offsets = fixture.forwardOffsets(steps: 10...90, stationaryChance: 0)
        var stitcher = ScrollStitcher()
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        #expect(log.movedButStationary.isEmpty, "\(log.movedButStationary)")
        #expect(!log.pauses.isEmpty)
        #expect(log.pauses.allSatisfy { $0.reason == .lowConfidence || $0.reason == .ambiguousMatch })
    }

    @Test("Identical repeated rows are an ambiguous match", arguments: [UInt64(31), 32, 33])
    func repeatedRows(seed: UInt64) throws {
        let fixture = ScrollPageFixture(seed: seed, kind: .repeatedRows, pageHeight: 1600)
        let period = try #require(fixture.repeatPeriod)
        let offsets = fixture.forwardOffsets(steps: 5...80, stationaryChance: 0)
        var stitcher = ScrollStitcher()
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        // A shift by a whole period is pixel-identical to no shift; anything else must not look stationary.
        let unexplained = log.movedButStationary.filter { index in
            guard let last = log.lastAcceptedOffset else { return true }
            return (offsets[index] - last) % period != 0
        }
        #expect(unexplained.isEmpty)
        #expect(log.pauses.contains { $0.reason == .ambiguousMatch })
        #expect(log.acceptedCount == 1, "only the first frame can be accepted on a periodic page")
    }

    @Test("Insufficient overlap and frame gaps pause with low confidence")
    func insufficientOverlap() {
        let fixture = ScrollPageFixture(seed: 41, pageHeight: 2000)
        let content = fixture.contentHeight
        for jump in [content - 8, content, content + 150] {
            var stitcher = ScrollStitcher()
            let offsets = [0, 60, 60 + jump, 60 + jump + 40]
            let log = ScrollHarness.run(
                fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
            #expect(log.falseAccepts.isEmpty, "jump \(jump): \(log.falseAccepts)")
            #expect(log.results[2] == .ambiguous(.lowConfidence), "jump \(jump): \(log.results)")
            // Still disconnected from the last accepted frame: remains paused.
            #expect(log.results[3] != .accepted(offset: jump + 40) || jump + 40 < content - 40)
        }
    }

    @Test("A frame gap followed by frames that overlap again resumes correctly")
    func frameGapRecovery() throws {
        let fixture = ScrollPageFixture(seed: 42, pageHeight: 1600)
        let offsets = [0, 50, 100, 100 + fixture.contentHeight + 20, 150, 200, 260]
        var stitcher = ScrollStitcher()
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        #expect(log.results[3] == .ambiguous(.lowConfidence))
        #expect(log.results[4] == .accepted(offset: 50))
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let bad = ScrollHarness.mismatchedRows(
            output: output, expected: fixture.expectedOutput(lastOffset: 260), fixture: fixture)
        #expect(bad.isEmpty, "\(bad.prefix(5))")
    }

    @Test("Reverse scrolling pauses and never duplicates content")
    func reverse() throws {
        let fixture = ScrollPageFixture(seed: 43, pageHeight: 1600)
        let offsets = [0, 60, 130, 90, 40, 130, 200]
        var stitcher = ScrollStitcher()
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        #expect(log.results[3] == .ambiguous(.reversedDirection))
        #expect(log.results[4] == .ambiguous(.reversedDirection))
        #expect(log.results[5] == .stationary)
        #expect(log.results[6] == .accepted(offset: 70))
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let bad = ScrollHarness.mismatchedRows(
            output: output, expected: fixture.expectedOutput(lastOffset: 200), fixture: fixture)
        #expect(bad.isEmpty, "\(bad.prefix(5))")
    }

    @Test("Lazy-load reflow inside the viewport pauses; the output stays consistent with one page layout")
    func lazyLoadReflow() throws {
        let fixture = ScrollPageFixture(seed: 44, pageHeight: 1800)
        let content = fixture.contentHeight
        let insertAt = 420, inserted = 60
        let reflowed = fixture.reflowedPage(insertingRows: inserted, at: insertAt)
        var frames = [0, 80, 160, 240].map { ScrollScriptFrame(offset: $0) }
        // The block loads while the insertion row is visible (240 + content > 420), with and without scrolling.
        for offset in [240, 280, 330, 420, 480, 540, 600] {
            frames.append(
                ScrollScriptFrame(
                    reflowedOffset: offset, page: reflowed, insertAt: insertAt, rows: inserted, contentHeight: content))
        }
        var stitcher = ScrollStitcher()
        let log = ScrollHarness.run(fixture, frames: frames, stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        #expect(log.results[4] != .stationary && !log.results[4].isAccepted, "\(log.results[4])")
        #expect(log.results[5].isPause && log.results[6].isPause, "\(log.results)")
        let last = try #require(log.lastAcceptedOffset)
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let bad = ScrollHarness.mismatchedRows(
            output: output, expected: fixture.expectedOutput(lastOffset: last), fixture: fixture)
        #expect(bad.isEmpty, "\(bad.prefix(5))")
    }

    @Test("Tiny viewports may pause for lack of evidence but never mis-stitch")
    func tinyViewport() throws {
        let fixture = ScrollPageFixture(
            seed: 52, width: 48, viewportHeight: 140, headerHeight: 16, footerHeight: 8, pageHeight: 3000)
        var rng = ScrollPageRandom(seed: 52)
        var offsets = [0]
        while offsets.count < 90 {
            offsets.append(min(fixture.maxOffset, offsets[offsets.count - 1] + Int.random(in: 8...30, using: &rng)))
        }
        var stitcher = ScrollStitcher()
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty, "\(log.falseAccepts)")
        #expect(log.movedButStationary.isEmpty, "\(log.movedButStationary)")
        let last = try #require(log.lastAcceptedOffset)
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let bad = ScrollHarness.mismatchedRows(
            output: output, expected: fixture.expectedOutput(lastOffset: last), fixture: fixture)
        #expect(bad.isEmpty, "\(bad.prefix(5))")
        print(
            "SCR-02 tiny viewport 48x140: \(log.acceptedCount) of \(offsets.count) frames accepted, \(log.pauses.count) pauses, 0 false accepts"
        )
    }

    @Test("A frame with different dimensions is rejected")
    func sizeChange() throws {
        let fixture = ScrollPageFixture(seed: 45, pageHeight: 900)
        let other = ScrollPageFixture(seed: 45, width: 200, pageHeight: 900)
        var stitcher = ScrollStitcher()
        #expect(
            stitcher.append(try #require(fixture.frame(offset: 0, index: 0)), elapsed: .zero) == .accepted(offset: 0))
        #expect(
            stitcher.append(try #require(other.frame(offset: 40, index: 1)), elapsed: .zero)
                == .ambiguous(.lowConfidence))
        #expect(
            stitcher.append(try #require(fixture.frame(offset: 40, index: 2)), elapsed: .zero) == .accepted(offset: 40))
    }
}

extension ScrollAppendResult {
    var isAccepted: Bool { if case .accepted = self { true } else { false } }
    var isPause: Bool { if case .ambiguous = self { true } else { false } }
}
