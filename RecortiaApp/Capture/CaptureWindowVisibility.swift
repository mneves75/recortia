import AppKit
import Features

/// Temporarily removes the app's existing windows before a capture command runs. Selection
/// panels created afterwards stay usable; documents and previously hidden windows are untouched.
@MainActor
final class CaptureWindowVisibility: NSObject {
    private struct SuspendedWindow {
        weak var window: NSWindow?
    }

    private let capture: CaptureCoordinator
    private let scroll: ScrollSessionModel
    private let isStartingScroll: @MainActor @Sendable () -> Bool
    private var suspended: [SuspendedWindow]?
    private var loop: ObservationLoop?

    init(
        capture: CaptureCoordinator, scroll: ScrollSessionModel,
        isStartingScroll: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.capture = capture
        self.scroll = scroll
        self.isStartingScroll = isStartingScroll
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        loop = ObservationLoop { [weak self] in self?.restoreIfFinished() }
    }

    func suspend() {
        // A replacement selection must retain the original snapshot, not the capture UI.
        guard suspended == nil else { return }
        // Hiding a parent also hides its children/sheet. Ordering a child out separately would
        // detach it from its parent, breaking sheet and auxiliary-panel ownership on restore.
        // Windows on other Spaces cannot appear in this capture; ordering them back in would move
        // windows that follow the active Space onto this one (FR-01).
        let windows = NSApp.orderedWindows.filter {
            $0.isVisible && $0.isOnActiveSpace && !$0.isMiniaturized && $0.parent == nil && $0.sheetParent == nil
        }
        suspended = windows.map { SuspendedWindow(window: $0) }
        // The hidden windows still exist for the user: Recortia stays in ⌘Tab and the Dock.
        AppPresence.shared.beginHold()
        for window in windows { window.orderOut(nil) }
    }

    func restoreIfFinished() {
        // Read both observable states even before there is a snapshot, so the loop stays armed.
        let stillCapturing = capture.state.isActive
        let startingScroll = isStartingScroll()
        let scrolling: Bool
        switch scroll.state {
        case .selecting, .armed, .collecting, .paused: scrolling = true
        default: scrolling = false
        }
        guard !stillCapturing, !scrolling, !startingScroll, let windows = suspended else { return }
        suspended = nil
        defer { AppPresence.shared.endHold() }
        // Back ordering preserves the prior relative order and never replaces the new editor's
        // key/main window, activates the app, or takes focus from the user's target application.
        for entry in windows {
            guard let window = entry.window, !window.isVisible, !window.isMiniaturized else { continue }
            window.orderBack(nil)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        suspended?.removeAll { $0.window == nil || $0.window === window }
    }
}
