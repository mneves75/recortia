import AppKit
import CoreGraphics
import Domain

/// Binds a scrolling capture to the visible window beneath the selected region without Accessibility.
/// Only window IDs, process IDs, and bounds are read; titles and pixels are never inspected here.
@MainActor
final class LiveScrollTargetChecker: ScrollTargetChecking {
    private struct Window: Equatable {
        let id: CGWindowID
        let ownerPID: pid_t
        let bounds: CGRect
    }

    private let point: CGPoint
    private let display: DisplayInfo
    private var boundWindow: Window?

    init(region: Rect<DesktopSpace>, display: DisplayInfo) {
        point = CGPoint(x: region.midX, y: region.midY)
        self.display = display
    }

    func bind() -> Bool {
        guard displayIsCurrent(), let window = windowAtPoint(),
            focusAllows(window.ownerPID)
        else { return false }
        boundWindow = window
        return true
    }

    func isCurrent() -> Bool {
        guard let boundWindow, displayIsCurrent(),
            focusAllows(boundWindow.ownerPID),
            windowAtPoint() == boundWindow
        else { return false }
        return true
    }

    private func displayIsCurrent() -> Bool {
        DesktopGeometry.displays().first { $0.id == display.id }?.fingerprint == display.fingerprint
    }

    private func focusAllows(_ targetPID: pid_t) -> Bool {
        // Selecting a region and clicking the capture HUD can leave Recortia frontmost. Its own
        // windows are excluded below, so accept either that focus or the selected target app.
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return foreground == targetPID || foreground == ProcessInfo.processInfo.processIdentifier
    }

    private func windowAtPoint() -> Window? {
        guard
            let entries = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in entries {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let id = entry[kCGWindowNumber as String] as? CGWindowID,
                let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.contains(point)
            else { continue }
            return Window(id: id, ownerPID: pid, bounds: bounds)
        }
        return nil
    }
}
