import AppKit

/// Recortia is a menu-bar app (`LSUIElement`) that joins ⌘Tab and the Dock while it has a window
/// the user can switch to, and leaves them when the last one closes (FR-01, ADR-007).
///
/// Activation policy is process-wide, so there is one instance. Promotion is immediate: presenting
/// code calls `activate()`, which becomes regular before activating, because a switch after
/// activation leaves the previous app's menu in the menu bar. Demotion is coalesced to a later
/// main-actor turn, so one window replacing another never drops the Dock icon.
///
/// The same coalesced turn reports that the person closed the last switchable window
/// (`onLastWindowClosed`). Only a real close counts: launching without a window, minimizing,
/// hiding, a capture that orders windows out, and closing a capture panel never do.
@MainActor
final class AppPresence {
    static let shared = AppPresence()

    /// How many times the app returned to accessory; lets E2E prove a replacement did not demote.
    private(set) var demotions = 0
    /// Called when a closed switchable window left none, nothing holds the app, and it is not hidden.
    var onLastWindowClosed: (@MainActor () -> Void)?
    /// Active reasons to keep the app regular without a visible window (capture suspension).
    private var holds = 0
    private var refreshScheduled = false
    /// A switchable window closed since the last refresh.
    private var closedSwitchableWindow = false
    private var observers: [any NSObjectProtocol] = []

    private init() {}

    /// Starts following window changes. Idempotent; the observers live as long as the process.
    func start() {
        guard observers.isEmpty else { return }
        let names = [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification, NSApplication.didUnhideNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { AppPresence.shared.setNeedsRefresh() }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
                notification in
                // Still ordered in while it closes, so a switchable window is recognized here.
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { AppPresence.shared.windowWillClose(window) }
            })
    }

    private func windowWillClose(_ window: NSWindow?) {
        if let window, Self.isSwitchable(window) { closedSwitchableWindow = true }
        setNeedsRefresh()
    }

    /// Becomes regular, then activates: for code about to show a switchable window.
    func activate() {
        windowWillAppear()
        NSApp.activate()
    }

    /// Becomes regular now, for a switchable window about to be ordered in.
    func windowWillAppear() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// Re-evaluates on a later main-actor turn, after the window change in progress completes.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            refreshScheduled = false
            refresh()
        }
    }

    /// Capture temporarily orders Recortia's windows out; they still exist for the user.
    func beginHold() {
        holds += 1
    }

    func endHold() {
        holds = max(0, holds - 1)
        setNeedsRefresh()
    }

    /// The most recent minimized switchable window, restored by a Dock click.
    var minimizedWindow: NSWindow? {
        NSApp.windows.last { Self.isSwitchable($0) && $0.isMiniaturized }
    }

    /// A window the person can still return to: one shown or minimized, one a capture ordered out
    /// (a hold), or any while Recortia is hidden.
    var hasUserWindow: Bool {
        holds > 0 || NSApp.isHidden || NSApp.windows.contains(where: Self.isSwitchable)
    }

    private func refresh() {
        // A close is reported in the turn that sees it or never: a capture holding the app then
        // means the person is still working, and cancelling that capture must not quit.
        let closed = closedSwitchableWindow
        closedSwitchableWindow = false
        if NSApp.windows.contains(where: Self.isSwitchable) {
            windowWillAppear()
            return
        }
        guard holds == 0, !NSApp.isHidden else { return }
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
            demotions += 1
        }
        if closed { onLastWindowClosed?() }
    }

    /// A top-level window at the normal or modal level that is shown or minimized: the editor,
    /// Settings, onboarding, scrolling review, About, alerts, open panels, and pins. Capture panels,
    /// HUDs, the drag chip, menus, and status items sit at higher levels and never count.
    static func isSwitchable(_ window: NSWindow) -> Bool {
        window.parent == nil && window.sheetParent == nil
            && (window.level == .normal || window.level == .modalPanel)
            && (window.isVisible || window.isMiniaturized)
    }
}
