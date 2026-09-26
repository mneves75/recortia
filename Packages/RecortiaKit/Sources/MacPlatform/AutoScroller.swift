import AppKit
import CoreGraphics
import Domain
import Foundation

public enum AutoScrollStopReason: Sendable, Equatable {
    case requested
    case frontmostAppChanged
    case targetWindowGone
    case displayChanged
    case accessibilityRevoked
    case eventPostFailed
}

public enum AutoScrollError: Error, Equatable, Sendable {
    /// Accessibility is not granted. The scroller never prompts; the settings flow asks explicitly.
    case accessibilityNotTrusted
    case targetUnavailable
    case displayChanged
    case alreadyStopped
}

/// What the scroller checks before every synthetic event.
public struct AutoScrollObservation: Sendable, Equatable {
    public var frontmostPID: pid_t?
    public var targetWindowOnScreen: Bool
    /// Current fingerprint of the target's display; nil when the display is gone.
    public var displayFingerprint: String?
    public var accessibilityTrusted: Bool

    public init(
        frontmostPID: pid_t?, targetWindowOnScreen: Bool, displayFingerprint: String?, accessibilityTrusted: Bool
    ) {
        self.frontmostPID = frontmostPID
        self.targetWindowOnScreen = targetWindowOnScreen
        self.displayFingerprint = displayFingerprint
        self.accessibilityTrusted = accessibilityTrusted
    }
}

/// Pure stop rules for automatic scrolling (FR-10, SCR-03): any change of the frontmost app, the
/// target window, the display configuration, or the Accessibility grant stops scrolling.
public struct AutoScrollStopPolicy: Sendable, Equatable {
    public let frontmostPIDAtStart: pid_t?
    public let displayFingerprint: String

    public init(frontmostPIDAtStart: pid_t?, displayFingerprint: String) {
        self.frontmostPIDAtStart = frontmostPIDAtStart
        self.displayFingerprint = displayFingerprint
    }

    /// Nil to continue; otherwise the most fundamental reason to stop.
    public func stopReason(for observation: AutoScrollObservation) -> AutoScrollStopReason? {
        if !observation.accessibilityTrusted { return .accessibilityRevoked }
        if !observation.targetWindowOnScreen { return .targetWindowGone }
        if observation.displayFingerprint != displayFingerprint { return .displayChanged }
        if observation.frontmostPID != frontmostPIDAtStart { return .frontmostAppChanged }
        return nil
    }
}

public enum AutoScrollStepResult: Sendable, Equatable {
    case scrolled
    case stopped(AutoScrollStopReason)
    case notRunning
}

@MainActor
protocol AutoScrollEnvironment {
    func observe(windowID: CGWindowID, displayID: CGDirectDisplayID) -> AutoScrollObservation
}

@MainActor
protocol ScrollEventPosting {
    /// Posts one pixel-unit scroll-wheel event to `pid` only. Negative values scroll content down.
    func postScroll(pixels: Int32, at location: CGPoint, toProcess pid: pid_t) -> Bool
}

/// Minimal targeted scrolling for automatic scrolling capture (FR-10). It posts only vertical
/// scroll-wheel events, only to the chosen target process, only while Accessibility is granted and
/// nothing relevant changed. No typing, clicking, AppleScript, clipboard reads, or event taps.
/// Once stopped, it stays stopped.
@MainActor
public final class AutoScroller {
    public enum State: Sendable, Equatable {
        case idle
        case running
        case stopped(AutoScrollStopReason)
    }

    /// Upper bound for one step, in points; larger requests are clamped.
    public static let maxStepPixels = 1_000

    public let target: WindowInfo
    public let display: DisplayInfo
    public private(set) var state: State = .idle

    private let scrollLocation: CGPoint
    private let environment: any AutoScrollEnvironment
    private let poster: any ScrollEventPosting
    private var policy: AutoScrollStopPolicy?
    private var activationObserver: (any NSObjectProtocol)?
    private var observesActivations = false

    /// A live scroller. `scrollPoint` must lie inside the target window; events carry it as their
    /// location so the target app routes them to the view under it.
    public convenience init(target: WindowInfo, display: DisplayInfo, scrollPoint: Point<DesktopSpace>)
        throws(AutoScrollError)
    {
        try self.init(
            target: target, display: display, scrollPoint: scrollPoint, environment: LiveAutoScrollEnvironment(),
            poster: TargetedScrollEventPoster())
        observesActivations = true
    }

    init(
        target: WindowInfo, display: DisplayInfo, scrollPoint: Point<DesktopSpace>,
        environment: any AutoScrollEnvironment, poster: any ScrollEventPosting
    ) throws(AutoScrollError) {
        guard target.frame.contains(scrollPoint) else { throw .targetUnavailable }
        self.target = target
        self.display = display
        scrollLocation = CGPoint(x: scrollPoint.x, y: scrollPoint.y)
        self.environment = environment
        self.poster = poster
    }

    public func start() throws(AutoScrollError) {
        guard state == .idle else { throw .alreadyStopped }
        let observation = environment.observe(windowID: target.id, displayID: display.id)
        guard observation.accessibilityTrusted else { throw .accessibilityNotTrusted }
        guard observation.targetWindowOnScreen else { throw .targetUnavailable }
        guard observation.displayFingerprint == display.fingerprint else { throw .displayChanged }
        policy = AutoScrollStopPolicy(
            frontmostPIDAtStart: observation.frontmostPID, displayFingerprint: display.fingerprint)
        state = .running
        if observesActivations { observeActivations() }
    }

    /// Checks the stop policy, then posts one scroll step revealing content below.
    public func scrollDown(byPixels pixels: Int) -> AutoScrollStepResult {
        switch state {
        case .idle: return .notRunning
        case .stopped(let reason): return .stopped(reason)
        case .running: break
        }
        guard let policy else { return .notRunning }
        if let reason = policy.stopReason(for: environment.observe(windowID: target.id, displayID: display.id)) {
            stop(reason: reason)
            return .stopped(reason)
        }
        let step = Int32(min(max(pixels, 1), Self.maxStepPixels))
        guard poster.postScroll(pixels: -step, at: scrollLocation, toProcess: target.ownerPID) else {
            stop(reason: .eventPostFailed)
            return .stopped(.eventPostFailed)
        }
        return .scrolled
    }

    public func stop(reason: AutoScrollStopReason = .requested) {
        if case .stopped = state { return }
        state = .stopped(reason)
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// Stops at once when another app becomes active, without waiting for the next step. Only the
    /// live initializer installs it; the per-step policy check is the guarantee either way.
    private func observeActivations() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .running, let policy = self.policy else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != policy.frontmostPIDAtStart {
                    self.stop(reason: .frontmostAppChanged)
                }
            }
        }
    }
}

// MARK: - Live environment

@MainActor
struct LiveAutoScrollEnvironment: AutoScrollEnvironment {
    func observe(windowID: CGWindowID, displayID: CGDirectDisplayID) -> AutoScrollObservation {
        AutoScrollObservation(
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            targetWindowOnScreen: Self.isOnScreen(windowID),
            displayFingerprint: DesktopGeometry.displays().first { $0.id == displayID }?.fingerprint,
            accessibilityTrusted: AccessibilityPermission.isTrusted)
    }

    /// Reads only the on-screen flag of one window; no titles or pixels.
    private static func isOnScreen(_ windowID: CGWindowID) -> Bool {
        guard
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let entry = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
        else { return false }
        return (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }
}

@MainActor
struct TargetedScrollEventPoster: ScrollEventPosting {
    func postScroll(pixels: Int32, at location: CGPoint, toProcess pid: pid_t) -> Bool {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)
        else { return false }
        event.location = location
        event.postToPid(pid)
        return true
    }
}
