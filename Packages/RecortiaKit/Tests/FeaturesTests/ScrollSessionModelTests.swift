import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform
import Testing

@testable import Features

// Failure modes (FR-10, SCR-02/04, PERM-02): screen permission missing; automatic mode requested
// without Accessibility (must stay manual and explain); ambiguous match (pause, never fabricate);
// a limit reached (review with a partial reason); target loss, display change, or permission
// revocation mid-stream (stop immediately); a late frame after Stop/Cancel (dropped); Stop with
// zero frames; assembly over budget; Accessibility revoked while scrolling automatically.
@MainActor
final class ScrollHarness {
    let frames = FakeFrameSource()
    let stitcher = FakeStitcher()
    let scroller = FakeAutoScroller()
    let accessibility: FakeAccessibilityPermission
    let permission: FakeScreenPermission
    let assets = FakeAssetService()
    let clock = ManualClock()
    let settings = SettingsStore(storage: MemoryPreferenceStorage())
    let model: ScrollSessionModel
    var accepted: [DocumentSession] = []
    let target = CaptureTarget.region(Rect(x: 0, y: 0, width: 400, height: 300), display: TestFixtures.primaryDisplay)

    init(trusted: Bool = false, automaticPreference: Bool = false, screenGranted: Bool = true) {
        accessibility = FakeAccessibilityPermission(isTrusted: trusted)
        permission = FakeScreenPermission(isGranted: screenGranted)
        settings.update { $0.automaticScrollingEnabled = automaticPreference }
        model = ScrollSessionModel(
            frames: frames, stitcher: stitcher, autoScroller: scroller, accessibility: accessibility,
            screenPermission: permission, assets: assets, clock: clock, settings: settings)
        model.onAccepted = { [unowned self] in self.accepted.append($0) }
    }

    /// Begins, chooses the target, and starts collecting.
    func startCollecting() async {
        _ = await model.begin()
        model.chooseTarget(target)
        model.start()
        await waitFor("collecting and waiting for a frame") {
            self.model.state == .collecting && self.frames.frames.waiterCount == 1
        }
    }
}

@Suite("ScrollSessionModel (FR-10, SCR-02/04)")
@MainActor
struct ScrollSessionModelTests {
    @Test("Manual collection accepts frames and records seams, then reviews and accepts")
    func manualHappyPath() async {
        let h = ScrollHarness()
        await h.startCollecting()
        #expect(h.model.mode == .manual)

        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 && h.frames.frames.waiterCount == 1 }
        h.frames.deliver()
        await waitFor("frame 2") { h.model.acceptedFrames == 2 && h.frames.frames.waiterCount == 1 }
        #expect(h.model.seams == [100])
        #expect(h.model.outputSize.height == 140)

        h.model.stop()
        #expect(h.model.state == .reviewing)
        #expect(h.frames.stopCount >= 1)
        #expect(h.model.partialReason == nil)
        await waitFor("preview") { h.model.preview != nil }

        await h.model.accept()
        #expect(h.model.state == .accepted)
        #expect(h.accepted.count == 1)
        #expect(h.assets.registeredStitched.first?.origin == .scrollCapture(partialReason: nil))
        #expect(h.accessibility.promptCount == 0)
        #expect(h.scroller.stepCount == 0)
    }

    @Test("Automatic mode requires both the preference and Accessibility trust")
    func automaticModeGate() async {
        let off = ScrollHarness(trusted: true, automaticPreference: false)
        _ = await off.model.begin()
        off.model.chooseTarget(off.target)
        #expect(off.model.mode == .manual)
        #expect(off.model.notice == nil)

        let untrusted = ScrollHarness(trusted: false, automaticPreference: true)
        _ = await untrusted.model.begin()
        untrusted.model.chooseTarget(untrusted.target)
        #expect(untrusted.model.mode == .manual)
        #expect(untrusted.model.notice == .automaticNeedsAccessibility)
        #expect(untrusted.accessibility.promptCount == 0)

        let on = ScrollHarness(trusted: true, automaticPreference: true)
        _ = await on.model.begin()
        on.model.chooseTarget(on.target)
        #expect(on.model.mode == .automatic)
    }

    @Test("Automatic mode scrolls after each frame and ends at the page end")
    func automaticScrolling() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        h.scroller.steps = [.scrolled, .reachedEnd]
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 && h.frames.frames.waiterCount == 1 }
        h.frames.deliver()
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(h.scroller.stepCount == 2)
        #expect(h.scroller.stopCount >= 1)
        #expect(h.model.partialReason == nil)
    }

    @Test("Target loss during automatic scrolling stops everything immediately")
    func automaticTargetLoss() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        h.scroller.steps = [.targetLost]
        await h.startCollecting()
        let resetsBefore = h.stitcher.resetCount
        h.frames.deliver()
        await waitFor("failed") { h.model.state == .failed(.targetLost) }
        #expect(h.frames.stopCount >= 1)
        #expect(h.scroller.stopCount >= 1)
        #expect(h.stitcher.resetCount > resetsBefore)
        #expect(h.model.acceptedFrames == 0)
    }

    @Test("A new session stops any auto scroller left over from the previous one before scrolling")
    func newSessionStopsPreviousScroller() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        h.model.cancel()
        // A step still in flight at cancel time may leave a scroller behind for the old target.
        let afterCancel = h.scroller.stopCount
        #expect(await h.model.begin())
        #expect(h.scroller.stopCount > afterCancel)
        h.model.chooseTarget(h.target)
        let beforeStart = h.scroller.stopCount
        let stepsBefore = h.scroller.stepCount
        h.model.start()
        #expect(h.scroller.stopCount > beforeStart)
        #expect(h.scroller.stepCount == stepsBefore)
        h.model.cancel()
    }

    @Test("Canceling before collection begins never starts a capture stream (security audit)")
    func cancelBeforeCollectStartsNoStream() async {
        let h = ScrollHarness(trusted: false, automaticPreference: false)
        #expect(await h.model.begin())
        h.model.chooseTarget(h.target)
        h.model.start()
        h.model.cancel()  // before the collect task first runs
        for _ in 0..<50 { await Task.yield() }
        #expect(h.frames.startCount == 0, "an orphaned stream would keep capturing with nothing consuming it")
    }

    @Test("Revoked Accessibility falls back to manual mode instead of scrolling")
    func accessibilityRevokedFallsBackToManual() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        h.accessibility.isTrusted = false
        h.frames.deliver()
        await waitFor("manual") { h.model.mode == .manual }
        #expect(h.scroller.stepCount == 0)
        #expect(h.model.notice == .accessibilityRevoked)
        #expect(h.model.state == .collecting)
    }

    @Test("An ambiguous match pauses and never appends; Stop then labels the result partial")
    func ambiguousPauses() async {
        let h = ScrollHarness()
        h.stitcher.script = [.accepted(offset: 0), .ambiguous(.ambiguousMatch)]
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 && h.frames.frames.waiterCount == 1 }
        h.frames.deliver()
        await waitFor("paused") { h.model.state == .paused(.ambiguousMatch) }
        #expect(h.model.acceptedFrames == 1)

        h.model.stop()
        #expect(h.model.state == .reviewing)
        #expect(h.model.partialReason == .ambiguous(.ambiguousMatch))
        await h.model.accept()
        #expect(h.assets.registeredStitched.first?.isPartialScrollCapture == true)
        #expect(h.assets.registeredStitched.first?.origin == .scrollCapture(partialReason: .ambiguous(.ambiguousMatch)))
    }

    @Test("Resume after a pause continues collecting")
    func resumeAfterPause() async {
        let h = ScrollHarness()
        await h.startCollecting()
        h.model.pause()
        #expect(h.model.state == .paused(.userPaused))
        h.model.resume()
        await waitFor("collecting") { h.model.state == .collecting && h.frames.frames.waiterCount >= 1 }
        h.frames.deliver()
        await waitFor("frame") { h.model.acceptedFrames == 1 }
    }

    @Test("A reached limit ends collection into review with a partial reason (SCR-04)")
    func limitReached() async {
        let h = ScrollHarness()
        h.stitcher.script = [.accepted(offset: 0), .limitReached(.height)]
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 && h.frames.frames.waiterCount == 1 }
        h.frames.deliver()
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(h.model.partialReason == .limit(.height))
        #expect(h.frames.stopCount >= 1)
    }

    @Test("Stop is immediate and drops a frame that arrives afterwards")
    func stopDropsLateFrames() async {
        let h = ScrollHarness()
        await h.startCollecting()
        h.model.stop()
        #expect(h.model.state == .failed(.noFrames))
        #expect(h.frames.deliver() == false)  // the stream was stopped; nobody waits any more
        await drain()
        #expect(h.stitcher.appendCount == 0)
    }

    @Test("Cancel discards the stitch and stops the stream")
    func cancelDiscards() async {
        let h = ScrollHarness()
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 }
        let resetsBefore = h.stitcher.resetCount
        h.model.cancel()
        #expect(h.model.state == .canceled)
        #expect(h.frames.stopCount >= 1)
        #expect(h.stitcher.resetCount > resetsBefore)
        await drain()
        #expect(h.accepted.isEmpty)
    }

    @Test(
        "Stream errors stop the session with a typed failure",
        arguments: [
            (CaptureError.targetUnavailable, ScrollFailure.targetLost),
            (.permissionDenied, .permissionRevoked),
            (.displayChanged, .displayChanged),
        ])
    func streamErrors(error: CaptureError, expected: ScrollFailure) async {
        let h = ScrollHarness()
        await h.startCollecting()
        h.frames.frames.resolve(.failure(error))
        await waitFor("failed") { h.model.state == .failed(expected) }
        #expect(h.frames.stopCount >= 1)
    }

    @Test("An externally reported target loss stops immediately")
    func externalTargetLoss() async {
        let h = ScrollHarness()
        await h.startCollecting()
        h.model.targetLost()
        #expect(h.model.state == .failed(.targetLost))
        #expect(h.frames.stopCount >= 1)
    }

    @Test("Denied screen permission keeps the session idle and explains")
    func screenPermissionDenied() async {
        let h = ScrollHarness(screenGranted: false)
        #expect(await h.model.begin() == false)
        #expect(h.model.state == .idle)
        #expect(h.model.notice == .screenPermissionDenied)
        #expect(h.frames.startCount == 0)
    }

    @Test("An assembly failure keeps the review open so the user can discard")
    func assemblyFailure() async {
        let h = ScrollHarness()
        h.stitcher.assembleFails = true
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 }
        h.model.stop()
        await h.model.accept()
        #expect(h.model.state == .reviewing)
        #expect(h.model.notice == .assemblyFailed)
        #expect(h.accepted.isEmpty)
        h.model.discard()
        #expect(h.model.state == .canceled)
    }

    @Test("Elapsed time from the injected clock reaches the stitcher")
    func elapsedFromClock() async {
        let h = ScrollHarness()
        await h.startCollecting()
        h.clock.advance(bySeconds: 5)
        h.frames.deliver()
        await waitFor("frame 1") { h.model.acceptedFrames == 1 }
        #expect(h.stitcher.lastElapsed == .seconds(5))
    }
}
