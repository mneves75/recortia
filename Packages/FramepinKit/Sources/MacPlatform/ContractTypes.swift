import CoreGraphics
import Domain
import Foundation

// Integrator-owned value types shared by MacPlatform, Features, and the app (module-contracts.md).
// Workers extend these in their own files; they do not edit this one.

public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public let id: CGDirectDisplayID
    /// Desktop points, top-left origin at the primary display.
    public let frame: Rect<DesktopSpace>
    public let pointPixelScale: Double
    /// Changes when resolution, scale, rotation, or arrangement changes; invalidates repeat regions.
    public let fingerprint: String

    public init(id: CGDirectDisplayID, frame: Rect<DesktopSpace>, pointPixelScale: Double, fingerprint: String) {
        self.id = id
        self.frame = frame
        self.pointPixelScale = pointPixelScale
        self.fingerprint = fingerprint
    }
}

public struct WindowInfo: Sendable, Hashable, Identifiable {
    public let id: CGWindowID
    public let ownerName: String
    public let ownerPID: pid_t
    /// Shown in the window chooser only; never used in filenames or logs (FR-07, PRIV-01).
    public let title: String?
    public let frame: Rect<DesktopSpace>
    public let displayID: CGDirectDisplayID

    public init(
        id: CGWindowID, ownerName: String, ownerPID: pid_t, title: String?, frame: Rect<DesktopSpace>,
        displayID: CGDirectDisplayID
    ) {
        self.id = id
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
        self.displayID = displayID
    }
}

public enum CaptureTarget: Sendable, Hashable {
    /// A region on one display; regions never cross displays in v1 (FR-02).
    case region(Rect<DesktopSpace>, display: DisplayInfo)
    case display(DisplayInfo)
    case window(WindowInfo)
}

public enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case targetUnavailable
    case displayChanged
    case canceled
    case system(code: Int)
}

public enum SinkError: Error, Equatable, Sendable {
    case clipboardWriteFailed
    case destinationExists
    case accessDenied
    case diskFull
    case volumeUnavailable
    case writeFailed(code: Int)
}
