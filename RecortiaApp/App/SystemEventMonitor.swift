import AppKit

/// Forwards system events that must stop capture immediately (FR-02, FR-10, PERM-02): display
/// reconfiguration, screen lock, sleep, and the user session becoming inactive (fast user switching).
/// Observation only; nothing here polls or records input.
final class SystemEventMonitor {
    enum Event: Equatable {
        case displaysChanged
        case screenLocked
        case sleeping
    }

    private let handler: (Event) -> Void
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    private var lockObserver: LockObserver?

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    func start() {
        guard tokens.isEmpty else { return }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .displaysChanged)
        // AppKit suspends distributed delivery while the app is inactive, and capture panels and the
        // scrolling HUD keep Recortia inactive: the lock must still arrive while it happens.
        let lock = LockObserver { [weak self] in self?.handler(.screenLocked) }
        DistributedNotificationCenter.default().addObserver(
            lock, selector: #selector(LockObserver.screenLocked(_:)), name: Notification.Name("com.apple.screenIsLocked"),
            object: nil, suspensionBehavior: .deliverImmediately)
        lockObserver = lock
        observe(
            NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, .screenLocked)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification, .sleeping)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification, .sleeping)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: Event) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler(event) }
        }
        tokens.append((center, token))
    }
}

private final class LockObserver: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    // The distributed center delivers on the main thread.
    @objc func screenLocked(_ notification: Notification) {
        action()
    }
}
