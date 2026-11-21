import Domain
import Foundation
import MacPlatform
import Testing

@testable import Features

// Failure modes (FR-02, A-4): window frames for snapping that outlive their selection or arrive
// for a canceled one; a listing failure that ends the selection instead of only disabling window
// snapping; an aspect choice that is not remembered; nudge steps taken in pixels instead of
// points, or that cross a display edge at a negative desktop origin.
@Suite("Region selection precision in capture (FR-02, A-4)")
@MainActor
struct RegionPrecisionCaptureTests {
    @Test("A region selection lists window frames to snap to and forgets them when it ends")
    func listsSnapFrames() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        await waitFor("frames") { h.coordinator.snapFrames == [TestFixtures.window.frame] }
        #expect(h.capture.windowCalls == 1)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        #expect(h.coordinator.snapFrames.isEmpty)

        let display = CaptureHarness()
        display.capture.displayList = [TestFixtures.primaryDisplay, TestFixtures.leftDisplay]
        display.coordinator.start(.display)
        await drain()
        #expect(display.capture.windowCalls == 0)
        #expect(display.coordinator.snapFrames.isEmpty)
    }

    @Test("A late or failed window list never reaches another selection or ends this one")
    func staleOrFailedFrames() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        h.coordinator.cancel()
        await drain()
        #expect(h.coordinator.snapFrames.isEmpty)

        let failed = CaptureHarness()
        failed.capture.windowResult = .failure(.permissionDenied)
        failed.coordinator.start(.region)
        await waitFor("listed") { failed.capture.windowCalls == 1 }
        await drain()
        #expect(failed.coordinator.state == .selecting)
        #expect(failed.coordinator.snapFrames.isEmpty)
        #expect(failed.coordinator.commitRegion(failed.regionRect, on: TestFixtures.primaryDisplay))
    }

    @Test("The chosen ratio is remembered as a preference")
    func remembersAspect() {
        let h = CaptureHarness()
        #expect(h.coordinator.regionAspect == .free)
        h.coordinator.setRegionAspect(.sixteenByNine)
        #expect(h.settings.preferences.regionAspect == .sixteenByNine)
        #expect(CaptureHarness().coordinator.regionAspect == .free)
    }

    @Test("Nudges are in points: 2 px on the 2x display, 1 px on the 1x one, and stop at its edge")
    func nudgesInPoints() {
        func resized(_ rect: Rect<DesktopSpace>, on display: DisplayInfo) -> PixelSize {
            RegionSelection.pixelSize(
                of: RegionPrecision.nudged(
                    rect, .right, keys: SelectionKeys(option: true), aspect: .free, within: display.frame,
                    minimumSide: RegionSelection.minimumSide), on: display)
        }
        let retina = Rect<DesktopSpace>(x: 100, y: 100, width: 50, height: 40)
        #expect(resized(retina, on: TestFixtures.primaryDisplay) == PixelSize(width: 102, height: 80))
        let left = TestFixtures.leftDisplay
        let standard = Rect<DesktopSpace>(x: -1000, y: -100, width: 50, height: 40)
        #expect(resized(standard, on: left) == PixelSize(width: 51, height: 40))
        let moved = RegionPrecision.nudged(
            Rect<DesktopSpace>(x: -1915, y: -195, width: 50, height: 40), .left, keys: SelectionKeys(shift: true),
            aspect: .free, within: left.frame, minimumSide: RegionSelection.minimumSide)
        #expect(moved == Rect(x: -1920, y: -195, width: 50, height: 40))
    }
}
