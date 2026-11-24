import AppKit
import Observation

/// Recortia is a menu-bar app (`LSUIElement`) that joins ⌘Tab and the Dock while it has a window
/// the user can switch to, and leaves them when the last one closes (FR-01, ADR-007).
///
/// Activation policy is process-wide, so there is one instance. Promotion is immediate: an ordinary
/// window is shown through `present(_:)`, and other presenting code calls `activate()`; both become
/// regular before activating, because a switch after activation leaves the previous app's menu in
/// the menu bar. Demotion is coalesced to a later
/// main-actor turn, so one window replacing another never drops the Dock icon.
///
/// The same coalesced turn reports that the person closed the last switchable window
/// (`onLastWindowClosed`). Only a real close counts: launching without a window, minimizing,
/// hiding, a capture that orders windows out, and closing a capture panel never do.
@MainActor
@Observable
final class AppPresence {
    static let shared = AppPresence()

    #if DEBUG
        /// How many times the app returned to accessory; lets E2E prove a replacement did not demote.
        @ObservationIgnored private(set) var demotions = 0
    #endif
    /// Called when a closed switchable window left none, nothing holds the app, and it is not hidden.
    @ObservationIgnored var onLastWindowClosed: (@MainActor () -> Void)?
    /// Active reasons to keep the app regular without a visible window (capture suspension).
    private var holds = 0
    /// Observed mirror of `liveHasUserWindow` so `withObservationTracking` wakes on window/hide changes.
    private var trackedHasUserWindow = false
    @ObservationIgnored private var refreshScheduled = false
    /// A switchable window closed since the last refresh.
    @ObservationIgnored private var closedSwitchableWindow = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

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
                    MainActor.assumeIsolated {
                        AppPresence.shared.syncObservedPresence()
                        AppPresence.shared.setNeedsRefresh()
                    }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didHideNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { AppPresence.shared.syncObservedPresence() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
                notification in
                // Still ordered in while it closes, so a switchable window is recognized here.
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated { AppPresence.shared.windowWillClose(window) }
            })
        syncObservedPresence()
    }

    private func windowWillClose(_ window: NSWindow?) {
        if let window, Self.isSwitchable(window) { closedSwitchableWindow = true }
        setNeedsRefresh()
    }

    /// Shows an ordinary window (editor, Settings, onboarding, scrolling review): regular first, then
    /// the Space policy, then order and activate, so the window moves to the person instead of macOS
    /// switching to the Space where it was last shown (FR-01).
    func present(_ window: NSWindow) {
        windowWillAppear()
        SpacePolicy.follow(window)
        window.makeKeyAndOrderFront(nil)
        syncObservedPresence()
        NSApp.activate()
    }

    /// Becomes regular, then activates: for code about to show a switchable window it does not
    /// order itself (alerts, About, open panels, pins).
    func activate() {
        windowWillAppear()
        NSApp.activate()
    }

    /// Becomes regular now, for a switchable window about to be ordered in.
    func windowWillAppear() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        syncObservedPresence()
    }

    /// Synchronizes observed presence right after a switchable window is ordered in without
    /// becoming key (for example, a non-activating pin).
    func windowDidAppear() {
        syncObservedPresence()
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
        syncObservedPresence()
    }

    func endHold() {
        holds = max(0, holds - 1)
        syncObservedPresence()
        setNeedsRefresh()
    }

    /// The most recent minimized switchable window, restored by a Dock click.
    var minimizedWindow: NSWindow? {
        NSApp.windows.last { Self.isSwitchable($0) && $0.isMiniaturized }
    }

    /// A window the person can still return to: one shown or minimized, one a capture ordered out
    /// (a hold), or any while Recortia is hidden.
    var hasUserWindow: Bool {
        _ = trackedHasUserWindow
        return liveHasUserWindow
    }

    private var liveHasUserWindow: Bool {
        holds > 0 || NSApp.isHidden || NSApp.windows.contains(where: Self.isSwitchable)
    }

    private func syncObservedPresence() {
        let live = liveHasUserWindow
        if trackedHasUserWindow != live { trackedHasUserWindow = live }
    }

    private func refresh() {
        // A close is reported in the turn that sees it or never: a capture holding the app then
        // means the person is still working, and cancelling that capture must not quit.
        let closed = closedSwitchableWindow
        closedSwitchableWindow = false
        syncObservedPresence()
        if NSApp.windows.contains(where: Self.isSwitchable) {
            windowWillAppear()
            return
        }
        guard holds == 0, !NSApp.isHidden else { return }
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
            #if DEBUG
                demotions += 1
            #endif
        }
        if closed { onLastWindowClosed?() }
    }

    /// A top-level window at the normal or modal level that is shown or minimized: the editor,
    /// Settings, onboarding, scrolling review, About, alerts, open panels, and pins. A pin counts at
    /// any level (`SwitchableAtAnyLevel`). Capture panels, HUDs, the drag chip, menus, and status
    /// items sit at higher levels and never count.
    static func isSwitchable(_ window: NSWindow) -> Bool {
        window.parent == nil && window.sheetParent == nil
            && (window.level == .normal || window.level == .modalPanel || window is any SwitchableAtAnyLevel)
            && (window.isVisible || window.isMiniaturized)
    }
}

/// A window that stays switchable when it floats: a pin with Keep on Top is still a window the
/// person returns to (ADR-007 amendment).
protocol SwitchableAtAnyLevel: NSWindow {}
