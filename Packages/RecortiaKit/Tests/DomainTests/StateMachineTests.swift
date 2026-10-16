import Testing

@testable import Domain

@Suite("Capture, scroll, and export state machines (SPEC §6)")
struct StateMachineTests {

    @Test("Cancel from any active capture state is terminal and returns to idle")
    func cancelFromAnyActiveState() throws {
        for state in [CaptureState.permissionCheck, .selecting, .countdown(remaining: 2), .capturing] {
            let canceled = try state.next(.cancel)
            #expect(canceled == .canceled)
            #expect(try canceled.next(.reset) == .idle)
        }
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
