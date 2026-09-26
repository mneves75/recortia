import AppKit
import ApplicationServices
import Domain
import Features
import MacPlatform

/// Adapts MacPlatform's single-use `ScrollFrameSource` to the session protocol: each `start`
/// builds a new bounded stream for the chosen region; frames after `stop()` throw `.canceled`.
final class LiveScrollFrames: ScrollFrameSourceService {
    private var source: ScrollFrameSource?
    private var iterator: AsyncStream<CGImage>.AsyncIterator?

    func start(_ target: CaptureTarget) async throws(CaptureError) {
        stopSynchronously()
        guard let (region, display) = Self.region(for: target) else { throw .targetUnavailable }
        let source = ScrollFrameSource(region: region, display: display)
        self.source = source
        iterator = source.frames.makeAsyncIterator()
        try await source.start()
    }

    func nextFrame() async throws(CaptureError) -> CGImage {
        guard let source, var iterator else { throw .canceled }
        let frame = await iterator.next(isolation: #isolation)
        // A stop and a new start may have run during the await; never overwrite the new iterator.
        if self.source === source { self.iterator = iterator }
        if let frame { return frame }
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
/// the frontmost other-app window under the capture region, and stops on any focus/target change.
final class LiveAutoScroll: AutoScrollService {
    /// Points per step: less than a typical viewport so consecutive frames overlap for matching.
    static let stepPoints = 240

    private let capture: ScreenCaptureService
    private var scroller: AutoScroller?

    init(capture: ScreenCaptureService = ScreenCaptureService()) {
        self.capture = capture
    }

    func step(_ target: CaptureTarget) async -> AutoScrollStep {
        if scroller == nil {
            guard let created = await makeScroller(for: target) else { return .targetLost }
            // The session may have ended while the window list loaded; never keep a scroller then.
            guard !Task.isCancelled else { return .targetLost }
            do { try created.start() } catch { return .targetLost }
            scroller = created
        }
        guard let scroller else { return .targetLost }
        switch scroller.scrollDown(byPixels: Self.stepPoints) {
        case .scrolled: return .scrolled
        case .notRunning, .stopped: return .targetLost
        }
    }

    func stop() {
        scroller?.stop()
        scroller = nil
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

    private func makeScroller(for target: CaptureTarget) async -> AutoScroller? {
        guard let (region, display) = LiveScrollFrames.region(for: target) else { return nil }
        let center = Point<DesktopSpace>(x: region.midX, y: region.midY)
        let window: WindowInfo?
        if case .window(let chosen) = target {
            window = chosen
        } else {
            let candidates = (try? await capture.windows()) ?? []
            window = Self.frontmostWindowID(containing: center).flatMap { id in candidates.first { $0.id == id } }
        }
        guard let window else { return nil }
        return try? AutoScroller(target: window, display: display, scrollPoint: center)
    }

    /// `CGWindowListCopyWindowInfo` documents front-to-back ordering (ScreenCaptureKit does not), and
    /// its bounds use the same top-left global coordinates as desktop space.
    static func frontmostWindowID(containing point: Point<DesktopSpace>) -> CGWindowID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]]
        else { return nil }
        for entry in list {
            guard let layer = entry[kCGWindowLayer] as? Int, layer == 0,
                let pid = entry[kCGWindowOwnerPID] as? pid_t, pid != ownPID,
                let number = entry[kCGWindowNumber] as? CGWindowID,
                let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            if bounds.contains(CGPoint(x: point.x, y: point.y)) { return number }
        }
        return nil
    }
}
