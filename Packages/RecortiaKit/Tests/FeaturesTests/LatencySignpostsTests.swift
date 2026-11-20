import Testing

@testable import Features

// Failure modes (FR-14, A-13 step 1): an interval that never closes, so Instruments reports
// nothing, or an end without a begin that closes another request's interval.
@Suite("Latency signposts (FR-14, A-13)")
@MainActor
struct LatencySignpostsTests {
    @Test("An interval stays open from begin to end; ending one never begun does nothing")
    func pairing() {
        LatencySignposts.end(.captureToEditor)
        #expect(!LatencySignposts.isOpen(.captureToEditor))
        LatencySignposts.begin(.captureToEditor)
        LatencySignposts.begin(.captureToEditor)
        #expect(LatencySignposts.isOpen(.captureToEditor))
        #expect(!LatencySignposts.isOpen(.editorToFirstDraw))
        LatencySignposts.end(.captureToEditor)
        #expect(!LatencySignposts.isOpen(.captureToEditor))
    }
}
