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

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    func start() {
        guard tokens.isEmpty else { return }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .displaysChanged)
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .screenLocked)
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
