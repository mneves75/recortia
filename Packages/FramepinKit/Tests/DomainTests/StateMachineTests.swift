import Testing

@testable import Domain

@Suite("Capture, scroll, and export state machines (SPEC §6)")
struct StateMachineTests {
    @Test("Capture happy path")
    func captureHappyPath() throws {
        var state = CaptureState.idle
        state = try state.next(.request)
        #expect(state == .permissionCheck)
        state = try state.next(.permissionGranted)
        #expect(state == .selecting)
        state = try state.next(.selectionCommitted(delaySeconds: 3))
        #expect(state == .countdown(remaining: 3))
        state = try state.next(.countdownFinished)
        #expect(state == .capturing)
        state = try state.next(.captureSucceeded)
        #expect(state == .editing)
    }

    @Test("Zero delay skips the countdown")
    func zeroDelaySkipsCountdown() throws {
        let state = try CaptureState.selecting.next(.selectionCommitted(delaySeconds: 0))
        #expect(state == .capturing)
    }

    @Test("Cancel from any active capture state is terminal and returns to idle")
    func cancelFromAnyActiveState() throws {
        for state in [CaptureState.permissionCheck, .selecting, .countdown(remaining: 2), .capturing] {
            let canceled = try state.next(.cancel)
            #expect(canceled == .canceled)
            #expect(try canceled.next(.reset) == .idle)
        }
    }

    @Test("Illegal capture transitions throw instead of silently continuing")
    func illegalCaptureTransitions() {
        #expect(throws: StateTransitionError.self) { try CaptureState.idle.next(.captureSucceeded) }
        #expect(throws: StateTransitionError.self) { try CaptureState.editing.next(.permissionGranted) }
        #expect(throws: StateTransitionError.self) { try CaptureState.capturing.next(.request) }
    }

    @Test("Denied permission fails the capture with a typed reason")
    func deniedPermission() throws {
        let state = try CaptureState.permissionCheck.next(.permissionDenied)
        #expect(state == .failed(.permissionDenied))
    }

    @Test("Scroll session: collect, pause, resume, review, accept")
    func scrollFlow() throws {
        var state = ScrollState.idle
        for event: ScrollEvent in [.begin, .targetChosen, .start, .pause(.ambiguousMatch), .resume, .stop, .accept] {
            state = try state.next(event)
        }
        #expect(state == .accepted)
    }

    @Test("A scroll target change stops collection as a failure, never a success")
    func scrollTargetLost() throws {
        let state = try ScrollState.collecting.next(.targetLost)
        #expect(state == .failed(.targetLost))
    }

    @Test("Export cancellation after commit reports the action already completed")
    func exportCancelAfterCommit() throws {
        var state = ExportState.requested
        for event: ExportEvent in [.snapshot, .sanitize, .render, .encode, .commit] {
            state = try state.next(event)
        }
        #expect(state == .committing)
        #expect(try state.next(.cancel) == .succeeded(canceledAfterCommit: true))
        #expect(try ExportState.encoding.next(.cancel) == .canceled)
        #expect(try ExportState.rendering.next(.fail(.renderFailed)) == .failed(.renderFailed))
    }
}
