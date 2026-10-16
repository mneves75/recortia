import CoreGraphics
import Domain
import Foundation
import Testing

@testable import MacPlatform

/// A three-display arrangement: a 2× primary, a 1× display to its left that sits partly above it,
/// and a 2× display directly above it. Desktop coordinates are top-left, so both secondary displays
/// have negative origins.
private enum Arrangement {
    static let primaryHeight = 900.0
    static let primary = TestSupport.display(id: 1, x: 0, y: 0, width: 1440, height: 900, scale: 2)
    static let left = TestSupport.display(id: 2, x: -1920, y: -180, width: 1920, height: 1080, scale: 1)
    static let above = TestSupport.display(id: 3, x: 0, y: -800, width: 1280, height: 800, scale: 2)
    static let all = [primary, left, above]
}

@Suite("Desktop geometry: AppKit conversion, displays, selection (GEO-01)")
struct DesktopGeometryTests {

    @Test("DisplayInfo takes its frame from AppKit and its scale from the display, never a constant")
    func displayInfoFromAppKit() {
        let info = DesktopGeometry.displayInfo(
            id: 2, appKitFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), primaryDisplayHeight: 900,
            pointPixelScale: 1, rotationDegrees: 0)
        #expect(info == Arrangement.left)
        let retina = DesktopGeometry.displayInfo(
            id: 3, appKitFrame: CGRect(x: 0, y: 900, width: 1280, height: 800), primaryDisplayHeight: 900,
            pointPixelScale: 2, rotationDegrees: 0)
        #expect(retina.pointPixelScale == 2)
        #expect(retina.frame == Arrangement.above.frame)
    }

    @Test("The fingerprint changes with resolution, scale, rotation, and arrangement")
    func fingerprintSensitivity() {
        let frame = Rect<DesktopSpace>(x: 0, y: 0, width: 1440, height: 900)
        let base = DesktopGeometry.fingerprint(id: 1, frame: frame, pointPixelScale: 2, rotationDegrees: 0)
        #expect(base == DesktopGeometry.fingerprint(id: 1, frame: frame, pointPixelScale: 2, rotationDegrees: 0))
        let variants = [
            DesktopGeometry.fingerprint(id: 9, frame: frame, pointPixelScale: 2, rotationDegrees: 0),
            DesktopGeometry.fingerprint(
                id: 1, frame: Rect(x: 0, y: 0, width: 1728, height: 1117), pointPixelScale: 2, rotationDegrees: 0),
            DesktopGeometry.fingerprint(id: 1, frame: frame, pointPixelScale: 1, rotationDegrees: 0),
            DesktopGeometry.fingerprint(id: 1, frame: frame, pointPixelScale: 2, rotationDegrees: 90),
            DesktopGeometry.fingerprint(
                id: 1, frame: Rect(x: 1440, y: 0, width: 1440, height: 900), pointPixelScale: 2, rotationDegrees: 0),
        ]
        for variant in variants {
            #expect(variant != base)
        }
    }

    @Test("Fractional regions round outward to whole pixels at 2×")
    func pixelAlignmentAt2x() {
        let display = TestSupport.display(id: 7, x: 0, y: 0, width: 100, height: 100, scale: 2)
        let local = DesktopGeometry.pixelAlignedLocalRect(
            Rect(x: 10.3, y: 20.6, width: 5.2, height: 3.1), on: display)
        #expect(local == Rect<DisplaySpace>(x: 10, y: 20.5, width: 5.5, height: 3.5))
    }

    @Test("Alignment on a negative-origin display is local to that display and clamped")
    func pixelAlignmentNegativeOrigin() {
        let local = DesktopGeometry.pixelAlignedLocalRect(
            Rect(x: -1910.5, y: -170.25, width: 10, height: 10), on: Arrangement.left)
        #expect(local == Rect<DisplaySpace>(x: 9, y: 9, width: 11, height: 11))
        let spill = DesktopGeometry.pixelAlignedLocalRect(
            Rect(x: -10.5, y: 890.5, width: 50, height: 50), on: Arrangement.left)
        #expect(spill == Rect<DisplaySpace>(x: 1909, y: 1070, width: 11, height: 10))
        #expect(
            DesktopGeometry.pixelAlignedLocalRect(Rect(x: 5, y: 5, width: 10, height: 10), on: Arrangement.left) == nil)
        #expect(
            DesktopGeometry.pixelAlignedLocalRect(Rect(x: .nan, y: 5, width: 10, height: 10), on: Arrangement.left)
                == nil)
    }
}

@MainActor
@Suite("Live display enumeration (reads NSScreen only; no capture, no permission)")
struct LiveDisplayTests {
}

@Suite("Repeat-last-region binding (FR-02)")
struct RepeatRegionTests {

}
