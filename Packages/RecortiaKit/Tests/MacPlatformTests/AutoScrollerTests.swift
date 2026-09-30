import CoreGraphics
import Domain
import Foundation
import Testing

@testable import MacPlatform

private let targetPID: pid_t = 777
private let display = TestSupport.display(id: 1, x: 0, y: 0, width: 1440, height: 900, scale: 2)
private let target = WindowInfo(
    id: 42, ownerName: "Browser", ownerPID: targetPID, title: nil, frame: Rect(x: 100, y: 100, width: 800, height: 600),
    displayID: 1)

private func observation(
    frontmost: pid_t? = targetPID, onScreen: Bool = true, fingerprint: String? = display.fingerprint,
    trusted: Bool = true
) -> AutoScrollObservation {
    AutoScrollObservation(
        frontmostPID: frontmost, targetWindowOnScreen: onScreen, displayFingerprint: fingerprint,
        accessibilityTrusted: trusted)
}

@MainActor
final class FakeScrollEnvironment: AutoScrollEnvironment {
    var current: AutoScrollObservation
    var observedWindowIDs: [CGWindowID] = []

    init(_ observation: AutoScrollObservation) { current = observation }

    func observe(windowID: CGWindowID, displayID: CGDirectDisplayID) -> AutoScrollObservation {
        observedWindowIDs.append(windowID)
        return current
    }
}

@MainActor
final class FakeScrollPoster: ScrollEventPosting {
    struct Post: Equatable {
        var pixels: Int32
        var location: CGPoint
        var pid: pid_t
    }

    var posts: [Post] = []
    var succeeds = true

    func postScroll(pixels: Int32, at location: CGPoint, toProcess pid: pid_t) -> Bool {
        posts.append(Post(pixels: pixels, location: location, pid: pid))
        return succeeds
    }
}

@Suite("Automatic scrolling stop policy (FR-10, SCR-03)")
struct AutoScrollStopPolicyTests {
    let policy = AutoScrollStopPolicy(
        targetPID: targetPID, controllerPID: ProcessInfo.processInfo.processIdentifier,
        displayFingerprint: display.fingerprint)

    @Test("An unchanged environment continues")
    func unchangedContinues() {
        #expect(policy.stopReason(for: observation()) == nil)
        #expect(policy.stopReason(for: observation(frontmost: ProcessInfo.processInfo.processIdentifier)) == nil)
    }

    @Test(
        "Each change stops scrolling with its own reason",
        arguments: [
            (observation(frontmost: 1), AutoScrollStopReason.frontmostAppChanged),
            (observation(frontmost: nil), .frontmostAppChanged),
            (observation(onScreen: false), .targetWindowGone),
            (observation(fingerprint: "other"), .displayChanged),
            (observation(fingerprint: nil), .displayChanged),
            (observation(trusted: false), .accessibilityRevoked),
        ])
    func changesStop(observation: AutoScrollObservation, expected: AutoScrollStopReason) {
        #expect(policy.stopReason(for: observation) == expected)
    }

    @Test("Revoked Accessibility wins over every other reason, then a vanished target")
    func priority() {
        let everything = observation(frontmost: 1, onScreen: false, fingerprint: nil, trusted: false)
        #expect(policy.stopReason(for: everything) == .accessibilityRevoked)
        let noTarget = observation(frontmost: 1, onScreen: false, fingerprint: nil)
        #expect(policy.stopReason(for: noTarget) == .targetWindowGone)
    }
}

@MainActor
@Suite("Automatic scroller: targeted scroll events only while the policy allows (FR-10, PERM-01)")
struct AutoScrollerTests {
    @Test("Live target validation rejects moved, replaced, malformed, and covered windows")
    func targetIdentityBeforeEvents() {
        func entry(id: UInt32 = 42, pid: pid_t = targetPID, x: Double = 100) -> [String: Any] {
            [
                kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowIsOnscreen as String: true, kCGWindowLayer as String: 0,
                kCGWindowBounds as String: ["X": x, "Y": 100.0, "Width": 800.0, "Height": 600.0],
            ]
        }
        let point = CGPoint(x: 500, y: 400)
        #expect(LiveAutoScrollEnvironment.targetIsCurrent(target, at: point, in: [entry()]))
        for list in [
            [entry(x: 101)], [entry(pid: 778)], [[kCGWindowNumber as String: 42]],
            [entry(id: 43), entry()], [],
        ] {
            #expect(!LiveAutoScrollEnvironment.targetIsCurrent(target, at: point, in: list))
        }
        // The controller's HUD is excluded; other windows of the target app are not.
        #expect(
            LiveAutoScrollEnvironment.targetIsCurrent(
                target, at: point,
                in: [
                    entry(id: 99, pid: ProcessInfo.processInfo.processIdentifier), entry(),
                ]))
    }

    private func make(_ observation: AutoScrollObservation = observation()) throws -> (
        AutoScroller, FakeScrollEnvironment, FakeScrollPoster
    ) {
        let environment = FakeScrollEnvironment(observation)
        let poster = FakeScrollPoster()
        let scroller = try AutoScroller(
            target: target, display: display, scrollPoint: Point(x: 500, y: 400), environment: environment,
            poster: poster)
        return (scroller, environment, poster)
    }

    @Test("Starting without Accessibility fails and posts nothing")
    func requiresAccessibility() throws {
        let (scroller, _, poster) = try make(observation(trusted: false))
        #expect(throws: AutoScrollError.accessibilityNotTrusted) { try scroller.start() }
        #expect(scroller.scrollDown(byPixels: 40) == .notRunning)
        #expect(poster.posts.isEmpty)
    }

    @Test("A scroll point outside the target window is rejected")
    func scrollPointMustBeInsideTarget() {
        #expect(throws: AutoScrollError.targetUnavailable) {
            _ = try AutoScroller(
                target: target, display: display, scrollPoint: Point(x: 50, y: 50),
                environment: FakeScrollEnvironment(observation()), poster: FakeScrollPoster())
        }
    }

    @Test("Scrolling posts one pixel scroll-wheel event to the target process at the scroll point")
    func postsTargetedEvent() throws {
        let (scroller, environment, poster) = try make()
        try scroller.start()
        #expect(scroller.scrollDown(byPixels: 40) == .scrolled)
        #expect(poster.posts == [FakeScrollPoster.Post(pixels: -40, location: CGPoint(x: 500, y: 400), pid: targetPID)])
        #expect(environment.observedWindowIDs.allSatisfy { $0 == 42 })
    }

    @Test("Step sizes are bounded")
    func boundedSteps() throws {
        let (scroller, _, poster) = try make()
        try scroller.start()
        _ = scroller.scrollDown(byPixels: 50_000)
        _ = scroller.scrollDown(byPixels: 0)
        #expect(poster.posts.map(\.pixels) == [-Int32(AutoScroller.maxStepPixels), -1])
    }

    @Test("A frontmost-app change stops before the next event and stays stopped")
    func frontmostChangeLatches() throws {
        let (scroller, environment, poster) = try make()
        try scroller.start()
        #expect(scroller.scrollDown(byPixels: 10) == .scrolled)
        environment.current = observation(frontmost: 1)
        #expect(scroller.scrollDown(byPixels: 10) == .stopped(.frontmostAppChanged))
        environment.current = observation()
        #expect(scroller.scrollDown(byPixels: 10) == .stopped(.frontmostAppChanged))
        #expect(poster.posts.count == 1)
        #expect(scroller.state == .stopped(.frontmostAppChanged))
    }

    @Test(
        "Target disappearance, display change, and revoked Accessibility each stop scrolling",
        arguments: [
            (observation(onScreen: false), AutoScrollStopReason.targetWindowGone),
            (observation(fingerprint: "rotated"), .displayChanged),
            (observation(trusted: false), .accessibilityRevoked),
        ])
    func environmentChangesStop(changed: AutoScrollObservation, expected: AutoScrollStopReason) throws {
        let (scroller, environment, poster) = try make()
        try scroller.start()
        environment.current = changed
        #expect(scroller.scrollDown(byPixels: 10) == .stopped(expected))
        #expect(poster.posts.isEmpty)
    }

    @Test("A chosen window in a background app cannot receive automatic scroll events")
    func frontmostMustOwnTargetAtStart() throws {
        let (scroller, _, poster) = try make(observation(frontmost: 555))
        #expect(throws: AutoScrollError.targetUnavailable) { try scroller.start() }
        #expect(scroller.scrollDown(byPixels: 10) == .notRunning)
        #expect(poster.posts.isEmpty)
    }

    @Test("The scrolling HUD may have focus when its target is started")
    func controllerMayOwnFocusAtStart() throws {
        let (scroller, environment, poster) = try make(
            observation(frontmost: ProcessInfo.processInfo.processIdentifier))
        try scroller.start()
        #expect(scroller.scrollDown(byPixels: 10) == .scrolled)
        environment.current = observation(frontmost: targetPID)
        #expect(scroller.scrollDown(byPixels: 10) == .scrolled)
        environment.current = observation(frontmost: 555)
        #expect(scroller.scrollDown(byPixels: 10) == .stopped(.frontmostAppChanged))
        #expect(poster.posts.count == 2)
    }

    @Test("A failed event post stops scrolling")
    func postFailureStops() throws {
        let (scroller, _, poster) = try make()
        poster.succeeds = false
        try scroller.start()
        #expect(scroller.scrollDown(byPixels: 10) == .stopped(.eventPostFailed))
        #expect(scroller.scrollDown(byPixels: 10) == .stopped(.eventPostFailed))
        #expect(poster.posts.count == 1)
    }

    @Test("An explicit stop prevents further events; a stopped scroller cannot restart")
    func explicitStop() throws {
        let (scroller, _, poster) = try make()
        try scroller.start()
        scroller.stop()
        #expect(scroller.scrollDown(byPixels: 10) == .stopped(.requested))
        #expect(throws: AutoScrollError.alreadyStopped) { try scroller.start() }
        #expect(poster.posts.isEmpty)
    }

    @Test("Starting when the environment already changed refuses to run")
    func startChecksPolicy() throws {
        let (scroller, _, poster) = try make(observation(onScreen: false))
        #expect(throws: AutoScrollError.targetUnavailable) { try scroller.start() }
        #expect(scroller.scrollDown(byPixels: 10) == .notRunning)
        #expect(poster.posts.isEmpty)
    }
}
