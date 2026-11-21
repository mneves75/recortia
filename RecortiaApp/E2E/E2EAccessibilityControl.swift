#if DEBUG
    import AppKit
    import ApplicationServices
    import Domain

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
                control.value(forKey: attribute.rawValue) as? String,
                "\(type(of: control)) returned \(String(describing: control.value(forKey: attribute.rawValue)))")
        }

        /// The name an assistive app reads for the element: its label, description or title, plain or
        /// attributed. A bridged SwiftUI menu button exposes its Label text only as an attributed title.
        static func name(for identifier: String, in root: NSView, _ context: ScenarioContext) throws -> String {
            let control = try control(identifier, in: root, context)
            func plain(_ value: Any?) -> String? {
                switch value {
                case let text as String: text
                case let text as NSAttributedString: text.string
                default: nil
                }
            }
            let candidates: [Any?] = [
                control.responds(to: NSSelectorFromString("accessibilityLabel"))
                    ? control.value(forKey: "accessibilityLabel") : nil,
                control.accessibilityAttributeValue(.description),
                control.responds(to: NSSelectorFromString("accessibilityTitle"))
                    ? control.value(forKey: "accessibilityTitle") : nil,
                control.accessibilityAttributeValue(.title),
            ]
            return try context.unwrap(
                "\(identifier) has an accessible name", candidates.compactMap(plain).first { !$0.isEmpty },
                "\(type(of: control)) candidates \(candidates.map { String(describing: $0) })")
        }

        /// The help an assistive app reads for the element: its own help, or, for a SwiftUI node inside
        /// a bridged toolbar item, the help of that toolbar item's element.
        static func help(for identifier: String, in root: NSView, _ context: ScenarioContext) throws -> String {
            let control = try control(identifier, in: root, context)
            func own(_ object: NSObject?) -> [Any?] {
                guard let object else { return [] }
                return [
                    object.responds(to: NSSelectorFromString("accessibilityHelp"))
                        ? object.value(forKey: "accessibilityHelp") : nil,
                    object.accessibilityAttributeValue(.help),
                ]
            }
            let parent = control.value(forKey: "accessibilityParent") as? NSObject
            let candidates = own(control) + own(parent)
            return try context.unwrap(
                "\(identifier) has help", candidates.compactMap { $0 as? String }.first { !$0.isEmpty },
                "\(type(of: control)) / \(String(describing: parent.map { type(of: $0) })) candidates "
                    + "\(candidates.map { String(describing: $0) })")
        }

        static func press(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws {
            let control = try control(identifier, in: root, context)
            if let modern = control as? any NSAccessibilityProtocol {
                try context.require("\(identifier) responds to Press", modern.accessibilityPerformPress())
                return
            }
            try pressFrame(control, in: root, context)
        }

        /// Presses a SwiftUI control as an assistive app does, for controls (bridged toolbar items,
        /// switches, menu buttons) that perform the press yet report false: the legacy AXPress when the
        /// element lists it (the path `AXUIElementPerformAction` reaches), else the element's own
        /// `accessibilityPerformPress`. The caller verifies the effect instead of that flag.
        static func pressCheckingEffect(_ identifier: String, in root: NSView, _ context: ScenarioContext) throws {
            let control = try control(identifier, in: root, context)
            if control.accessibilityActionNames().contains(.press) {
                control.accessibilityPerformAction(.press)
                return
            }
            let press = NSSelectorFromString("accessibilityPerformPress")
            try context.require(
                "\(identifier) offers Press", control.responds(to: press),
                "\(type(of: control)) actions \(control.accessibilityActionNames().map(\.rawValue))")
            _ = control.perform(press)
        }

        /// Presses a menu button through accessibility, as a person or VoiceOver opens it (or, with
        /// `byRightClick`, opens a context menu with a secondary click), and while the real menu
        /// tracks: records its items, chooses the item titled `title` (or nothing), and ends tracking. A common-mode timer ends tracking after two seconds so a menu that never
        /// matches cannot block the run.
        static func chooseFromMenu(
            _ title: String?, opening identifier: String, in root: NSView, _ context: ScenarioContext,
            byRightClick: Bool = false
        ) async throws -> [E2EMenuEntry] {
            let session = E2EMenuSession(choosing: title)
            NotificationCenter.default.addObserver(
                session, selector: #selector(E2EMenuSession.began(_:)), name: NSMenu.didBeginTrackingNotification,
                object: nil)
            defer { NotificationCenter.default.removeObserver(session) }
            let safety = Timer(timeInterval: 2, repeats: false) { [weak session] _ in
                MainActor.assumeIsolated { session?.menu?.cancelTrackingWithoutAnimation() }
            }
            RunLoop.main.add(safety, forMode: .common)
            defer { safety.invalidate() }
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let active = NSApp.isActive
            if byRightClick {
                // A context menu opens from the pointer: a secondary click on the control's frame.
                try pressFrame(try control(identifier, in: root, context), in: root, context, secondary: true)
            } else {
                try pressCheckingEffect(identifier, in: root, context)
            }
            try context.require(
                "\(identifier) opens its menu", await E2EWait.until(timeout: .seconds(3)) { session.tracked })
            _ = await E2EWait.until(timeout: .seconds(3)) { session.menu == nil || !session.isOpen }
            context.check(
                "\(identifier) menu leaves the foreground app and activation unchanged",
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && NSApp.isActive == active,
                "foreground \(String(describing: foreground)) -> "
                    + "\(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier)), "
                    + "active \(active) -> \(NSApp.isActive)")
            if let title {
                try context.require("\(identifier) offers \(title)", session.chosen, "items \(session.entries)")
            }
            return session.entries
        }

        /// Clicks a control of a pane, such as the selected Settings pane or the editor's inspector,
        /// like a pointer would: one mouse-down then
        /// one mouse-up, posted in that order to this application's own event queue, so the normal
        /// app event loop dispatches the down and then the up in FIFO order, as Apple's public
        /// event-handling docs describe. This proves pointer delivery, not VoiceOver or
        /// accessibility Press. No global event, tap or other process is involved. The caller's
        /// next settle runs the event loop that delivers both events.
        static func click(_ identifier: String, in pane: NSView, _ context: ScenarioContext) throws {
            try click(try control(identifier, in: pane, context), named: identifier, in: pane, context)
        }

        /// `click(_:in:_:)` for an element found another way.
        static func click(_ control: NSObject, named identifier: String, in pane: NSView, _ context: ScenarioContext)
            throws
        {
            let window = try context.unwrap("the pane under \(identifier) has a window", pane.window)
            try context.require(
                "the window under \(identifier) is visible, key and foreground", isReadyForInput(window),
                "visible=\(window.isVisible), key=\(window.isKeyWindow), active=\(NSApp.isActive), "
                    + "foregroundPID=\(String(describing: NSWorkspace.shared.frontmostApplication?.processIdentifier))")
            try context.require(
                "\(identifier) exposes its frame", control.responds(to: NSSelectorFromString("accessibilityFrame")))
            let frame = try context.unwrap(
                "\(identifier) frame", control.value(forKey: "accessibilityFrame") as? NSValue
            ).rectValue
            try context.require(
                "\(identifier) frame is finite and nonempty",
                frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
                    && frame.width > 0 && frame.height > 0, "\(frame)")
            let paneFrame = window.convertToScreen(pane.convert(pane.bounds, to: nil))
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            try context.require(
                "\(identifier) centre lies inside the selected pane", paneFrame.contains(centre),
                "control \(frame), pane \(paneFrame)")
            let point = window.convertPoint(fromScreen: centre)
            let topView = window.contentView?.superview ?? window.contentView
            let hit = try context.unwrap("a view under \(identifier) centre", topView?.hitTest(point))
            try context.require(
                "the view under \(identifier) centre is inside the selected pane", hit.isDescendant(of: pane),
                "\(type(of: hit))")
            if let view = control as? NSView {
                try context.require(
                    "the view under \(identifier) centre is that control", hit.isDescendant(of: view),
                    "hit \(type(of: hit)), control \(type(of: view))")
            }

            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try context.unwrap(
                    "\(identifier) mouse event",
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            let down = try event(.leftMouseDown)
            let up = try event(.leftMouseUp)
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
            E2ERunner.log(
                "click \(identifier): \(type(of: control)) at \(point) in window \(window.windowNumber); "
                    + "hit \(type(of: hit))")
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
        /// Chooses the inspector's text Font and Style as a person does: the Font pop-up through
        /// accessibility Press and its real menu, then the Style segment through the segmented
        /// control's own selection and action (as `InspectorScenarios.chooseTab` does).
        static func chooseTextAppearance(
            _ appearance: TextAppearance, in root: NSView, _ context: ScenarioContext
        ) async throws {
            let (font, style) = textChoices(appearance)
            let entries = try await chooseFromMenu(fontTitles[font], opening: "text.font", in: root, context)
            checkFontMenu(entries, context)
            await E2ESnapshot.settle(root)
            let segmented = try context.unwrap(
                "the inspector has the text Style control", textStyleControl(in: root))
            segmented.setSelected(true, forSegment: style)
            try context.require(
                "the Style control sends its action", segmented.sendAction(segmented.action, to: segmented.target))
        }

        /// The text Font and Style the inspector shows, as one appearance: the Font menu's checked
        /// item and the selected Style segment.
        static func shownTextAppearance(in root: NSView, _ context: ScenarioContext) async throws -> TextAppearance? {
            let entries = try await chooseFromMenu(nil, opening: "text.font", in: root, context)
            checkFontMenu(entries, context)
            guard let style = textStyleControl(in: root)?.selectedSegment,
                let checked = entries.first(where: \.checked), let font = fontTitles.firstIndex(of: checked.title)
            else { return nil }
            return TextAppearance.allCases.first { textChoices($0) == (font, style) }
        }

        /// The Font menu lists exactly System, Rounded and Monospaced, in that order, with one checked.
        private static func checkFontMenu(_ entries: [E2EMenuEntry], _ context: ScenarioContext) {
            context.check(
                "the Font menu lists System, Rounded and Monospaced in order", entries.map(\.title) == fontTitles,
                "\(entries.map(\.title))")
            context.check(
                "the Font menu checks exactly one font", entries.filter(\.checked).count == 1, "\(entries)")
        }

        private static var fontTitles: [String] {
            [
                String(localized: "System", table: "Editor"), String(localized: "Rounded", table: "Editor"),
                String(localized: "Monospaced", table: "Editor"),
            ]
        }

        private static func textChoices(_ appearance: TextAppearance) -> (font: Int, style: Int) {
            switch appearance {
            case .standard: (0, 0)
            case .outlined: (0, 1)
            case .boxed: (0, 2)
            case .rounded: (1, 0)
            case .roundedBoxed: (1, 2)
            case .monospaced: (2, 0)
            case .monospacedBoxed: (2, 2)
            }
        }

        private static func textStyleControl(in root: NSView) -> NSSegmentedControl? {
            let styles = [
                String(localized: "Plain", table: "Editor"), String(localized: "Outline", table: "Editor"),
                String(localized: "Box", table: "Editor"),
            ]
            return EditorWindowController.all(NSSegmentedControl.self, in: root).first { control in
                control.segmentCount == styles.count
                    && (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" } == styles
            }
        }

        /// Opens or closes a disclosure header (a button whose accessibility value says Expanded or
        /// Collapsed) as people do: opening clicks it with the pointer, closing presses it through
        /// accessibility, as VoiceOver does. Requires the reported state to follow.
        static func setDisclosure(
            _ identifier: String, titled title: String, expanded: Bool, in pane: NSView, _ context: ScenarioContext
        ) async throws {
            let window = try context.unwrap("the pane under \(identifier) has a window", pane.window)
            try await showAndActivate(window, context)
            await E2ESnapshot.settle(pane)
            guard try disclosureIsExpanded(identifier, titled: title, in: pane, context) != expanded else { return }
            if expanded {
                try click(identifier, in: pane, context)
            } else {
                try pressCheckingEffect(identifier, in: pane, context)
            }
            try context.require(
                "\(identifier) \(expanded ? "opens by a click" : "closes by Press")",
                await E2EWait.until { headerValue(identifier, in: pane) == stateName(expanded) },
                "value now \(String(describing: headerValue(identifier, in: pane)))")
        }

        /// Whether the disclosure header titled `title` reports itself expanded (it must report
        /// Expanded or Collapsed, nothing else).
        static func disclosureIsExpanded(
            _ identifier: String, titled title: String, in root: NSView, _ context: ScenarioContext
        ) throws -> Bool {
            let header = try control(identifier, in: root, context)
            let label =
                header.responds(to: NSSelectorFromString("accessibilityLabel"))
                ? header.value(forKey: "accessibilityLabel") as? String : nil
            try context.require(
                "\(identifier) is titled \(title)", label == title, "label \(String(describing: label))")
            let value = headerValue(identifier, in: root)
            try context.require(
                "\(identifier) reports Expanded or Collapsed",
                value == stateName(true) || value == stateName(false), "value \(String(describing: value))")
            return value == stateName(true)
        }

        private static func stateName(_ expanded: Bool) -> String {
            expanded ? String(localized: "Expanded", table: "Editor") : String(localized: "Collapsed", table: "Editor")
        }

        private static func headerValue(_ identifier: String, in root: NSView) -> String? {
            guard let header = element(identifier, in: root),
                header.responds(to: NSSelectorFromString("accessibilityValue"))
            else { return nil }
            return header.value(forKey: "accessibilityValue") as? String
        }

        /// The element with `identifier` under `root`, recording nothing.
        private static func element(_ identifier: String, in root: NSView) -> NSObject? {
            var visited: Set<ObjectIdentifier> = []
            var remaining = 4096
            return find(identifier, in: root, visited: &visited, remaining: &remaining, depth: 0)
        }

        /// Performs a control's named accessibility action, as VoiceOver's actions rotor does.
        static func performCustomAction(
            _ name: String, on identifier: String, in root: NSView, _ context: ScenarioContext
        ) throws {
            let control = try control(identifier, in: root, context)
            let actions =
                control.responds(to: NSSelectorFromString("accessibilityCustomActions"))
                ? (control.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []) : []
            let action = try context.unwrap(
                "\(identifier) offers the \(name) action", actions.first { $0.name == name },
                "custom actions \(actions.map(\.name)), actions \(control.accessibilityActionNames().map(\.rawValue))")
            if let handler = action.handler {
                try context.require("\(name) is handled", handler())
            } else {
                let target = try context.unwrap("\(name) has a target", action.target as? NSObject)
                let selector = try context.unwrap("\(name) has a selector", action.selector)
                _ = target.perform(selector, with: action)
            }
        }

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

        private static func pressFrame(
            _ control: NSObject, in root: NSView, _ context: ScenarioContext, secondary: Bool = false
        ) throws {
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
            // A context menu opens on the secondary mouse-down and its tracking consumes the
            // mouse-up; a separate up after tracking would reach the control as a click.
            let types: [NSEvent.EventType] = secondary ? [.rightMouseDown] : [.leftMouseDown, .leftMouseUp]
            for type in types {
                let event = try context.unwrap(
                    "control mouse event",
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
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
    struct E2EMenuEntry: CustomStringConvertible {
        let title: String
        let checked: Bool
        var description: String { "\(title)\(checked ? " ✓" : "")" }
    }

    /// Observes the menu the next press opens; the notification arrives on the main thread,
    /// inside the menu's tracking loop.
    @MainActor
    private final class E2EMenuSession: NSObject {
        let title: String?
        private(set) weak var menu: NSMenu?
        private(set) var entries: [E2EMenuEntry] = []
        private(set) var tracked = false
        private(set) var chosen = false
        private(set) var isOpen = false

        init(choosing title: String?) { self.title = title }

        @objc func ended(_ note: Notification) {
            if note.object as? NSMenu === menu { isOpen = false }
        }

        @objc func began(_ note: Notification) {
            guard let menu = note.object as? NSMenu, !tracked else { return }
            tracked = true
            isOpen = true
            self.menu = menu
            NotificationCenter.default.addObserver(
                self, selector: #selector(ended(_:)), name: NSMenu.didEndTrackingNotification, object: menu)
            menu.update()
            entries = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
                .map { E2EMenuEntry(title: $0.title, checked: $0.state == .on) }
            // Only an item a person could choose: visible and enabled, never a hidden alternate.
            let index = title.flatMap { title in
                menu.items.firstIndex { $0.title == title && !$0.isHidden && $0.isEnabled }
            }
            chosen = index != nil
            // Choose on the next turn of the tracking loop, after the menu finished opening, as a
            // person's click would; a menu chosen inside the notification did not open again.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let index { menu.performActionForItem(at: index) }
                    menu.cancelTracking()
                }
            }
        }
    }
#endif
