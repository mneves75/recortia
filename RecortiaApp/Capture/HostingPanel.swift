import AppKit
import SwiftUI

/// A small AppKit panel hosting SwiftUI content, sized to that content.
final class HostingPanel: NSPanel {
    private let allowsKey: Bool

    /// - Parameter activating: false for HUDs that must not take focus from the app being captured.
    init(title: String, activating: Bool) {
        allowsKey = activating
        var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
        if !activating { style.insert(.nonactivatingPanel) }
        super.init(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { allowsKey }

    func setContent<Content: View>(_ view: Content) {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
    }

    /// Shows the panel near the top center of the screen with the pointer.
    func present(activate: Bool) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = frame.size
            setFrameOrigin(
                CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - visible.height * 0.18))
        }
        if activate {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }
}
