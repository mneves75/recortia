import AppKit
import CoreGraphics
import Domain
import Foundation

/// The single place where AppKit's bottom-left screen coordinates become Recortia's top-left
/// desktop coordinates (SPEC.md §7). Desktop space matches Core Graphics global display
/// coordinates: origin at the primary display's top-left corner, y growing downward, so displays
/// left of or above the primary have negative origins.
public enum DesktopGeometry {
    /// Tolerance used when snapping to the pixel grid, so values such as `10.000000000001` do not
    /// round outward by a whole pixel because of floating-point noise.
    static let pixelSnapTolerance = 1e-6

    // MARK: AppKit <-> desktop

    public static func desktopRect(fromAppKit rect: CGRect, primaryDisplayHeight: Double) -> Rect<DesktopSpace> {
        let standardized = rect.standardized
        return Rect(
            x: standardized.minX, y: primaryDisplayHeight - standardized.maxY, width: standardized.width,
            height: standardized.height)
    }

    public static func appKitRect(fromDesktop rect: Rect<DesktopSpace>, primaryDisplayHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: primaryDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func desktopPoint(fromAppKit point: CGPoint, primaryDisplayHeight: Double) -> Point<DesktopSpace> {
        Point(x: point.x, y: primaryDisplayHeight - point.y)
    }

    public static func appKitPoint(fromDesktop point: Point<DesktopSpace>, primaryDisplayHeight: Double) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    // MARK: Displays

    /// Every connected display, in desktop space, with its own backing scale. The primary display
    /// is `NSScreen.screens.first` (AppKit documents index 0 as the primary screen).
    @MainActor
    public static func displays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.compactMap { screen -> DisplayInfo? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            return displayInfo(
                id: id, appKitFrame: screen.frame, primaryDisplayHeight: primaryHeight,
                pointPixelScale: screen.backingScaleFactor, rotationDegrees: CGDisplayRotation(id))
        }
    }

    /// Builds a `DisplayInfo` from AppKit values; `displays()` uses this so the mapping is testable.
    public static func displayInfo(
        id: CGDirectDisplayID, appKitFrame: CGRect, primaryDisplayHeight: Double, pointPixelScale: Double,
        rotationDegrees: Double
    ) -> DisplayInfo {
        let frame = desktopRect(fromAppKit: appKitFrame, primaryDisplayHeight: primaryDisplayHeight)
        return DisplayInfo(
            id: id, frame: frame, pointPixelScale: pointPixelScale,
            fingerprint: fingerprint(
                id: id, frame: frame, pointPixelScale: pointPixelScale, rotationDegrees: rotationDegrees))
    }

    /// Identity plus every property that invalidates a stored region: arrangement (origin),
    /// resolution (size in points), scale, and rotation.
    public static func fingerprint(
        id: CGDirectDisplayID, frame: Rect<DesktopSpace>, pointPixelScale: Double, rotationDegrees: Double
    ) -> String {
        "\(id)|\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)|\(pointPixelScale)|\(rotationDegrees)"
    }

    public static func display(containing point: Point<DesktopSpace>, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    // MARK: Selection

    /// The region dragged from `start` to `end` in any direction, clamped to the display where the
    /// drag started (v1 regions never cross displays). Nil when nothing of it lies on that display.
    public static func selection(
        from start: Point<DesktopSpace>, to end: Point<DesktopSpace>, on display: DisplayInfo
    ) -> Rect<DesktopSpace>? {
        clamp(Rect(spanning: start, end), to: display)
    }

    /// `rect` intersected with the display, or nil when the result is empty or not finite.
    public static func clamp(_ rect: Rect<DesktopSpace>, to display: DisplayInfo) -> Rect<DesktopSpace>? {
        guard (try? rect.validated()) != nil, let clamped = rect.intersection(display.frame), !clamped.isEmpty else {
            return nil
        }
        return clamped
    }

    /// The region in the display's local points, clamped to the display and expanded outward to
    /// whole device pixels at the display's own scale. Nil when nothing remains.
    public static func pixelAlignedLocalRect(_ rect: Rect<DesktopSpace>, on display: DisplayInfo) -> Rect<DisplaySpace>?
    {
        let scale = display.pointPixelScale
        guard scale.isFinite, scale > 0, let clamped = clamp(rect, to: display) else { return nil }
        let localMinX = clamped.minX - display.frame.minX
        let localMinY = clamped.minY - display.frame.minY
        let localMaxX = clamped.maxX - display.frame.minX
        let localMaxY = clamped.maxY - display.frame.minY
        let maxPixelX = (display.frame.width * scale).rounded(.down)
        let maxPixelY = (display.frame.height * scale).rounded(.down)
        let x0 = max(0, (localMinX * scale + pixelSnapTolerance).rounded(.down))
        let y0 = max(0, (localMinY * scale + pixelSnapTolerance).rounded(.down))
        let x1 = min(maxPixelX, (localMaxX * scale - pixelSnapTolerance).rounded(.up))
        let y1 = min(maxPixelY, (localMaxY * scale - pixelSnapTolerance).rounded(.up))
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0 / scale, y: y0 / scale, width: (x1 - x0) / scale, height: (y1 - y0) / scale)
    }

    static func desktopRect(fromLocal rect: Rect<DisplaySpace>, on display: DisplayInfo) -> Rect<DesktopSpace> {
        Rect(
            x: rect.minX + display.frame.minX, y: rect.minY + display.frame.minY, width: rect.width,
            height: rect.height)
    }
}

/// The last captured region, bound to the display it was drawn on (FR-02 repeat-last-region).
/// Session-only: it is valid only while a display with the same ID and fingerprint exists.
public struct RepeatRegion: Sendable, Hashable {
    public let rect: Rect<DesktopSpace>
    public let displayID: CGDirectDisplayID
    public let fingerprint: String

    /// Clamps `rect` to `display`; nil when nothing of it lies on the display.
    public init?(rect: Rect<DesktopSpace>, display: DisplayInfo) {
        guard let clamped = DesktopGeometry.clamp(rect, to: display) else { return nil }
        self.rect = clamped
        displayID = display.id
        fingerprint = display.fingerprint
    }

    /// The capture target to repeat, or nil when the display is gone or its configuration changed;
    /// the caller then asks the user for a new selection.
    public func target(in displays: [DisplayInfo]) -> CaptureTarget? {
        guard let display = displays.first(where: { $0.id == displayID }), display.fingerprint == fingerprint else {
            return nil
        }
        return .region(rect, display: display)
    }
}
