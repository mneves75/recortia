import CoreGraphics
import Foundation
import RecortiaFixtures
import Testing

@testable import Imaging

// Failure modes (audit hardening): `decide` indexes both frames with the current frame's geometry
// and the region's rows. A caller passing frames of different sizes, or a region outside the
// frame, must get a pause, never a slice or vDSP trap.
@Suite("ScrollMatcher.decide rejects inconsistent geometry")
struct ScrollMatcherContractTests {
    /// A textured viewport, so a pause can only come from the geometry check.
    private func frame(width: Int, height: Int) throws -> ScrollFrame {
        let fixture = ScrollPageFixture(seed: 5, width: width, viewportHeight: height)
        let image = try #require(fixture.frame(offset: 0, index: 0))
        return try #require(ScrollFrame(image: image))
    }

    @Test("Frames of different sizes pause")
    func mismatchedSizes() throws {
        let previous = try frame(width: 64, height: 240)
        let current = try frame(width: 96, height: 240)
        #expect(ScrollMatcher.decide(previous: previous, current: current, region: 0..<240) == .pause(.lowConfidence))
        let shorter = try frame(width: 96, height: 120)
        #expect(ScrollMatcher.decide(previous: shorter, current: current, region: 0..<240) == .pause(.lowConfidence))
    }

    @Test("A region outside the frame pauses")
    func regionOutsideFrame() throws {
        let previous = try frame(width: 96, height: 240)
        let current = try frame(width: 96, height: 240)
        #expect(ScrollMatcher.decide(previous: previous, current: current, region: 0..<480) == .pause(.lowConfidence))
        #expect(ScrollMatcher.decide(previous: previous, current: current, region: -40..<200) == .pause(.lowConfidence))
    }

    @Test("Control: consistent identical frames are stationary")
    func consistentControl() throws {
        let previous = try frame(width: 96, height: 240)
        let current = try frame(width: 96, height: 240)
        #expect(ScrollMatcher.decide(previous: previous, current: current, region: 0..<240) == .stationary)
    }
}
