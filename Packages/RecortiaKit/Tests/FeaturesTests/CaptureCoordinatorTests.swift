import CoreGraphics
import Domain
import Foundation
import MacPlatform
import Testing

@testable import Features

// Failure modes the capture coordinator must handle (written before the implementation):
//  1. Screen permission missing: request just in time; denial ends in failed(.permissionDenied)
//     without touching capture. No request at init (PERM-01).
//  2. A permission answer that arrives after the request was replaced or canceled.
//  3. A second invocation while selecting/countdown (replace) or capturing (ignore + report) (CAP-02).
//  4. A canceled capture whose completion arrives before or after a replacement request (PERM-02):
//     never produces an editor document, never registers a lasting asset.
//  5. Countdown canceled mid-way: its pending clock sleep must not fire a capture later.
//  6. Capture errors: target gone, display changed, permission revoked, system error.
//  7. Repeat-last-region against a display whose configuration changed or disappeared.
//  8. Region selections that cross displays or sit at negative desktop origins.
//  9. Window list unavailable (permission lost between check and listing).
@MainActor
final class CaptureHarness {
    let capture = FakeCaptureService()
    let permission: FakeScreenPermission
    let assets = FakeAssetService()
    let clock = ManualClock()
    let storage = MemoryPreferenceStorage()
    let settings: SettingsStore
    let coordinator: CaptureCoordinator
    var completions: [CaptureCompletion] = []

    init(permissionGranted: Bool = true) {
        permission = FakeScreenPermission(isGranted: permissionGranted)
        settings = SettingsStore(storage: storage)
        coordinator = CaptureCoordinator(
            capture: capture, permission: permission, assets: assets, clock: clock, settings: settings)
        coordinator.onCaptured = { [unowned self] in self.completions.append($0) }
    }

    var regionRect: Rect<DesktopSpace> { Rect(x: 100, y: 120, width: 200, height: 80) }
}

@Suite("CaptureCoordinator (FR-02, CAP-01/02, PERM-01/02)")
@MainActor
struct CaptureCoordinatorTests {
    @Test("Region capture with permission goes selecting → capturing → editing")
    func regionHappyPath() async {
        let h = CaptureHarness()
        #expect(h.coordinator.start(.region) == .started)
        #expect(h.coordinator.state == .selecting)
        #expect(h.coordinator.selectionContext == .region([TestFixtures.primaryDisplay]))

        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }

        #expect(h.capture.captureCalls == [.region(h.regionRect, display: TestFixtures.primaryDisplay)])
        #expect(h.completions.count == 1)
        #expect(h.completions.first?.purpose == .edit)
        #expect(h.assets.registeredCaptures.count == 1)
        #expect(h.permission.requestCount == 0)
        #expect(h.coordinator.selectionContext == nil)
    }

    @Test("Creating the coordinator never asks for Screen Recording (PERM-01)")
    func noPermissionRequestAtLaunch() async {
        let h = CaptureHarness(permissionGranted: false)
        await drain()
        #expect(h.permission.requestCount == 0)
        #expect(h.coordinator.state == .idle)
    }

    @Test("Missing permission is requested just in time; denial is a typed failure")
    func permissionDenied() async {
        let h = CaptureHarness(permissionGranted: false)
        h.permission.grantOnRequest = false
        h.coordinator.start(.region)
        await waitFor("failed") { h.coordinator.state == .failed(.permissionDenied) }
        #expect(h.permission.requestCount == 1)
        #expect(h.capture.captureCalls.isEmpty)
        #expect(h.completions.isEmpty)
    }

    @Test("Granting permission on request continues to selection")
    func permissionGrantedOnRequest() async {
        let h = CaptureHarness(permissionGranted: false)
        h.permission.grantOnRequest = true
        h.coordinator.start(.region)
        #expect(h.coordinator.state == .permissionCheck)
        await waitFor("selecting") { h.coordinator.state == .selecting }
    }

    @Test("A permission answer for a replaced request is ignored")
    func stalePermissionAnswerIgnored() async {
        let h = CaptureHarness(permissionGranted: false)
        let pending = Pending<Bool>()
        h.permission.pendingRequest = pending
        h.coordinator.start(.region)
        await waitFor("first request") { pending.waiterCount == 1 }
        #expect(h.coordinator.start(.window) == .replacedPrevious)
        await waitFor("second request") { pending.waiterCount == 2 }

        pending.resolve(false)  // answer to the replaced request
        await drain()
        #expect(h.coordinator.state == .permissionCheck)

        pending.resolve(true)
        await waitFor("window selection") { h.coordinator.selectionContext == .window([TestFixtures.window]) }
        #expect(h.coordinator.mode == .window)
    }

    @Test("20 rapid invocations keep one active session and queue nothing (CAP-02)")
    func rapidInvocations() async {
        let h = CaptureHarness()
        var results: [CaptureCoordinator.StartResult] = []
        for _ in 0..<20 { results.append(h.coordinator.start(.region)) }
        #expect(results.first == .started)
        #expect(results.dropFirst().allSatisfy { $0 == .replacedPrevious })
        #expect(h.coordinator.state == .selecting)
        #expect(h.capture.captureCalls.isEmpty)

        let pending = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = pending
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("capture started") { pending.waiterCount == 1 }

        var ignored: [CaptureCoordinator.StartResult] = []
        for _ in 0..<20 { ignored.append(h.coordinator.start(.region)) }
        #expect(ignored.allSatisfy { $0 == .ignoredCaptureInProgress })
        #expect(h.coordinator.notice == .captureInProgress)
        #expect(h.coordinator.state == .capturing)

        guard let image = makeImage() else { return }
        let target = CaptureTarget.region(h.regionRect, display: TestFixtures.primaryDisplay)
        pending.resolve(.success((image, TestFixtures.geometry(for: target))))
        await waitFor("editing") { h.coordinator.state == .editing }
        await drain()

        #expect(h.capture.captureCalls.count == 1)
        #expect(h.capture.maxConcurrentCaptures == 1)
        #expect(h.completions.count == 1)
        #expect(h.coordinator.state.isActive == false)
    }

    @Test("Canceled capture completing before a replacement produces nothing (PERM-02)")
    func lateCompletionBeforeReplacement() async {
        let h = CaptureHarness()
        let pending = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = pending
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("capturing") { pending.waiterCount == 1 }

        h.coordinator.cancel()
        #expect(h.coordinator.state == .canceled)

        guard let image = makeImage() else { return }
        let target = CaptureTarget.region(h.regionRect, display: TestFixtures.primaryDisplay)
        pending.resolve(.success((image, TestFixtures.geometry(for: target))))
        await drain()

        #expect(h.coordinator.state == .canceled)
        #expect(h.completions.isEmpty)
        #expect(h.assets.registeredCaptures.isEmpty)
        #expect(h.coordinator.hasRepeatRegion == false)
    }

    @Test("Canceled capture completing after a replacement request produces nothing (PERM-02)")
    func lateCompletionAfterReplacement() async {
        let h = CaptureHarness()
        let pending = Pending<Result<(CGImage, CaptureGeometry), CaptureError>>()
        h.capture.pendingCapture = pending
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("capturing") { pending.waiterCount == 1 }

        h.coordinator.cancel()
        #expect(h.coordinator.start(.region) == .started)
        #expect(h.coordinator.state == .selecting)

        guard let image = makeImage() else { return }
        let stale = CaptureTarget.region(h.regionRect, display: TestFixtures.primaryDisplay)
        pending.resolve(.success((image, TestFixtures.geometry(for: stale))))
        await drain()
        #expect(h.coordinator.state == .selecting)
        #expect(h.completions.isEmpty)

        let newRect = Rect<DesktopSpace>(x: 5, y: 5, width: 50, height: 50)
        h.coordinator.commitRegion(newRect, on: TestFixtures.primaryDisplay)
        await waitFor("second capture") { pending.waiterCount == 1 }
        let fresh = CaptureTarget.region(newRect, display: TestFixtures.primaryDisplay)
        pending.resolve(.success((image, TestFixtures.geometry(for: fresh))))
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.completions.count == 1)
        #expect(h.assets.registeredCaptures.count == 1)
    }

    @Test("Delay counts down one second at a time through the injected clock")
    func countdown() async {
        let h = CaptureHarness()
        h.coordinator.start(.region, delaySeconds: 3)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        #expect(h.coordinator.state == .countdown(remaining: 3))

        await waitFor("sleep 1") { h.clock.pendingSleepCount == 1 }
        h.clock.advance(bySeconds: 1)
        await waitFor("2 left") { h.coordinator.state == .countdown(remaining: 2) }
        await waitFor("sleep 2") { h.clock.pendingSleepCount == 1 }
        h.clock.advance(bySeconds: 1)
        await waitFor("1 left") { h.coordinator.state == .countdown(remaining: 1) }
        #expect(h.capture.captureCalls.isEmpty)
        await waitFor("sleep 3") { h.clock.pendingSleepCount == 1 }
        h.clock.advance(bySeconds: 1)
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.capture.captureCalls.count == 1)
        #expect(h.clock.sleepRequests == [.seconds(1), .seconds(1), .seconds(1)])
    }

    @Test("A replaced countdown never fires its capture later")
    func replacedCountdownDoesNotCapture() async {
        let h = CaptureHarness()
        h.coordinator.start(.region, delaySeconds: 5)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("sleeping") { h.clock.pendingSleepCount == 1 }

        #expect(h.coordinator.start(.region) == .replacedPrevious)
        await waitFor("old sleep canceled") { h.clock.pendingSleepCount == 0 }
        h.clock.advance(bySeconds: 30)
        await drain()
        #expect(h.capture.captureCalls.isEmpty)
        #expect(h.coordinator.state == .selecting)
    }

    @Test("Escape during selection cancels without side effects")
    func cancelDuringSelection() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        h.coordinator.cancel()
        #expect(h.coordinator.state == .canceled)
        #expect(h.coordinator.selectionContext == nil)
        await drain()
        #expect(h.capture.captureCalls.isEmpty)
        #expect(h.completions.isEmpty)

        let idle = CaptureHarness()
        idle.coordinator.cancel()
        #expect(idle.coordinator.state == .idle)
    }

    @Test("Capture options come from preferences; the cursor is hidden by default")
    func captureOptionsFromPreferences() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.capture.lastOptions?.showsCursor == false)
        #expect(h.capture.lastOptions?.includesShadow == true)

        h.settings.update {
            $0.captureShowsCursor = true
            $0.captureIncludesWindowShadow = false
        }
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing again") { h.completions.count == 2 }
        #expect(h.capture.lastOptions?.showsCursor == true)
        #expect(h.capture.lastOptions?.includesShadow == false)
    }

    @Test("Repeat last region captures the remembered rectangle without selection")
    func repeatLastRegion() async {
        let h = CaptureHarness()
        #expect(h.coordinator.hasRepeatRegion == false)
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.coordinator.hasRepeatRegion)

        h.coordinator.start(.repeatRegion)
        await waitFor("second capture") { h.completions.count == 2 }
        #expect(h.capture.captureCalls.last == .region(h.regionRect, display: TestFixtures.primaryDisplay))
    }

    @Test("Repeat region is invalidated when the display fingerprint changes")
    func repeatInvalidatedByFingerprint() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }

        let rescaled = DisplayInfo(
            id: 1, frame: Rect(x: 0, y: 0, width: 1800, height: 1169), pointPixelScale: 2, fingerprint: "1-1800x1169@2")
        h.capture.displayList = [rescaled]
        h.coordinator.start(.repeatRegion)
        #expect(h.coordinator.notice == .repeatRegionUnavailable)
        #expect(h.coordinator.hasRepeatRegion == false)
        #expect(h.coordinator.state == .selecting)
        #expect(h.coordinator.selectionContext == .region([rescaled]))
        #expect(h.capture.captureCalls.count == 1)
    }

    @Test("Repeat region is session-only and never persisted")
    func repeatRegionIsSessionOnly() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }

        let fresh = CaptureCoordinator(
            capture: h.capture, permission: h.permission, assets: h.assets, clock: h.clock,
            settings: SettingsStore(storage: h.storage))
        #expect(fresh.hasRepeatRegion == false)
        let blob = h.storage.values.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!blob.contains("120"))  // the region's y coordinate never reaches storage
    }

    @Test("A display reconfiguration cancels selection and forgets the repeat region")
    func displayReconfiguration() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }

        h.coordinator.start(.region)
        h.coordinator.displayConfigurationChanged()
        #expect(h.coordinator.state == .failed(.displayChanged))
        #expect(h.coordinator.hasRepeatRegion == false)
        #expect(h.coordinator.selectionContext == nil)
    }

    @Test("Region selection is clamped to its starting display, including negative origins")
    func regionClampedToStartingDisplay() async {
        let h = CaptureHarness()
        h.capture.displayList = [TestFixtures.leftDisplay, TestFixtures.primaryDisplay]
        h.coordinator.start(.region)
        // Starts on the left display (negative origin) and is dragged onto the primary display.
        let crossing = Rect<DesktopSpace>(x: -300, y: -150, width: 600, height: 400)
        h.coordinator.commitRegion(crossing, on: TestFixtures.leftDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }

        let expected = Rect<DesktopSpace>(x: -300, y: -150, width: 300, height: 400)
        #expect(h.capture.captureCalls == [.region(expected, display: TestFixtures.leftDisplay)])
        #expect(h.coordinator.lastSelectionWasClamped)
    }

    @Test("An empty selection keeps selecting instead of capturing")
    func emptySelectionIgnored() async {
        let h = CaptureHarness()
        h.coordinator.start(.region)
        let offDisplay = Rect<DesktopSpace>(x: 5000, y: 5000, width: 10, height: 10)
        #expect(h.coordinator.commitRegion(offDisplay, on: TestFixtures.primaryDisplay) == false)
        #expect(
            h.coordinator.commitRegion(Rect(x: 10, y: 10, width: 0, height: 20), on: TestFixtures.primaryDisplay)
                == false)
        #expect(h.coordinator.state == .selecting)
        #expect(h.capture.captureCalls.isEmpty)
    }

    @Test("Window mode lists windows for the chooser, then captures the chosen one")
    func windowMode() async {
        let h = CaptureHarness()
        h.coordinator.start(.window)
        await waitFor("windows listed") { h.coordinator.selectionContext == .window([TestFixtures.window]) }
        h.coordinator.commitSelection(.window(TestFixtures.window))
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.capture.captureCalls == [.window(TestFixtures.window)])
    }

    @Test("Space during a region selection switches the same request to a window, keeping its delay")
    func switchRegionToWindow() async {
        let h = CaptureHarness()
        h.coordinator.start(.region, delaySeconds: 2)
        #expect(h.coordinator.switchToWindowSelection())
        #expect(h.coordinator.mode == .window)
        #expect(h.coordinator.state == .selecting)
        await waitFor("windows listed") { h.coordinator.selectionContext == .window([TestFixtures.window]) }
        #expect(h.completions.isEmpty)

        h.coordinator.commitSelection(.window(TestFixtures.window))
        #expect(h.coordinator.state == .countdown(remaining: 2))
        for second in 1...2 {
            await waitFor("sleep \(second)") { h.clock.pendingSleepCount == 1 }
            h.clock.advance(bySeconds: 1)
        }
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.capture.captureCalls == [.window(TestFixtures.window)])
        #expect(h.completions.count == 1)
    }

    @Test("Only a plain region selection switches to a window")
    func switchToWindowOnlyFromRegion() async {
        let idle = CaptureHarness()
        #expect(!idle.coordinator.switchToWindowSelection())
        #expect(idle.coordinator.state == .idle)

        let text = CaptureHarness()
        text.coordinator.start(.region, purpose: .recognizeText)
        #expect(!text.coordinator.switchToWindowSelection())
        #expect(text.coordinator.mode == .region)

        let display = CaptureHarness()
        display.capture.displayList = [TestFixtures.primaryDisplay, TestFixtures.leftDisplay]
        display.coordinator.start(.display)
        #expect(!display.coordinator.switchToWindowSelection())
        #expect(display.coordinator.mode == .display)

        let window = CaptureHarness()
        window.coordinator.start(.window)
        #expect(!window.coordinator.switchToWindowSelection())
    }

    @Test("A window list failure is reported as a typed capture failure")
    func windowListFailure() async {
        let h = CaptureHarness()
        h.capture.windowResult = .failure(.permissionDenied)
        h.coordinator.start(.window)
        await waitFor("failed") { h.coordinator.state == .failed(.permissionDenied) }
        #expect(h.capture.captureCalls.isEmpty)
    }

    @Test("Display mode captures a single display directly and offers a chooser for several")
    func displayMode() async {
        let single = CaptureHarness()
        single.coordinator.start(.display)
        await waitFor("editing") { single.coordinator.state == .editing }
        #expect(single.capture.captureCalls == [.display(TestFixtures.primaryDisplay)])

        let multi = CaptureHarness()
        multi.capture.displayList = [TestFixtures.primaryDisplay, TestFixtures.leftDisplay]
        multi.coordinator.start(.display)
        #expect(
            multi.coordinator.selectionContext == .display([TestFixtures.primaryDisplay, TestFixtures.leftDisplay]))
        multi.coordinator.commitSelection(.display(TestFixtures.leftDisplay))
        await waitFor("editing") { multi.coordinator.state == .editing }
        #expect(multi.capture.captureCalls == [.display(TestFixtures.leftDisplay)])
    }

    @Test(
        "Capture errors become typed failures",
        arguments: [
            (CaptureError.targetUnavailable, CaptureState.failed(.targetUnavailable)),
            (.displayChanged, .failed(.displayChanged)),
            (.permissionDenied, .failed(.permissionDenied)),
            (.system(code: 7), .failed(.system(code: 7))),
            (.canceled, .canceled),
        ])
    func captureErrors(error: CaptureError, expected: CaptureState) async {
        let h = CaptureHarness()
        h.capture.immediateCaptureError = error
        h.coordinator.start(.region)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("terminal \(expected)") { h.coordinator.state == expected }
        #expect(h.completions.isEmpty)
        #expect(h.assets.registeredCaptures.isEmpty)
    }

    @Test("Text capture carries its purpose to the completion")
    func textPurpose() async {
        let h = CaptureHarness()
        h.coordinator.start(.region, purpose: .recognizeText)
        h.coordinator.commitRegion(h.regionRect, on: TestFixtures.primaryDisplay)
        await waitFor("editing") { h.coordinator.state == .editing }
        #expect(h.completions.first?.purpose == .recognizeText)
    }

    @Test("The configured delay is used by delayed capture, with a fallback when it is zero")
    func delayedCaptureDelay() {
        let h = CaptureHarness()
        #expect(h.coordinator.delayForDelayedCapture == CaptureCoordinator.fallbackDelaySeconds)
        h.settings.update { $0.captureDelaySeconds = 7 }
        #expect(h.coordinator.delayForDelayedCapture == 7)
    }
}
