import CoreGraphics
import ScreenCaptureKit

/// Which windows a capture filter must exclude besides Recortia itself.
enum CaptureExclusion {
    struct Window: Equatable {
        let id: CGWindowID
        let ownerPID: pid_t
    }

    /// Requested windows that are present in the fresh content and belong to another app. A
    /// requested window missing from the content (a Recortia panel that just closed) is not
    /// foreign: counting it would drop the app-level exclusion that also covers Recortia windows
    /// created later, such as pins and the drag chip.
    static func foreignWindowIDs(requested: Set<CGWindowID>, present: [Window], ownPID: pid_t) -> Set<CGWindowID> {
        Set(present.filter { requested.contains($0.id) && $0.ownerPID != ownPID }.map(\.id))
    }

    /// Recortia is always excluded as an application, so its windows created later (pins, the
    /// drag chip) never enter the capture. Requested windows of other apps are excluded too, by
    /// including every other app except those windows. Only if Recortia cannot be found as an
    /// application at all does this fall back to excluding the windows present right now.
    static func filter(
        display: SCDisplay, excludingWindowIDs requested: Set<CGWindowID>, content: SCShareableContent, ownPID: pid_t
    ) async -> SCContentFilter {
        let present = content.windows.map { Window(id: $0.windowID, ownerPID: $0.owningApplication?.processID ?? 0) }
        let foreign = foreignWindowIDs(requested: requested, present: present, ownPID: ownPID)
        if let own = await ownApplication(in: content, ownPID: ownPID) {
            guard !foreign.isEmpty else {
                return SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
            }
            return SCContentFilter(
                display: display, including: content.applications.filter { $0.processID != ownPID },
                exceptingWindows: content.windows.filter { foreign.contains($0.windowID) })
        }
        return SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter {
                requested.contains($0.windowID) || $0.owningApplication?.processID == ownPID
            })
    }

    /// Recortia's running application. On-screen-only content omits an app with no visible
    /// window (the menu-bar app during a capture), so look it up in the full content then.
    private static func ownApplication(in content: SCShareableContent, ownPID: pid_t) async -> SCRunningApplication? {
        if let own = content.applications.first(where: { $0.processID == ownPID }) { return own }
        let all = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return all?.applications.first { $0.processID == ownPID }
    }
}
