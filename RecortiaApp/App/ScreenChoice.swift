import AppKit

/// Picks the screen a Recortia window appears on (FR-01): the display a capture came from when it
/// is still connected, else the screen under the pointer, else the first screen. Never the key
/// window's screen (`NSScreen.main`), which can be another display than the one the user is on.
enum ScreenChoice {
    static func pick<Screen>(
        _ screens: [Screen], displayID: CGDirectDisplayID?, pointer: CGPoint, id: (Screen) -> CGDirectDisplayID?,
        frame: (Screen) -> CGRect
    ) -> Screen? {
        if let displayID, let match = screens.first(where: { id($0) == displayID }) { return match }
        return screens.first { frame($0).contains(pointer) } ?? screens.first
    }

    /// The live screen for `displayID`, or the pointer's screen.
    static func screen(displayID: CGDirectDisplayID? = nil) -> NSScreen? {
        pick(NSScreen.screens, displayID: displayID, pointer: NSEvent.mouseLocation, id: \.displayID, frame: \.frame)
    }
}

extension NSWindow {
    /// Centers the window in `screen`'s visible frame; `center()` would use the key window's screen.
    func center(on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return center() }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }
}

extension NSScreen {
    /// The Core Graphics display this screen shows.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
