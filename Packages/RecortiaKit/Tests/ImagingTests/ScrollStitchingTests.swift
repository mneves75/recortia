import CoreGraphics
import Domain
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("SCR-01: deterministic stitching fixtures")
struct ScrollStitchingTests {
    /// Development seeds (the held-out set lives in ScrollCalibrationTests).
    static let developmentSeeds: [UInt64] = [1, 2, 3, 4, 5, 6]

    @Test("End of page: no movement over consecutive frames is detected, movement resets it")
    func endOfPage() {
        let fixture = ScrollPageFixture(seed: 12, pageHeight: 700)
        var stitcher = ScrollStitcher()
        let end = fixture.maxOffset
        let offsets = [0, 100, 100, 200, 300, 400, end, end, end, end]
        var detections: [Bool] = []
        for (index, offset) in offsets.enumerated() {
            guard let frame = fixture.frame(offset: offset, index: index) else { return }
            _ = stitcher.append(frame, elapsed: .milliseconds(index * 100))
            detections.append(stitcher.endOfPageDetected)
        }
        #expect(detections == [false, false, false, false, false, false, false, false, false, true])
        #expect(ScrollStitcher.endOfPageStationaryFrames == 3)
    }

    @Test("Preview is bounded by maxHeight, keeps aspect ratio, and is nil before any frame")
    func preview() throws {
        var stitcher = ScrollStitcher()
        #expect(stitcher.preview(maxHeight: 100) == nil)
        #expect(throws: ScrollStitchError.noFrames) { try stitcher.assemble() }
        let fixture = ScrollPageFixture(seed: 13, pageHeight: 1200)
        for (index, offset) in [0, 100, 200, 300, 400].enumerated() {
            _ = stitcher.append(try #require(fixture.frame(offset: offset, index: index)), elapsed: .zero)
        }
        let size = stitcher.outputSize
        let preview = try #require(stitcher.preview(maxHeight: 200))
        #expect(preview.height <= 200)
        let expectedWidth = Double(size.width) * Double(preview.height) / Double(size.height)
        #expect(abs(Double(preview.width) - expectedWidth) <= 1)
        let full = try #require(stitcher.preview(maxHeight: 100_000))
        #expect(full.width == size.width && full.height == size.height)
        #expect(stitcher.preview(maxHeight: 0) == nil)
    }

    @Test("Fixed header and footer appear exactly once and seams copy source rows without blending")
    func bandsAppearOnce() throws {
        let fixture = ScrollPageFixture(
            seed: 14, headerHeight: 48, footerHeight: 32, pageHeight: 1000, animated: false, noisy: false)
        var stitcher = ScrollStitcher()
        let offsets = [0, 37, 81, 150, 222, 300, 377, 460, 540, 620, 700, fixture.maxOffset]
        let log = ScrollHarness.run(
            fixture, frames: ScrollHarness.script(fixture, offsets: offsets), stitcher: &stitcher)
        #expect(log.falseAccepts.isEmpty && log.pauses.isEmpty, "\(log.falseAccepts) \(log.pauses)")
        let output = try #require(ScrollHarness.rgba(try stitcher.assemble()))
        let expected = fixture.expectedOutput(lastOffset: fixture.maxOffset)
        // Noise-free frames: the output must be bit-identical, which rules out blending at seams.
        #expect(output == expected)
    }
}
