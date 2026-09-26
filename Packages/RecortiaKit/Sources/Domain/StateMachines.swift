import Foundation

public struct StateTransitionError: Error, Equatable, Sendable, CustomStringConvertible {
    public let from: String
    public let event: String

    public var description: String { "Illegal transition from \(from) on \(event)" }
}

// MARK: - Capture

public enum CaptureFailure: Hashable, Sendable {
    case permissionDenied
    case targetUnavailable
    case displayChanged
    case screenLocked
    case protectedContent
    case system(code: Int)
}

/// Capture: idle → permissionCheck → selecting/countdown → capturing → editing, with explicit
/// canceled and failed terminals that return to idle (SPEC.md §6).
public enum CaptureState: Hashable, Sendable {
    case idle
    case permissionCheck
    case selecting
    case countdown(remaining: Int)
    case capturing
    case editing
    case canceled
    case failed(CaptureFailure)

    public var isActive: Bool {
        switch self {
        case .permissionCheck, .selecting, .countdown, .capturing: true
        default: false
        }
    }

    public func next(_ event: CaptureEvent) throws -> CaptureState {
        switch (self, event) {
        case (.idle, .request): return .permissionCheck
        case (.permissionCheck, .permissionGranted): return .selecting
        case (.permissionCheck, .permissionDenied): return .failed(.permissionDenied)
        case (.selecting, .selectionCommitted(let delay)): return delay > 0 ? .countdown(remaining: delay) : .capturing
        case (.countdown(let remaining), .countdownTick):
            return remaining > 1 ? .countdown(remaining: remaining - 1) : .capturing
        case (.countdown, .countdownFinished): return .capturing
        case (.capturing, .captureSucceeded): return .editing
        case (.capturing, .captureFailed(let failure)), (.selecting, .captureFailed(let failure)),
            (.countdown, .captureFailed(let failure)):
            return .failed(failure)
        case (let state, .cancel) where state.isActive: return .canceled
        case (.canceled, .reset), (.failed, .reset), (.editing, .reset): return .idle
        default: throw StateTransitionError(from: "\(self)", event: "\(event)")
        }
    }
}

public enum CaptureEvent: Hashable, Sendable {
    case request
    case permissionGranted
    case permissionDenied
    case selectionCommitted(delaySeconds: Int)
    case countdownTick
    case countdownFinished
    case captureSucceeded
    case captureFailed(CaptureFailure)
    case cancel
    case reset
}

// MARK: - Scroll

public enum ScrollPauseReason: Hashable, Sendable, Codable {
    case userPaused
    case ambiguousMatch
    case reversedDirection
    case lowConfidence
}

public enum ScrollFailure: Hashable, Sendable {
    case targetLost
    case permissionRevoked
    case displayChanged
    case screenLocked
    case noFrames
}

/// Scroll: idle → selecting → armed → collecting ⇄ paused → reviewing → accepted, plus canceled/failed.
public enum ScrollState: Hashable, Sendable {
    case idle
    case selecting
    case armed
    case collecting
    case paused(ScrollPauseReason)
    case reviewing
    case accepted
    case canceled
    case failed(ScrollFailure)

    public var isActive: Bool {
        switch self {
        case .selecting, .armed, .collecting, .paused, .reviewing: true
        default: false
        }
    }

    public func next(_ event: ScrollEvent) throws -> ScrollState {
        switch (self, event) {
        case (.idle, .begin): return .selecting
        case (.selecting, .targetChosen): return .armed
        case (.armed, .start): return .collecting
        case (.collecting, .pause(let reason)): return .paused(reason)
        case (.paused, .resume): return .collecting
        case (.collecting, .stop), (.paused, .stop), (.collecting, .limitReached): return .reviewing
        case (.reviewing, .accept): return .accepted
        case (.armed, .targetLost), (.collecting, .targetLost), (.paused, .targetLost): return .failed(.targetLost)
        case (let state, .fail(let failure)) where state.isActive: return .failed(failure)
        case (let state, .cancel) where state.isActive: return .canceled
        case (.accepted, .reset), (.canceled, .reset), (.failed, .reset): return .idle
        default: throw StateTransitionError(from: "\(self)", event: "\(event)")
        }
    }
}

public enum ScrollEvent: Hashable, Sendable {
    case begin
    case targetChosen
    case start
    case pause(ScrollPauseReason)
    case resume
    case stop
    case limitReached(ScrollLimit)
    case accept
    case targetLost
    case fail(ScrollFailure)
    case cancel
    case reset
}

// MARK: - Export

public enum ExportFailure: Hashable, Sendable {
    case renderFailed
    case encodeFailed
    case budgetExceeded
    case clipboardFailed
    case accessDenied
    case destinationExists
    case diskFull
    case volumeUnavailable
    case staleDocument
    case system(code: Int)
}

/// Export: requested → snapshotting → sanitizing → rendering → encoding → committing → succeeded.
/// Failure or cancellation before commit never reports success; cancellation during or after the
/// commit reports that the action already completed.
public enum ExportState: Hashable, Sendable {
    case requested
    case snapshotting
    case sanitizing
    case rendering
    case encoding
    case committing
    case succeeded(canceledAfterCommit: Bool)
    case failed(ExportFailure)
    case canceled

    private var isBeforeCommit: Bool {
        switch self {
        case .requested, .snapshotting, .sanitizing, .rendering, .encoding: true
        default: false
        }
    }

    public func next(_ event: ExportEvent) throws -> ExportState {
        switch (self, event) {
        case (.requested, .snapshot): return .snapshotting
        case (.snapshotting, .sanitize): return .sanitizing
        case (.sanitizing, .render): return .rendering
        case (.rendering, .encode): return .encoding
        case (.encoding, .commit): return .committing
        case (.committing, .committed): return .succeeded(canceledAfterCommit: false)
        case (.committing, .cancel): return .succeeded(canceledAfterCommit: true)
        case (.committing, .fail(let failure)): return .failed(failure)
        case (let state, .cancel) where state.isBeforeCommit: return .canceled
        case (let state, .fail(let failure)) where state.isBeforeCommit: return .failed(failure)
        default: throw StateTransitionError(from: "\(self)", event: "\(event)")
        }
    }
}

public enum ExportEvent: Hashable, Sendable {
    case snapshot
    case sanitize
    case render
    case encode
    case commit
    case committed
    case cancel
    case fail(ExportFailure)
}
