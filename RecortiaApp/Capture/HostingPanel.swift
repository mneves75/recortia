import AppKit
import SwiftUI

/// A small AppKit panel hosting SwiftUI content, sized to that content.
final class HostingPanel: NSPanel {
    private let allowsKey: Bool
    /// The title bar is transparent and hidden; by default SwiftUI still insets the content by its
    /// height. A panel whose window buttons are absent (the scrolling HUD) sets this to false
    /// before `setContent`, so the content and the panel's size start at the top edge.
    var reservesTitleBarArea = true

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
        if !reservesTitleBarArea { controller.safeAreaRegions = [] }
        if fixedToFittingSize {
            controller.sizingOptions = []
            contentViewController = controller
            setContentSize(NSHostingView(rootView: view).fittingSize)
        } else {
            controller.sizingOptions = [.preferredContentSize]
            contentViewController = controller
        }
    }

    /// Right after `setContent` the tracked size has not arrived and the frame is zero; AppKit
    /// later grows the panel from its top-left corner, so `present` would leave it half its width
    /// right of centre and its top at the bottom edge it computed. Sizing to the content's fitting
    /// size first fixes both; a height that still misses the title-bar inset grows downward.
    func sizeToContentIfUnsized() {
        guard frame.width == 0, let content = contentViewController?.view else { return }
        setContentSize(content.fittingSize)
    }

    /// Sizes an unsized panel to its content and places it near the top center of the screen with
    /// the pointer, without showing it.
    func placeNearTop() {
        sizeToContentIfUnsized()
        guard let visible = ScreenChoice.screen()?.visibleFrame else { return }
        let size = frame.size
        setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - visible.height * 0.18))
    }

    /// Shows the panel near the top center of the screen with the pointer.
    func present(activate: Bool) {
        placeNearTop()
        if activate {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }
}
