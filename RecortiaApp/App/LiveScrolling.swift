import AppKit
import ApplicationServices
import Domain
import Features
import MacPlatform

struct ScrollWindowBinding: Equatable {
    let sessionID: UUID
    let windowID: CGWindowID
}

@MainActor
protocol AutoScrollDriving: AnyObject {
    func start() throws(AutoScrollError)
    func scrollDown(byPixels pixels: Int) -> AutoScrollStepResult
    func stop(reason: AutoScrollStopReason)
}

extension AutoScroller: AutoScrollDriving {}

/// Adapts MacPlatform's single-use `ScrollFrameSource` to the session protocol: each `start`
/// builds a new bounded stream for the chosen region; frames after `stop()` throw `.canceled`.
final class LiveScrollFrames: ScrollFrameSourceService {
    private var source: ScrollFrameSource?
    private var iterator: AsyncStream<CGImage>.AsyncIterator?
    private var sessionID = UUID()

    var boundWindowBinding: ScrollWindowBinding? {
        guard let windowID = source?.boundWindowID else { return nil }
        return ScrollWindowBinding(sessionID: sessionID, windowID: windowID)
    }

    func start(_ target: CaptureTarget) async throws(CaptureError) {
        stopSynchronously()
        guard let (region, display) = Self.region(for: target) else { throw .targetUnavailable }
        let source = ScrollFrameSource(region: region, display: display)
        self.source = source
        sessionID = UUID()
        iterator = source.frames.makeAsyncIterator()
        try await source.start()
    }

    func nextFrame() async throws(CaptureError) -> CGImage {
        guard let source, var iterator else { throw .canceled }
        let frame = await iterator.next(isolation: #isolation)
        // A stop and a new start may have run during the await; never overwrite the new iterator.
        guard self.source === source else { throw .canceled }
        self.iterator = iterator
        if let frame, await source.ensureTargetCurrent() { return frame }
        switch source.state {
        case .stopped(.failed(let error)): throw error
        case .stopped(.displayChanged): throw .displayChanged
        case .stopped(.targetChanged): throw .targetUnavailable
        default: throw .canceled
        }
    }

    func stop() {
        stopSynchronously()
    }

    private func stopSynchronously() {
        guard let source else { return }
        self.source = nil
        iterator = nil
        Task { await source.stop() }
    }

    static func region(for target: CaptureTarget) -> (Rect<DesktopSpace>, DisplayInfo)? {
        switch target {
        case .region(let rect, let display):
            return (rect, display)
        case .display(let display):
            return (display.frame, display)
        case .window(let window):
            guard let display = DesktopGeometry.displays().first(where: { $0.id == window.displayID }) else {
                return nil
            }
            return (window.frame, display)
        }
    }
}

/// Targeted automatic scrolling (FR-10, ADR-002). The scroller is created on the first step for
/// the frame source's bound window, and stops on any focus/target change.
final class LiveAutoScroll: AutoScrollService {
    /// Points per step: less than a typical viewport so consecutive frames overlap for matching.
    static let stepPoints = 240

    private let binding: @MainActor () -> ScrollWindowBinding?
    private let windows: @MainActor () async throws(CaptureError) -> [WindowInfo]
    private let frontmost: @MainActor (Point<DesktopSpace>) -> CGWindowID?
    private let makeDriver:
        @MainActor (WindowInfo, DisplayInfo, Point<DesktopSpace>) throws(AutoScrollError) -> any AutoScrollDriving
    private var scroller: (any AutoScrollDriving)?
    private var scrollerBinding: ScrollWindowBinding?
    private var generation = UUID()

    convenience init(frames: LiveScrollFrames) {
        self.init(binding: { frames.boundWindowBinding })
    }

    init(
        binding: @escaping @MainActor () -> ScrollWindowBinding?,
        windows: @escaping @MainActor () async throws(CaptureError) -> [WindowInfo] = {
            try await ScreenCaptureService().windows()
        },
        frontmost: @escaping @MainActor (Point<DesktopSpace>) -> CGWindowID? = ScrollFrameSource.frontmostWindowID(at:),
        makeDriver:
            @escaping @MainActor (WindowInfo, DisplayInfo, Point<DesktopSpace>) throws(AutoScrollError) ->
            any AutoScrollDriving = {
                try AutoScroller(target: $0, display: $1, scrollPoint: $2)
            }
    ) {
        self.binding = binding
        self.windows = windows
        self.frontmost = frontmost
        self.makeDriver = makeDriver
    }

    /// ScrollSessionModel's autoStepOwner serializes steps, including the first driver creation.
    func step(_ target: CaptureTarget) async -> AutoScrollStep {
        guard let expected = binding(), !Task.isCancelled else {
            stop()
            return .targetLost
        }
        if case .window(let chosen) = target, chosen.id != expected.windowID {
            stop()
            return .targetLost
        }
        guard let (region, _) = LiveScrollFrames.region(for: target),
            frontmost(Point(x: region.midX, y: region.midY)) == expected.windowID
        else {
            stop()
            return .targetLost
        }
        if scroller == nil {
            let request = generation
            guard let created = await makeScroller(for: target, binding: expected, generation: request) else {
                return .targetLost
            }
            guard generation == request, !Task.isCancelled, binding() == expected,
                frontmost(Point(x: region.midX, y: region.midY)) == expected.windowID
            else {
                created.stop(reason: .requested)
                return .targetLost
            }
            do { try created.start() } catch { return .targetLost }
            scroller = created
            scrollerBinding = expected
        }
        guard let scroller, scrollerBinding == expected else {
            stop()
            return .targetLost
        }
        switch scroller.scrollDown(byPixels: Self.stepPoints) {
        case .scrolled: return .scrolled
        case .notRunning, .stopped: return .targetLost
        }
    }

    func stop() {
        generation = UUID()
        scroller?.stop(reason: .requested)
        scroller = nil
        scrollerBinding = nil
    }

    /// Reads the vertical scroll bar of the scroll area under the capture region's center through
    /// Accessibility (granted for automatic mode). nil when there is none or it cannot be read.
    func isAtEnd(_ target: CaptureTarget) async -> Bool? {
        guard let (region, _) = LiveScrollFrames.region(for: target) else { return nil }
        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(region.midX), Float(region.midY), &hit) == .success,
            var element = hit
        else { return nil }
        for _ in 0..<24 {
            if Self.attribute(kAXRoleAttribute, of: element) as? String == kAXScrollAreaRole as String {
                guard let bar = Self.element(kAXVerticalScrollBarAttribute, of: element),
                    let value = Self.attribute(kAXValueAttribute, of: bar) as? NSNumber
                else { return nil }
                return value.doubleValue >= 0.995
            }
            guard let parent = Self.element(kAXParentAttribute, of: element) else { return nil }
            element = parent
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private func makeScroller(
        for target: CaptureTarget, binding expected: ScrollWindowBinding, generation request: UUID
    ) async -> (any AutoScrollDriving)? {
        guard let (region, display) = LiveScrollFrames.region(for: target) else { return nil }
        let center = Point<DesktopSpace>(x: region.midX, y: region.midY)
        let candidates = (try? await windows()) ?? []
        guard generation == request, !Task.isCancelled, binding() == expected,
            frontmost(center) == expected.windowID,
            let window = candidates.first(where: { $0.id == expected.windowID })
        else { return nil }
        return try? makeDriver(window, display, center)
    }

}
