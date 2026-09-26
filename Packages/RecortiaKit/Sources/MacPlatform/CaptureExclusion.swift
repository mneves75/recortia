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

    /// Recortia excluded as an application when no foreign window must go; otherwise the
    /// requested windows plus every current Recortia window.
    static func filter(
        display: SCDisplay, excludingWindowIDs requested: Set<CGWindowID>, content: SCShareableContent, ownPID: pid_t
    ) -> SCContentFilter {
        let present = content.windows.map { Window(id: $0.windowID, ownerPID: $0.owningApplication?.processID ?? 0) }
        if foreignWindowIDs(requested: requested, present: present, ownPID: ownPID).isEmpty,
            let own = content.applications.first(where: { $0.processID == ownPID })
        {
            return SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
        }
        return SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter {
                requested.contains($0.windowID) || $0.owningApplication?.processID == ownPID
            })
    }
}
