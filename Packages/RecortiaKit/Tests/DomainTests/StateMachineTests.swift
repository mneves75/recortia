import Testing

@testable import Domain

@Suite("Capture, scroll, and export state machines (SPEC §6)")
struct StateMachineTests {

    @Test("CaptureState exhaustive valid and illegal transition matrix")
    func captureStateMatrix() throws {
        let states: [CaptureState] = [
            .idle,
            .permissionCheck,
            .selecting,
            .countdown(remaining: 2),
            .countdown(remaining: 1),
            .countdown(remaining: 0),
            .capturing,
            .editing,
            .canceled,
            .failed(.permissionDenied),
            .failed(.displayChanged),
        ]
        let events: [CaptureEvent] = [
            .request,
            .permissionGranted,
            .permissionDenied,
            .selectionCommitted(delaySeconds: 0),
            .selectionCommitted(delaySeconds: 3),
            .selectionCommitted(delaySeconds: -1),
            .countdownTick,
            .countdownFinished,
            .captureSucceeded,
            .captureFailed(.screenLocked),
            .cancel,
            .reset,
        ]

        func expected(from state: CaptureState, on event: CaptureEvent) -> CaptureState? {
            switch (state, event) {
            case (.idle, .request): .permissionCheck
            case (.permissionCheck, .permissionGranted): .selecting
            case (.permissionCheck, .permissionDenied): .failed(.permissionDenied)
            case (.selecting, .selectionCommitted(let delay)):
                delay > 0 ? .countdown(remaining: delay) : .capturing
            case (.countdown(let remaining), .countdownTick):
                remaining > 1 ? .countdown(remaining: remaining - 1) : .capturing
            case (.countdown, .countdownFinished): .capturing
            case (.capturing, .captureSucceeded): .editing
            case (.selecting, .captureFailed(let failure)),
                (.countdown, .captureFailed(let failure)),
                (.capturing, .captureFailed(let failure)):
                .failed(failure)
            case (let current, .cancel) where current.isActive: .canceled
            case (.editing, .reset), (.canceled, .reset), (.failed, .reset): .idle
            default: nil
            }
        }

        for state in states {
            let expectedActive =
                switch state {
                case .permissionCheck, .selecting, .countdown, .capturing: true
                case .idle, .editing, .canceled, .failed: false
                }
            #expect(state.isActive == expectedActive, "isActive mismatch for \(state)")

            for event in events {
                if let target = expected(from: state, on: event) {
                    let actual = try state.next(event)
                    #expect(actual == target, "\(state) + \(event) -> \(actual), expected \(target)")
                } else {
                    #expect(throws: StateTransitionError(from: "\(state)", event: "\(event)")) {
                        _ = try state.next(event)
                    }
                }
            }
        }
    }

    @Test("ScrollState exhaustive valid and illegal transition matrix")
    func scrollStateMatrix() throws {
        let states: [ScrollState] = [
            .idle,
            .selecting,
            .armed,
            .collecting,
            .paused(.userPaused),
            .paused(.ambiguousMatch),
            .reviewing,
            .accepted,
            .canceled,
            .failed(.targetLost),
            .failed(.noFrames),
        ]
        let events: [ScrollEvent] = [
            .begin,
            .targetChosen,
            .start,
            .pause(.userPaused),
            .pause(.lowConfidence),
            .resume,
            .stop,
            .limitReached(.duration),
            .accept,
            .targetLost,
            .fail(.screenLocked),
            .cancel,
            .reset,
        ]

        func expected(from state: ScrollState, on event: ScrollEvent) -> ScrollState? {
            switch (state, event) {
            case (.idle, .begin): .selecting
            case (.selecting, .targetChosen): .armed
            case (.armed, .start): .collecting
            case (.collecting, .pause(let reason)): .paused(reason)
            case (.paused, .resume): .collecting
            case (.collecting, .stop), (.paused, .stop), (.collecting, .limitReached): .reviewing
            case (.reviewing, .accept): .accepted
            case (.armed, .targetLost), (.collecting, .targetLost), (.paused, .targetLost):
                .failed(.targetLost)
            case (let current, .fail(let failure)) where current.isActive: .failed(failure)
            case (let current, .cancel) where current.isActive: .canceled
            case (.accepted, .reset), (.canceled, .reset), (.failed, .reset): .idle
            default: nil
            }
        }

        for state in states {
            let expectedActive =
                switch state {
                case .selecting, .armed, .collecting, .paused, .reviewing: true
                case .idle, .accepted, .canceled, .failed: false
                }
            #expect(state.isActive == expectedActive, "isActive mismatch for \(state)")

            for event in events {
                if let target = expected(from: state, on: event) {
                    let actual = try state.next(event)
                    #expect(actual == target, "\(state) + \(event) -> \(actual), expected \(target)")
                } else {
                    #expect(throws: StateTransitionError(from: "\(state)", event: "\(event)")) {
                        _ = try state.next(event)
                    }
                }
            }
        }
    }

    @Test("ExportState exhaustive valid and illegal transition matrix")
    func exportStateMatrix() throws {
        let states: [ExportState] = [
            .requested,
            .snapshotting,
            .sanitizing,
            .rendering,
            .encoding,
            .committing,
            .succeeded(canceledAfterCommit: false),
            .succeeded(canceledAfterCommit: true),
            .failed(.renderFailed),
            .canceled,
        ]
        let events: [ExportEvent] = [
            .snapshot,
            .sanitize,
            .render,
            .encode,
            .commit,
            .destinationCollision,
            .committed,
            .cancel,
            .fail(.diskFull),
        ]

        func expected(from state: ExportState, on event: ExportEvent) -> ExportState? {
            switch (state, event) {
            case (.requested, .snapshot): .snapshotting
            case (.snapshotting, .sanitize): .sanitizing
            case (.sanitizing, .render): .rendering
            case (.rendering, .encode): .encoding
            case (.encoding, .commit): .committing
            case (.committing, .destinationCollision): .encoding
            case (.committing, .committed): .succeeded(canceledAfterCommit: false)
            case (.committing, .cancel): .succeeded(canceledAfterCommit: true)
            case (.committing, .fail(let failure)): .failed(failure)
            case (.requested, .cancel), (.snapshotting, .cancel), (.sanitizing, .cancel),
                (.rendering, .cancel), (.encoding, .cancel):
                .canceled
            case (.requested, .fail(let failure)), (.snapshotting, .fail(let failure)),
                (.sanitizing, .fail(let failure)), (.rendering, .fail(let failure)),
                (.encoding, .fail(let failure)):
                .failed(failure)
            default: nil
            }
        }

        for state in states {
            for event in events {
                if let target = expected(from: state, on: event) {
                    let actual = try state.next(event)
                    #expect(actual == target, "\(state) + \(event) -> \(actual), expected \(target)")
                } else {
                    #expect(throws: StateTransitionError(from: "\(state)", event: "\(event)")) {
                        _ = try state.next(event)
                    }
                }
            }
        }
    }
}
