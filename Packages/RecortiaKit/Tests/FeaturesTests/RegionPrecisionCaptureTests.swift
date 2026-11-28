import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform
import RecortiaFixtures
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

    @Test("Frozen selection commits the same display pixels, aligned outward at its negative origin (FR-02, A-5)")
    func frozenCommitUsesOriginalFrame() async throws {
        let h = CaptureHarness()
        let store = ImageStore()
        h.assets.store = store
        let registration = Pending<Void>()
        h.assets.pendingCanonicalRegistration = registration
        var fixture: (DisplayInfo, CGImage, CaptureGeometry)? = try autoreleasepool { try frozenFixture() }
        let display = try #require(fixture?.0)
        let geometry = try #require(fixture?.2)
        weak let wholeFrame = fixture?.1
        #expect(wholeFrame != nil)
        h.capture.displayList = [display]
        let read = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = read
        h.coordinator.start(.region)
        #expect(h.capture.captureCalls.isEmpty)
        h.coordinator.toggleRegionFreeze(on: display)
        await waitFor("display read") { read.waiterCount == 1 }
        let resolved = read.resolve(.success((try #require(fixture?.1), geometry)))
        #expect(resolved)
        fixture = nil
        await waitFor("frozen preview") {
            if case .frozen = h.coordinator.regionFreeze { return true }
            return false
        }
        #expect(h.coordinator.commitRegion(Rect(x: -28.75, y: -14.75, width: 3, height: 2), on: display))
        await waitFor("canonical crop reached registration") { registration.waiterCount == 1 }
        #expect(wholeFrame == nil)
        #expect(h.completions.isEmpty)
        #expect(registration.resolve(()))
        await waitFor("one committed crop") { h.completions.count == 1 }
        #expect(h.capture.captureCalls == [.display(display)])
        #expect(h.coordinator.regionFreeze == nil)
        let asset = try #require(h.assets.registeredCaptures.first)
        #expect(
            asset.origin
                == .captured(
                    CaptureGeometry(
                        source: .region(displayID: display.id),
                        desktopBounds: Rect(x: -29, y: -15, width: 3.5, height: 2.5), pointPixelScale: 2,
                        pixelSize: PixelSize(width: 7, height: 5), capturedAt: geometry.capturedAt)))
        let stored = await store.images(for: [asset.id])
        let pixels = try ContainerInspector.pixels(of: #require(stored[asset.id]))
        #expect(pixels.width == 7 && pixels.height == 5)
        #expect(pixels.pixel(x: 0, y: 0) == ChartFixture.Color(16, 16, 0))
        #expect(pixels.pixel(x: 6, y: 4) == ChartFixture.Color(64, 48, 0))
    }

    @Test("Frozen pixels expire at 60 seconds even if the timer has not resumed", arguments: [true, false])
    func expiredFrozenSelectionCannotCommit(timerResumes: Bool) async throws {
        let h = CaptureHarness()
        let (display, frame, geometry) = try frozenFixture()
        h.capture.displayList = [display]
        let read = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = read
        h.coordinator.start(.region)
        h.coordinator.toggleRegionFreeze(on: display)
        await waitFor("display read") { read.waiterCount == 1 }
        #expect(read.resolve(.success((frame, geometry))))
        await waitFor("frozen preview") {
            if case .frozen = h.coordinator.regionFreeze { return true }
            return false
        }

        h.clock.jumpWallClock(bySeconds: 3600)
        h.clock.advance(bySeconds: 59)
        await drain()
        #expect(h.coordinator.regionFreeze != nil)
        // A timer that returns before the deadline sleeps again instead of ending the expiry.
        h.clock.wakeEarly()
        await drain()
        #expect(h.coordinator.regionFreeze != nil)
        if timerResumes {
            h.clock.advance(bySeconds: 1)
            await waitFor("preview expired") { h.coordinator.regionFreeze == nil }
        } else {
            h.clock.stall(bySeconds: 1)
            let region = Rect<DesktopSpace>(x: -29, y: -15, width: 2, height: 2)
            #expect(!h.coordinator.commitRegion(region, on: display))
        }
        #expect(h.coordinator.regionFreeze == nil)
        #expect(h.coordinator.state == .selecting)
        #expect(h.capture.captureCalls == [.display(display)])
        #expect(h.completions.isEmpty)
    }

    @Test("Permission loss ends selection even when the frozen frame expires", arguments: [true, false])
    func permissionLossOverridesFrozenDeadline(reportedByCapture: Bool) async throws {
        let h = CaptureHarness()
        let (display, _, _) = try frozenFixture()
        h.capture.displayList = [display]
        let read = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = read
        h.coordinator.start(.region)
        h.coordinator.toggleRegionFreeze(on: display)
        await waitFor("display read") { read.waiterCount == 1 && h.clock.pendingSleepCount == 2 }

        if reportedByCapture {
            h.clock.stall(bySeconds: 60)
            #expect(read.resolve(.failure(.permissionDenied)))
        } else {
            h.permission.isGranted = false
            h.clock.advance(bySeconds: 60)
            await waitFor("the expired preview leaves selection") { h.coordinator.regionFreeze == nil }
            #expect(read.resolve(.failure(.canceled)))
        }
        await waitFor("freeze was removed") { h.coordinator.regionFreeze == nil }
        #expect(h.coordinator.state == .failed(.permissionDenied))
        #expect(h.coordinator.selectionContext == nil)
        #expect(h.completions.isEmpty)
    }

    @Test(
        "Canceling or unfreezing during the display read suppresses its late pixels without blocking the next live capture",
        arguments: [true, false])
    func staleFrozenReadNeverPublishes(cancel: Bool) async throws {
        let h = CaptureHarness()
        let store = ImageStore()
        h.assets.store = store
        let (display, frame, geometry) = try frozenFixture()
        h.capture.displayList = [display]
        let read = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = read
        h.coordinator.start(.region)
        h.coordinator.toggleRegionFreeze(on: display)
        await waitFor("display read is suspended") { read.waiterCount == 1 }

        if cancel {
            h.coordinator.cancel()
            #expect(h.coordinator.state == .canceled)
            #expect(h.coordinator.start(.region) == .started)
        } else {
            h.coordinator.toggleRegionFreeze(on: display)
            #expect(h.coordinator.state == .selecting)
        }
        h.capture.pendingCapture = nil
        let region = Rect<DesktopSpace>(x: -29, y: -15, width: 2, height: 2)
        #expect(h.coordinator.commitRegion(region, on: display))
        await drain()
        #expect(h.capture.captureCalls == [.display(display)])
        #expect(h.coordinator.regionFreeze == nil)
        #expect(h.completions.isEmpty && h.assets.registeredCaptures.isEmpty)
        #expect(await store.count == 0)

        #expect(read.resolve(.success((frame, geometry))))
        await waitFor("next live capture completes") { h.completions.count == 1 }
        #expect(h.capture.captureCalls == [.display(display), .region(region, display: display)])
        #expect(h.capture.maxConcurrentCaptures == 1)
        #expect(h.coordinator.regionFreeze == nil)
        #expect(h.assets.registeredCaptures.count == 1)
        #expect(await store.count == 1)
    }

    @Test("A canceled display read that never returns holds the next capture only until the drain limit, then fails it")
    func stuckFrozenReadFailsTheNextCaptureClosed() async throws {
        let h = CaptureHarness()
        let (display, frame, geometry) = try frozenFixture()
        h.capture.displayList = [display]
        let read = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = read
        h.coordinator.start(.region)
        h.coordinator.toggleRegionFreeze(on: display)
        await waitFor("display read is suspended") { read.waiterCount == 1 }
        h.coordinator.toggleRegionFreeze(on: display)
        h.capture.pendingCapture = nil
        let region = Rect<DesktopSpace>(x: -29, y: -15, width: 2, height: 2)
        #expect(h.coordinator.commitRegion(region, on: display))
        await waitFor("drain timer") { h.clock.pendingSleepCount == 1 }

        let limit = Double(CaptureCoordinator.freezeReadDrainLimit.components.seconds)
        h.clock.advance(bySeconds: limit - 0.001)
        await drain()
        #expect(h.coordinator.state == .capturing)
        h.clock.advance(bySeconds: 0.001)
        await waitFor("the waiting capture fails") { h.coordinator.state == .failed(.targetUnavailable) }
        #expect(h.capture.captureCalls == [.display(display)])
        #expect(h.capture.maxConcurrentCaptures == 1)

        // The late read still publishes nothing.
        #expect(read.resolve(.success((frame, geometry))))
        await drain()
        #expect(h.completions.isEmpty && h.assets.registeredCaptures.isEmpty)
        #expect(h.coordinator.regionFreeze == nil)
    }

    @Test("Permission revocation during a frozen region interrupts selection on the injected clock")
    func frozenPermissionRevocationUsesInjectedClock() async throws {
        let h = CaptureHarness()
        let (display, frame, geometry) = try frozenFixture()
        h.capture.displayList = [display]
        let read = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = read
        h.coordinator.start(.region)
        h.coordinator.toggleRegionFreeze(on: display)
        await waitFor("display read and timers") { read.waiterCount == 1 && h.clock.pendingSleepCount == 2 }
        #expect(read.resolve(.success((frame, geometry))))
        await waitFor("frozen preview") {
            if case .frozen = h.coordinator.regionFreeze { return true }
            return false
        }

        h.permission.isGranted = false
        h.clock.advance(bySeconds: 0.5)
        await waitFor("permission loss interrupted freeze") { h.coordinator.state == .failed(.permissionDenied) }
        #expect(h.coordinator.regionFreeze == nil)
        await waitFor("freeze timers released") { h.clock.pendingSleepCount == 0 }
    }

    private func frozenFixture() throws -> (DisplayInfo, CGImage, CaptureGeometry) {
        let display = DisplayInfo(
            id: 9, frame: Rect(x: -30, y: -16, width: 8, height: 6), pointPixelScale: 2, fingerprint: "negative")
        var rgba: [UInt8] = []
        for y in 0..<12 {
            for x in 0..<16 {
                rgba.append(contentsOf: [UInt8(x * 8), UInt8(y * 8), 0, 255])
            }
        }
        let image = try ChartFixture.image(width: 16, height: 12, straightRGBA: rgba)
        let geometry = CaptureGeometry(
            source: .display(id: display.id), desktopBounds: display.frame, pointPixelScale: 2,
            pixelSize: PixelSize(width: 16, height: 12), capturedAt: Date(timeIntervalSince1970: 123))
        return (display, image, geometry)
    }
}
