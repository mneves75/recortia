#if DEBUG
    import AppKit
    import ApplicationServices

    @MainActor
    enum E2EAccessibilityControl {
        enum TextAttribute: String {
            case value = "accessibilityValue"
            case help = "accessibilityHelp"
        }

        static func text(
            _ attribute: TextAttribute, for identifier: String, in root: NSView,
            _ context: ScenarioContext
        ) throws -> String {
            let control = try control(identifier, in: root, context)
            try context.require(
                "\(identifier) exposes \(attribute.rawValue)",
                control.responds(to: NSSelectorFromString(attribute.rawValue)))
            return try context.unwrap(
                "\(identifier) \(attribute.rawValue)",
                control.value(forKey: attribute.rawValue) as? String)
        }

        static func press(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws {
            let control = try control(identifier, in: root, context)
            if let modern = control as? any NSAccessibilityProtocol, modern.accessibilityPerformPress() { return }
            // A SwiftUI node may decline Press (a grouped-form switch row does); the scenario's own
            // outcome checks still decide whether the fallback below worked.
            E2ERunner.log("\(identifier): \(type(of: control)) declined Press; pressing its frame")
            try pressFrame(control, in: root, context)
        }

        /// Presents only the scenario's synthetic window through the ordinary-window activation path.
        static func showAndActivate(_ window: NSWindow, _ context: ScenarioContext) async throws {
            AppPresence.shared.windowWillAppear()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try context.require(
                "the synthetic control window is visible, key and foreground",
                await E2EWait.until { isReadyForInput(window) },
                "visible=\(window.isVisible), key=\(window.isKeyWindow), active=\(NSApp.isActive), "
                    + "foregroundPID=\(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier))")
        }

        /// Whether an element with `identifier` is in the hosted hierarchy now (records no check).
        static func isPresent(_ identifier: String, in root: NSView) -> Bool {
            var visited: Set<ObjectIdentifier> = []
            var remaining = 4096
            return find(identifier, in: root, visited: &visited, remaining: &remaining, depth: 0) != nil
        }

        /// The control's accessibility frame, in screen coordinates.
        static func frame(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws -> NSRect {
            let control = try control(identifier, in: root, context)
            let value = try context.unwrap(
                "\(identifier) frame", control.value(forKey: "accessibilityFrame") as? NSValue)
            return value.rectValue
        }

        static func isEnabled(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws -> Bool {
            let control = try control(identifier, in: root, context)
            try context.require(
                "\(identifier) exposes enabled state",
                control.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
                    || control.responds(to: NSSelectorFromString("accessibilityEnabled")))
            return try context.unwrap(
                "\(identifier) enabled state", control.value(forKey: "accessibilityEnabled") as? Bool)
        }

        /// Uses only this synthetic window's field editor and Return event, never global input.
        static func enterNumber(_ identifier: String, text: String, in root: NSView, _ context: ScenarioContext)
            async throws
        {
            let element = try control(identifier, in: root, context)
            let window = try context.unwrap("numeric field window", root.window)
            let focusBefore = element.value(forKey: "accessibilityFocused") as? Bool
            try context.require("\(identifier) is enabled for input", try isEnabled(identifier, in: root, context))
            if let modern = element as? any NSAccessibilityProtocol {
                modern.setAccessibilityFocused(true)
            } else {
                try pressFrame(element, in: root, context)
            }
            try context.require(
                "\(identifier) owns a native field editor",
                await E2EWait.until {
                    (element.value(forKey: "accessibilityFocused") as? Bool) == true
                        && (window.firstResponder as? NSTextView)?.isFieldEditor == true
                })
            let editor = try context.unwrap("native numeric field editor", window.firstResponder as? NSTextView)
            E2ERunner.log(
                "number field \(identifier): focusedBefore=\(String(describing: focusBefore)); focusedAfterRequest=\(String(describing: element.value(forKey: "accessibilityFocused") as? Bool)); previousText=\(editor.string)"
            )
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            try context.require("native number insertion reaches the field editor", editor.string == text)
            let event = try context.unwrap(
                "numeric Return event",
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
            window.sendEvent(event)
        }

        private static func control(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws
            -> NSObject
        {
            // SwiftUI creates its AX nodes lazily. Query only this synthetic runner's application;
            // this does not prompt, change permissions, or inspect another process's UI.
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            var windows: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
            try context.require(
                "synthetic runner AX query succeeds", result == .success, "AX status \(result.rawValue)")
            var visited: Set<ObjectIdentifier> = []
            var remaining = 4096
            return try context.unwrap(
                "\(identifier) is accessible",
                find(identifier, in: root, visited: &visited, remaining: &remaining, depth: 0))
        }

        private static func pressFrame(_ control: NSObject, in root: NSView, _ context: ScenarioContext) throws {
            let window = try context.unwrap("control has a window", root.window)
            try context.require("the native event target is visible, key and foreground", isReadyForInput(window))
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
            let topView = window.contentView?.superview ?? window.contentView
            let hit = try context.unwrap("a view under the control's centre", topView?.hitTest(point))
            try context.require("the view under the control's centre is inside the pane", hit.isDescendant(of: root))
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try context.unwrap(
                    "control mouse event",
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            // Queue the mouse-up in this app's own event queue first: an AppKit control tracks a
            // mouse-down on the main thread until a mouse-up arrives.
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            window.sendEvent(try event(.leftMouseDown))
        }

        private static func isReadyForInput(_ window: NSWindow) -> Bool {
            window.isVisible && window.isKeyWindow && NSApp.isActive
                && NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == ProcessInfo.processInfo.processIdentifier
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
