import AppKit

/// How Recortia's windows relate to Spaces, including other apps' fullscreen Spaces (FR-01).
///
/// Measured on macOS 27 with an accessory probe (`.scratch/space-probe`): activating the app
/// switches the user to any Space that holds one of its windows without a Space policy, even out
/// of another app's fullscreen Space. A window that follows the active Space moves to the user
/// instead, whether the app activates before or after ordering it.
enum SpacePolicy {
    /// Ordinary windows (editor, Settings, onboarding, scrolling review, alerts, About).
    static let followsActiveSpace: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    /// Panels shown on every Space (region overlay, HUDs, chooser, pins, drag chip).
    static let joinsAllSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    /// Makes `window` follow the active Space. AppKit allows one Space behavior and one fullscreen
    /// behavior per window, so conflicting ones are removed first.
    static func follow(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.subtract([.canJoinAllSpaces, .fullScreenPrimary, .fullScreenNone])
        behavior.formUnion(followsActiveSpace)
        window.collectionBehavior = behavior
    }

    /// A titled, top-level, normal or modal window without a Space policy: what AppKit and SwiftUI
    /// make for Recortia (Settings, About, alerts). Panels, menus and status items are excluded.
    static func needsAdoption(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.parent == nil && window.sheetParent == nil
            && (window.level == .normal || window.level == .modalPanel)
            && window.collectionBehavior.isDisjoint(with: [.canJoinAllSpaces, .moveToActiveSpace])
    }
}

/// Applies `SpacePolicy.follow` to windows Recortia does not construct itself, before the app
/// activates and whenever one becomes key, so activation cannot pull the user to another Space.
/// Like `SystemEventMonitor`, it lives as long as the app model; its observers capture nothing.
final class SpacePolicyMonitor {
    private var observers: [any NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.adoptAll() }
            })
        observers.append(
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if let window = NSApp.keyWindow, SpacePolicy.needsAdoption(window) { SpacePolicy.follow(window) }
                }
            })
    }

    private static func adoptAll() {
        for window in NSApp.windows where SpacePolicy.needsAdoption(window) {
            SpacePolicy.follow(window)
        }
    }
}
