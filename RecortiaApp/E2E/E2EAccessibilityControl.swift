#if DEBUG
    import AppKit

    @MainActor
    enum E2EAccessibilityControl {
        static func press(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws {
            var visited: Set<ObjectIdentifier> = []
            var remaining = 4096
            let control = try context.unwrap(
                "\(identifier) is accessible",
                find(identifier, in: root, visited: &visited, remaining: &remaining, depth: 0))
            if let modern = control as? any NSAccessibilityProtocol {
                try context.require("\(identifier) responds to Press", modern.accessibilityPerformPress())
                return
            }
            let window = try context.unwrap("control has a window", root.window)
            try context.require(
                "control exposes its frame", control.responds(to: NSSelectorFromString("accessibilityFrame")))
            let value = try context.unwrap(
                "control frame", control.value(forKey: "accessibilityFrame") as? NSValue)
            let frame = value.rectValue
            try context.require(
                "control frame is finite and nonempty",
                frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
                    && frame.width > 0 && frame.height > 0)
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try context.unwrap(
                    "control mouse event",
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }

        private static func find(
            _ identifier: String, in element: Any, visited: inout Set<ObjectIdentifier>, remaining: inout Int,
            depth: Int
        ) -> NSObject? {
            guard depth < 64, remaining > 0, let object = element as? NSObject,
                visited.insert(ObjectIdentifier(object)).inserted
            else { return nil }
            remaining -= 1
            if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                object.value(forKey: "accessibilityIdentifier") as? String == identifier
            {
                return object
            }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                let children = object.value(forKey: "accessibilityChildren") as? [Any]
            {
                for child in children {
                    if let match = find(
                        identifier, in: child, visited: &visited, remaining: &remaining, depth: depth + 1)
                    {
                        return match
                    }
                }
            }
            if let view = element as? NSView {
                for child in view.subviews {
                    if let match = find(
                        identifier, in: child, visited: &visited, remaining: &remaining, depth: depth + 1)
                    {
                        return match
                    }
                }
            }
            return nil
        }
    }
#endif
