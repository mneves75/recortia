import AppKit
import SwiftUI

/// A small AppKit panel hosting SwiftUI content, sized to that content.
final class HostingPanel: NSPanel {
    private let allowsKey: Bool

    /// - Parameters:
    ///   - activating: false for HUDs that must not take focus from the app being captured.
    ///   - keyOnClick: lets a non-activating HUD become key when the user clicks it, without
    ///     activating Recortia or changing the frontmost app, so its keyboard shortcuts (Escape
    ///     for Cancel) work then. It never becomes key by being shown.
    init(title: String, activating: Bool, keyOnClick: Bool = false) {
        allowsKey = activating || keyOnClick
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
        collectionBehavior = SpacePolicy.joinsAllSpaces
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { allowsKey }

    /// - Parameter fixedToFittingSize: sizes the panel once to the content's fitting size instead
    ///   of tracking it. Content without a fixed width (the countdown) makes size tracking loop
    ///   through constraint passes until AppKit throws, so such content must use this.
    func setContent<Content: View>(_ view: Content, fixedToFittingSize: Bool = false) {
        let controller = NSHostingController(rootView: view)
        if fixedToFittingSize {
            controller.sizingOptions = []
            contentViewController = controller
            setContentSize(NSHostingView(rootView: view).fittingSize)
        } else {
            controller.sizingOptions = [.preferredContentSize]
            contentViewController = controller
        }
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
