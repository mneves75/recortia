import CoreGraphics
import Domain
import Foundation
import Imaging
import MacPlatform
import Testing

@testable import Features

// Failure modes (FR-10, SCR-01/04, PERM-02): the page ends but the session keeps waiting (static
// pages deliver no new frames, so a frame-driven check never fires); a manual reader pauses
// mid-page and must not be stopped for it; the 2-minute limit is only checked when a frame
// arrives, so a static page or a paused session outlives it; Stop/Cancel while `nextFrame()` is
// blocked leaves a timer running that later rewrites the result; an external interrupt (lock,
// display change, permission loss) leaves the stream, the scroller, or the stitch alive, or lets
// a late frame through.
@Suite("ScrollSessionModel endings and interrupts (FR-10, SCR-01/04, PERM-02)")
@MainActor
struct ScrollSessionModelEndingTests {
    static let maxSeconds = seconds(ScrollLimits.default.maxDuration)
    static let settleSeconds = seconds(ScrollSessionModel.automaticSettleInterval)
    static let endThreshold = ScrollStitcher.endOfPageStationaryFrames

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Delivers `count` frames, waiting after each until the model asks for the next one.
    static func deliverFrames(_ h: ScrollHarness, _ count: Int, sourceLocation: SourceLocation = #_sourceLocation)
        async
    {
        for _ in 0..<count {
            let before = h.stitcher.appendCount
            h.frames.deliver()
            await waitFor("frame \(before + 1) processed", sourceLocation: sourceLocation) {
                h.stitcher.appendCount == before + 1 && h.frames.frames.waiterCount == 1
            }
        }
    }

    /// Each scroll step has registered its own settle sleep (after the deadline's), and only the
    /// deadline and the newest settle timer are still pending.
    static func settleArmed(_ h: ScrollHarness, steps: Int) -> Bool {
        h.scroller.stepCount == steps && h.clock.sleepRequests.count == 1 + steps && h.clock.pendingSleepCount == 2
    }

    // MARK: End of page

    @Test("Automatic mode ends a page that stops moving as a complete result")
    func automaticEndOfPageFromStationaryFrames() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        h.stitcher.script = [.accepted(offset: 0), .accepted(offset: 40)] + Array(repeating: .stationary, count: 3)
        await h.startCollecting()
        await Self.deliverFrames(h, 4)
        h.frames.deliver()
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(h.model.partialReason == nil)
        #expect(!h.model.isPartial)
        #expect(h.scroller.stepCount == 4)  // no scroll after the end was seen
        #expect(h.scroller.stopCount >= 1)
        #expect(h.frames.stopCount >= 1)

        await h.model.accept()
        #expect(h.model.state == .accepted)
        #expect(h.assets.registeredStitched.first?.origin == .scrollCapture(partialReason: nil))
    }

    @Test("Automatic mode ends the page when scroll steps expose nothing new (no frames arrive)")
    func automaticEndOfPageWithoutFrames() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        h.frames.deliver()
        // The 2-minute deadline plus the settle timer armed after the first scroll step.
        await waitFor("first step, settle timer armed") { Self.settleArmed(h, steps: 1) }
        for retry in 1..<Self.endThreshold {
            h.clock.advance(bySeconds: Self.settleSeconds)
            await waitFor("retry step \(retry)") { Self.settleArmed(h, steps: 1 + retry) }
            #expect(h.model.state == .collecting)
        }
        h.clock.advance(bySeconds: Self.settleSeconds)
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(h.model.partialReason == nil)
        #expect(h.scroller.stepCount == Self.endThreshold)
        #expect(h.scroller.stopCount >= 1)
        #expect(h.frames.frames.waiterCount == 0)
        await waitFor("timers released") { h.clock.pendingSleepCount == 0 }
    }

    @Test("A frame that moves the page restarts the settle count")
    func movementResetsSettleCount() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        h.frames.deliver()
        await waitFor("first step") { Self.settleArmed(h, steps: 1) }
        for retry in 1..<Self.endThreshold {
            h.clock.advance(bySeconds: Self.settleSeconds)
            await waitFor("retry \(retry)") { Self.settleArmed(h, steps: 1 + retry) }
        }
        h.frames.deliver()  // the page moved after all
        let stepsAfterMove = Self.endThreshold + 1
        await waitFor("frame 2") { h.model.acceptedFrames == 2 && Self.settleArmed(h, steps: stepsAfterMove) }
        for retry in 1..<Self.endThreshold {
            h.clock.advance(bySeconds: Self.settleSeconds)
            await waitFor("second run, retry \(retry)") { Self.settleArmed(h, steps: stepsAfterMove + retry) }
            #expect(h.model.state == .collecting)
        }
        h.clock.advance(bySeconds: Self.settleSeconds)
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(h.model.partialReason == nil)
    }

    @Test("Manual mode only hints at the page end and never stops by itself")
    func manualEndOfPageHint() async {
        let h = ScrollHarness()
        h.stitcher.script = [.accepted(offset: 0)] + Array(repeating: .stationary, count: 3) + [.accepted(offset: 40)]
        await h.startCollecting()
        await Self.deliverFrames(h, 3)
        #expect(!h.model.pageEndLikely)
        await Self.deliverFrames(h, 1)
        #expect(h.model.pageEndLikely)
        #expect(h.model.state == .collecting)

        // A reader pausing mid-page: no frames, time passes, nothing stops.
        h.clock.advance(bySeconds: 30)
        await drain()
        #expect(h.model.state == .collecting)
        #expect(h.scroller.stepCount == 0)

        await Self.deliverFrames(h, 1)
        #expect(h.model.acceptedFrames == 2)
        #expect(!h.model.pageEndLikely)

        h.model.stop()
        #expect(h.model.state == .reviewing)
        #expect(h.model.partialReason == nil)
    }

    // MARK: Duration limit

    @Test("The 2-minute limit ends collection even when no frame arrives")
    func durationLimitWithoutFrames() async {
        let h = ScrollHarness()
        await h.startCollecting()
        await Self.deliverFrames(h, 1)
        await waitFor("deadline armed") { h.clock.pendingSleepCount == 1 }
        h.clock.advance(bySeconds: Self.maxSeconds - 1)
        await drain()
        #expect(h.model.state == .collecting)

        h.clock.advance(bySeconds: 1)
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(h.model.partialReason == .limit(.duration))
        #expect(h.frames.stopCount >= 1)
        #expect(h.frames.frames.waiterCount == 0)
        #expect(h.frames.deliver() == false)
        await drain()
        #expect(h.stitcher.appendCount == 1)

        await h.model.accept()
        #expect(h.assets.registeredStitched.first?.origin == .scrollCapture(partialReason: .limit(.duration)))
    }

    @Test("Reaching the 2-minute limit with nothing captured fails clearly")
    func durationLimitWithNothingCaptured() async {
        let h = ScrollHarness()
        await h.startCollecting()
        await waitFor("deadline armed") { h.clock.pendingSleepCount == 1 }
        h.clock.advance(bySeconds: Self.maxSeconds)
        await waitFor("failed") { h.model.state == .failed(.noFrames) }
        #expect(h.frames.stopCount >= 1)
        #expect(h.frames.frames.waiterCount == 0)
    }

    @Test("Paused time counts toward the 2-minute limit")
    func durationLimitWhilePaused() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        await Self.deliverFrames(h, 1)
        h.model.pause()
        #expect(h.model.state == .paused(.userPaused))
        h.clock.advance(bySeconds: Self.maxSeconds)
        await waitFor("reviewing") { h.model.state == .reviewing }
        #expect(h.model.partialReason == .limit(.duration))
        #expect(h.frames.stopCount >= 1)
        #expect(h.scroller.stopCount >= 1)
        #expect(h.frames.deliver() == false)
    }

    // MARK: Responsiveness

    @Test("Stop is immediate while a frame is awaited and releases every timer")
    func stopWhileBlocked() async {
        let h = ScrollHarness()
        await h.startCollecting()
        await Self.deliverFrames(h, 1)
        await waitFor("deadline armed") {
            h.clock.sleepRequests.contains(ScrollLimits.default.maxDuration) && h.clock.pendingSleepCount == 1
        }
        h.model.stop()
        #expect(h.model.state == .reviewing)
        #expect(h.frames.frames.waiterCount == 0)
        await waitFor("timers released") { h.clock.pendingSleepCount == 0 }

        h.clock.advance(bySeconds: Self.maxSeconds * 2)
        await drain()
        #expect(h.model.state == .reviewing)
        #expect(h.model.partialReason == nil)
        #expect(h.frames.deliver() == false)
        #expect(h.stitcher.appendCount == 1)
    }

    @Test("Cancel is immediate while a frame is awaited and releases every timer")
    func cancelWhileBlocked() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        await Self.deliverFrames(h, 1)
        await waitFor("deadline and settle armed") { Self.settleArmed(h, steps: 1) }
        h.model.cancel()
        #expect(h.model.state == .canceled)
        #expect(h.frames.frames.waiterCount == 0)
        #expect(h.scroller.stopCount >= 1)
        await waitFor("timers released") { h.clock.pendingSleepCount == 0 }
        h.clock.advance(bySeconds: Self.maxSeconds * 2)
        await drain()
        #expect(h.model.state == .canceled)
        #expect(h.scroller.stepCount == 1)
    }

    @Test("Resuming in automatic mode scrolls again instead of waiting for a frame")
    func automaticResumeSteps() async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        await Self.deliverFrames(h, 1)
        #expect(h.scroller.stepCount == 1)
        h.model.pause()
        h.model.resume()
        await waitFor("stepped on resume") { h.scroller.stepCount == 2 }
        #expect(h.model.state == .collecting)
    }

    // MARK: Interrupts

    @Test(
        "An interrupt stops an active session at once and discards the stitch",
        arguments: [ScrollFailure.targetLost, .permissionRevoked, .displayChanged, .screenLocked, .noFrames])
    func interruptWhileCollecting(failure: ScrollFailure) async {
        let h = ScrollHarness(trusted: true, automaticPreference: true)
        await h.startCollecting()
        await Self.deliverFrames(h, 1)
        let resetsBefore = h.stitcher.resetCount
        h.model.interrupt(because: failure)
        #expect(h.model.state == .failed(failure))
        #expect(h.frames.stopCount >= 1)
        #expect(h.frames.frames.waiterCount == 0)
        #expect(h.scroller.stopCount >= 1)
        #expect(h.stitcher.resetCount > resetsBefore)
        #expect(h.model.acceptedFrames == 0)
        #expect(h.model.preview == nil)
        #expect(h.frames.deliver() == false)
        await waitFor("timers released") { h.clock.pendingSleepCount == 0 }
        h.clock.advance(bySeconds: Self.maxSeconds * 2)
        await drain()
        #expect(h.model.state == .failed(failure))
        #expect(h.stitcher.appendCount == 1)
        #expect(h.scroller.stepCount == 1)
        #expect(h.accepted.isEmpty)
    }

    @Test("An interrupt also ends a paused, armed, or selecting session")
    func interruptOtherActiveStates() async {
        let paused = ScrollHarness()
        await paused.startCollecting()
        await Self.deliverFrames(paused, 1)
        paused.model.pause()
        paused.model.interrupt(because: .displayChanged)
        #expect(paused.model.state == .failed(.displayChanged))
        #expect(paused.frames.stopCount >= 1)

        let armed = ScrollHarness()
        _ = await armed.model.begin()
        armed.model.chooseTarget(armed.target)
        armed.model.interrupt(because: .screenLocked)
        #expect(armed.model.state == .failed(.screenLocked))
        armed.model.start()
        #expect(armed.frames.startCount == 0)

        let selecting = ScrollHarness()
        _ = await selecting.model.begin()
        selecting.model.interrupt(because: .permissionRevoked)
        #expect(selecting.model.state == .failed(.permissionRevoked))
        #expect(selecting.frames.startCount == 0)
    }

    @Test("An interrupt leaves a finished review and an idle model alone")
    func interruptOutsideCapture() async {
        let idle = ScrollHarness()
        idle.model.interrupt(because: .screenLocked)
        #expect(idle.model.state == .idle)

        let h = ScrollHarness()
        await h.startCollecting()
        await Self.deliverFrames(h, 1)
        h.model.stop()
        #expect(h.model.state == .reviewing)
        h.model.interrupt(because: .screenLocked)
        #expect(h.model.state == .reviewing)
        await h.model.accept()
        #expect(h.model.state == .accepted)
        #expect(h.accepted.count == 1)
    }
}
