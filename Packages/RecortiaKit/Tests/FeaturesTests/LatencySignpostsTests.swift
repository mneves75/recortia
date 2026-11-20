import CoreGraphics
import Domain
import MacPlatform
import Testing

@testable import Features

// Failure modes (FR-14, A-13 step 1): an interval that never closes, a stale request that closes
// its successor's interval, or a capture without an overlay that leaves the overlay interval open.
@Suite("Latency signposts (FR-14, A-13)")
@MainActor
struct LatencySignpostsTests {
    @Test("Each interval is its own: ending one leaves another of the same kind open, and ends once")
    func independentIntervals() {
        let first = LatencySignposts.begin(.captureToEditor)
        let second = LatencySignposts.begin(.captureToEditor)
        first.end()
        #expect(!first.isOpen && second.isOpen)
        first.end()
        second.abandon()
        #expect(!second.isOpen)
    }

    @Test("A stale capture's completion closes only its own interval")
    func staleCompletion() async {
        let h = CaptureHarness()
        let pending = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = pending
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("first capture") { pending.waiterCount == 1 }
        h.coordinator.cancel()
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("second capture") { pending.waiterCount == 2 }
        #expect(h.coordinator.openLatencyIntervals == [.selectionToCapture, .selectionToCapture])
        guard let image = makeImage() else { return }
        let target = CaptureTarget.region(h.regionRect, display: TestFixtures.primaryDisplay)
        pending.resolve(.success((image, TestFixtures.geometry(for: target))))
        await waitFor("stale capture returned") { h.coordinator.openLatencyIntervals.count == 1 }
        #expect(h.coordinator.openLatencyIntervals == [.selectionToCapture])
        pending.resolve(.success((image, TestFixtures.geometry(for: target))))
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.coordinator.openLatencyIntervals.isEmpty)
    }

    @Test("The overlay interval stays open until the overlay appears; a capture without one closes it")
    func overlayInterval() async {
        let region = CaptureHarness()
        region.coordinator.start(.region)
        #expect(region.coordinator.openLatencyIntervals == [.startToOverlay])
        region.coordinator.selectionDidAppear()
        #expect(region.coordinator.openLatencyIntervals.isEmpty)

        let display = CaptureHarness()
        display.capture.displayList = [TestFixtures.primaryDisplay]
        display.coordinator.start(.display)
        await waitFor("captured") { display.completions.count == 1 }
        #expect(display.coordinator.openLatencyIntervals.isEmpty)

        let canceled = CaptureHarness()
        canceled.coordinator.start(.region)
        canceled.coordinator.cancel()
        #expect(canceled.coordinator.openLatencyIntervals.isEmpty)
    }
}
