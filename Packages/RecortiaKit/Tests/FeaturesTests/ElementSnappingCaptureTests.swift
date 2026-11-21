import Domain
import Foundation
import MacPlatform
import Testing

@testable import Features

// Failure modes (FR-02, B-7, ADR-010): element frames read without the setting, or kept after the
// selection that asked for them ended; a late read from a cancelled or committed selection, or from
// an earlier request, landing in the current one; an unreadable app or a failed window list that
// takes window and display snapping down with it; tiny or off-display elements becoming targets.
@Suite("Interface element snapping in capture (FR-02, B-7)")
@MainActor
struct ElementSnappingCaptureTests {
    private let button = Rect<DesktopSpace>(x: 40, y: 60, width: 120, height: 28)

    private func walk(_ frames: [Rect<DesktopSpace>]) -> ElementSnapping.Walk {
        ElementSnapping.Walk(frames: frames, visited: frames.count + 2, stoppedBy: nil)
    }

    private func snapping(_ h: CaptureHarness) -> CaptureHarness {
        h.settings.update { $0.snapsToInterfaceElements = true }
        return h
    }

    @Test("Snapping to interface elements is off by default, and off reads nothing")
    func offByDefault() async {
        let h = CaptureHarness()
        #expect(!h.settings.preferences.snapsToInterfaceElements)
        h.elements.result = walk([button])
        h.coordinator.start(.region)
        await waitFor("window frames") { h.coordinator.snapFrames == [TestFixtures.window.frame] }
        await drain()
        #expect(h.elements.calls.isEmpty)
        #expect(h.coordinator.snapFrames == [TestFixtures.window.frame])
    }

    @Test("With the setting on, admitted element frames join the window frames for this selection only")
    func joinsWindowFrames() async {
        let h = snapping(CaptureHarness())
        let tiny = Rect<DesktopSpace>(x: 40, y: 60, width: 6, height: 28)
        let offDisplay = Rect<DesktopSpace>(x: 4000, y: 60, width: 120, height: 28)
        h.elements.result = walk([button, tiny, offDisplay])
        h.coordinator.start(.region)
        await waitFor("element frames") { h.coordinator.snapFrames == [TestFixtures.window.frame, button] }
        #expect(h.elements.calls == [[TestFixtures.window]])
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        #expect(h.coordinator.snapFrames.isEmpty)
    }

    @Test("A read that finishes after Escape or commit is discarded")
    func lateResultAfterEnd() async {
        for ending in ["cancel", "commit"] {
            let h = snapping(CaptureHarness())
            let pending = Pending<ElementSnapping.Walk?>()
            h.elements.pending = pending
            h.coordinator.start(.region)
            await waitFor("read started") { pending.waiterCount == 1 }
            if ending == "cancel" {
                h.coordinator.cancel()
            } else {
                h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
            }
            pending.resolve(walk([button]))
            await drain()
            #expect(h.coordinator.snapFrames.isEmpty, "\(ending)")
        }
    }

    @Test("A late read from an earlier request never reaches the next selection")
    func lateResultFromEarlierRequest() async {
        let h = snapping(CaptureHarness())
        let pending = Pending<ElementSnapping.Walk?>()
        h.elements.pending = pending
        h.coordinator.start(.region)
        await waitFor("first read started") { pending.waiterCount == 1 }
        h.coordinator.cancel()
        h.coordinator.start(.region)
        await waitFor("second read started") { pending.waiterCount == 2 }
        let earlier = Rect<DesktopSpace>(x: 500, y: 500, width: 90, height: 30)
        pending.resolve(walk([earlier]))
        await drain()
        #expect(h.coordinator.snapFrames == [TestFixtures.window.frame])
        pending.resolve(walk([button]))
        await waitFor("current frames") { h.coordinator.snapFrames == [TestFixtures.window.frame, button] }
        #expect(!h.coordinator.snapFrames.contains(earlier))
    }

    @Test("An unreadable app or a failed window list leaves window and display snapping intact")
    func failureKeepsOtherGuides() async {
        let unreadable = snapping(CaptureHarness())
        unreadable.elements.result = nil
        unreadable.coordinator.start(.region)
        await waitFor("read") { unreadable.elements.calls.count == 1 }
        await drain()
        #expect(unreadable.coordinator.snapFrames == [TestFixtures.window.frame])
        let display = TestFixtures.primaryDisplay.frame
        #expect(
            RegionPrecision.guides(within: display, frames: unreadable.coordinator.snapFrames)
                == RegionPrecision.guides(within: display, frames: [TestFixtures.window.frame]))
        #expect(unreadable.coordinator.state == .selecting)

        let unlisted = snapping(CaptureHarness())
        unlisted.capture.windowResult = .failure(.permissionDenied)
        unlisted.elements.result = walk([button])
        unlisted.coordinator.start(.region)
        await waitFor("listed") { unlisted.capture.windowCalls == 1 }
        await drain()
        #expect(unlisted.elements.calls.isEmpty)
        #expect(unlisted.coordinator.snapFrames.isEmpty)
        #expect(unlisted.coordinator.state == .selecting)
        #expect(unlisted.coordinator.commitRegion(unlisted.regionRect, on: TestFixtures.primaryDisplay))
    }

    @Test("Switching to a window selection discards a read in progress")
    func switchToWindowDiscards() async {
        let h = snapping(CaptureHarness())
        let pending = Pending<ElementSnapping.Walk?>()
        h.elements.pending = pending
        h.coordinator.start(.region)
        await waitFor("read started") { pending.waiterCount == 1 }
        #expect(h.coordinator.switchToWindowSelection())
        pending.resolve(walk([button]))
        await drain()
        #expect(h.coordinator.snapFrames.isEmpty)
    }
}
