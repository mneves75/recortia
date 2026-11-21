import ApplicationServices
import CoreGraphics
import Domain
import Features
import MacPlatform

/// Interface element frames for region snapping (FR-02, B-7, ADR-010), through Accessibility. It
/// checks the grant and never requests it, and asks the other app for four attributes only:
/// AXPosition, AXSize and AXRole of each element, and AXChildren to walk the tree. The frames go
/// to the capture coordinator for one selection; they are never logged or stored.
final class LiveInterfaceElements: InterfaceElementFrameService {
    func frames(under windows: [WindowInfo]) async -> ElementSnapping.Walk? {
        guard AccessibilityPermission.isTrusted, let pointer = CGEvent(source: nil)?.location,
            let frontmost = ScrollFrameSource.frontmostWindowID(at: Point(x: pointer.x, y: pointer.y)),
            let window = windows.first(where: { $0.id == frontmost })
        else { return nil }
        return await Self.read(pid: window.ownerPID)
    }

    @concurrent
    private static func read(pid: pid_t) async -> ElementSnapping.Walk {
        let clock = ContinuousClock()
        let start = clock.now
        return ElementSnapping.walk(from: AXElementNode(AXUIElementCreateApplication(pid))) { clock.now - start }
    }
}

/// One element of the other app. Attribute names are spelled out so a reader can check that no
/// text attribute (AXValue, AXTitle, AXDescription, AXHelp…) is ever asked for.
nonisolated private struct AXElementNode: InterfaceElementNode {
    /// The longest one message to the other app may block; the walk's deadline bounds the total.
    static let messagingTimeout: Float = 0.05

    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
        // The timeout belongs to each element reference, not to the application it came from.
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
    }

    func read() -> InterfaceElementReading? {
        var values: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(
                element, ["AXPosition", "AXSize", "AXRole"] as CFArray, AXCopyMultipleAttributeOptions(), &values)
                == .success,
            let list = values as? [AnyObject], list.count == 3
        else { return nil }
        let role = list[2] as? String
        let kind: InterfaceElementKind = role == "AXApplication" || role == "AXWindow" ? .container : .element
        guard let origin = Self.point(list[0]), let size = Self.size(list[1]) else {
            return InterfaceElementReading(frame: nil, kind: kind)
        }
        return InterfaceElementReading(
            frame: Rect(x: origin.x, y: origin.y, width: size.width, height: size.height), kind: kind)
    }

    func children(limit: Int) -> [AXElementNode] {
        var values: CFArray?
        guard limit > 0,
            AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, limit, &values) == .success,
            let list = values as? [AnyObject]
        else { return [] }
        return list.compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return AXElementNode(unsafeDowncast(child, to: AXUIElement.self))
        }
    }

    /// A failed attribute in a multiple-attribute read comes back as an AXValue of error type.
    private static func axValue(_ object: AnyObject, _ type: AXValueType) -> AXValue? {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(object, to: AXValue.self)
        return AXValueGetType(value) == type ? value : nil
    }

    private static func point(_ object: AnyObject) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(object, .cgPoint), AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ object: AnyObject) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(object, .cgSize), AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
