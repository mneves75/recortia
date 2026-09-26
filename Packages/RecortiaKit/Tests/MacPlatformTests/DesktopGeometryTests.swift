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
    @Test("The primary display converts to itself")
    func primaryIsIdentity() {
        let rect = DesktopGeometry.desktopRect(
            fromAppKit: CGRect(x: 0, y: 0, width: 1440, height: 900), primaryDisplayHeight: Arrangement.primaryHeight)
        #expect(rect == Rect<DesktopSpace>(x: 0, y: 0, width: 1440, height: 900))
    }

    @Test("Displays left of and above the primary get negative desktop origins")
    func secondaryDisplaysConvert() {
        let left = DesktopGeometry.desktopRect(
            fromAppKit: CGRect(x: -1920, y: 0, width: 1920, height: 1080), primaryDisplayHeight: 900)
        #expect(left == Arrangement.left.frame)
        let above = DesktopGeometry.desktopRect(
            fromAppKit: CGRect(x: 0, y: 900, width: 1280, height: 800), primaryDisplayHeight: 900)
        #expect(above == Arrangement.above.frame)
        #expect(
            DesktopGeometry.appKitRect(fromDesktop: Arrangement.left.frame, primaryDisplayHeight: 900)
                == CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    }

    @Test("Points flip about the primary display height")
    func pointsConvert() {
        let point = DesktopGeometry.desktopPoint(fromAppKit: CGPoint(x: 100, y: 850), primaryDisplayHeight: 900)
        #expect(point == Point<DesktopSpace>(x: 100, y: 50))
        #expect(DesktopGeometry.appKitPoint(fromDesktop: point, primaryDisplayHeight: 900) == CGPoint(x: 100, y: 850))
        let negative = DesktopGeometry.desktopPoint(fromAppKit: CGPoint(x: -5.5, y: 1700), primaryDisplayHeight: 900)
        #expect(negative == Point<DesktopSpace>(x: -5.5, y: -800))
    }

    @Test(
        "Fractional rects survive a round trip exactly",
        arguments: [
            CGRect(x: 0.25, y: 0.75, width: 10.5, height: 3.125),
            CGRect(x: -1919.5, y: 1.5, width: 0.5, height: 0.5),
            CGRect(x: 12.3, y: 1699.9, width: 100.1, height: 0.1),
        ])
    func roundTrip(rect: CGRect) {
        let desktop = DesktopGeometry.desktopRect(fromAppKit: rect, primaryDisplayHeight: 900)
        let back = DesktopGeometry.appKitRect(fromDesktop: desktop, primaryDisplayHeight: 900)
        #expect(abs(back.minX - rect.minX) < 1e-9)
        #expect(abs(back.minY - rect.minY) < 1e-9)
        #expect(abs(back.width - rect.width) < 1e-9)
        #expect(abs(back.height - rect.height) < 1e-9)
    }

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

    @Test("Hit testing finds displays with negative origins and nothing in gaps")
    func displayContainingPoint() {
        #expect(DesktopGeometry.display(containing: Point(x: -10, y: 0), in: Arrangement.all)?.id == 2)
        #expect(DesktopGeometry.display(containing: Point(x: 100, y: -1), in: Arrangement.all)?.id == 3)
        #expect(DesktopGeometry.display(containing: Point(x: 0, y: 0), in: Arrangement.all)?.id == 1)
        #expect(DesktopGeometry.display(containing: Point(x: -10, y: -500), in: Arrangement.all) == nil)
        #expect(DesktopGeometry.display(containing: Point(x: 1440, y: 10), in: Arrangement.all) == nil)
    }

    @Test("All four drag directions produce the same selection on a negative-origin display")
    func fourDragDirections() {
        let expected = Rect<DesktopSpace>(x: -1000, y: -100, width: 100, height: 50)
        let drags: [(Point<DesktopSpace>, Point<DesktopSpace>)] = [
            (Point(x: -1000, y: -100), Point(x: -900, y: -50)),
            (Point(x: -900, y: -50), Point(x: -1000, y: -100)),
            (Point(x: -900, y: -100), Point(x: -1000, y: -50)),
            (Point(x: -1000, y: -50), Point(x: -900, y: -100)),
        ]
        for (start, end) in drags {
            #expect(DesktopGeometry.selection(from: start, to: end, on: Arrangement.left) == expected)
        }
    }

    @Test("A drag that crosses displays is clamped to the starting display")
    func crossDisplayDragClamps() {
        let rect = DesktopGeometry.selection(
            from: Point(x: -100, y: 100), to: Point(x: 200, y: 300), on: Arrangement.left)
        #expect(rect == Rect<DesktopSpace>(x: -100, y: 100, width: 100, height: 200))
        let upward = DesktopGeometry.selection(
            from: Point(x: 10, y: 10), to: Point(x: 20, y: -50), on: Arrangement.primary)
        #expect(upward == Rect<DesktopSpace>(x: 10, y: 0, width: 10, height: 10))
    }

    @Test("A one-point selection at the display edge is kept; an empty one is not")
    func edgesAndEmpty() {
        let edge = DesktopGeometry.selection(from: Point(x: -1, y: 0), to: Point(x: 0, y: 1), on: Arrangement.left)
        #expect(edge == Rect<DesktopSpace>(x: -1, y: 0, width: 1, height: 1))
        #expect(
            DesktopGeometry.selection(from: Point(x: 5, y: 5), to: Point(x: 5, y: 40), on: Arrangement.primary) == nil)
        #expect(
            DesktopGeometry.selection(from: Point(x: 2000, y: 5), to: Point(x: 2100, y: 40), on: Arrangement.primary)
                == nil)
    }

    @Test("Fractional regions round outward to whole pixels at 1×")
    func pixelAlignmentAt1x() {
        let display = TestSupport.display(id: 7, x: 0, y: 0, width: 100, height: 100, scale: 1)
        let local = DesktopGeometry.pixelAlignedLocalRect(
            Rect(x: 10.3, y: 20.6, width: 5.2, height: 3.1), on: display)
        #expect(local == Rect<DisplaySpace>(x: 10, y: 20, width: 6, height: 4))
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
    @Test("Every connected display has its own positive scale, a fingerprint, and the primary sits at the origin")
    func liveDisplaysAreConsistent() {
        let displays = DesktopGeometry.displays()
        for display in displays {
            #expect(display.pointPixelScale > 0)
            #expect(!display.frame.isEmpty)
            #expect(display.fingerprint.hasPrefix("\(display.id)|"))
        }
        if let primary = displays.first {
            #expect(primary.frame.origin == Point<DesktopSpace>(x: 0, y: 0))
        }
        #expect(Set(displays.map(\.id)).count == displays.count)
    }
}

@Suite("Repeat-last-region binding (FR-02)")
struct RepeatRegionTests {
    @Test("A repeat region resolves while its display is unchanged")
    func resolvesOnSameDisplay() throws {
        let rect = Rect<DesktopSpace>(x: 100, y: -700, width: 300, height: 200)
        let region = try #require(RepeatRegion(rect: rect, display: Arrangement.above))
        #expect(region.displayID == 3)
        #expect(region.fingerprint == Arrangement.above.fingerprint)
        #expect(region.target(in: Arrangement.all) == .region(rect, display: Arrangement.above))
    }

    @Test("A repeat region is clamped to its display when created")
    func clampsOnCreation() throws {
        let region = try #require(
            RepeatRegion(rect: Rect(x: 1200, y: -100, width: 300, height: 300), display: Arrangement.above))
        #expect(region.rect == Rect<DesktopSpace>(x: 1200, y: -100, width: 80, height: 100))
        #expect(RepeatRegion(rect: Rect(x: 5000, y: 0, width: 10, height: 10), display: Arrangement.above) == nil)
    }

    @Test("A scale change invalidates the repeat region")
    func invalidatedByScaleChange() throws {
        let region = try #require(
            RepeatRegion(rect: Rect(x: 100, y: -700, width: 300, height: 200), display: Arrangement.above))
        let rescaled = TestSupport.display(id: 3, x: 0, y: -800, width: 1280, height: 800, scale: 1)
        #expect(region.target(in: [Arrangement.primary, Arrangement.left, rescaled]) == nil)
    }

    @Test("A rotation or arrangement change invalidates the repeat region")
    func invalidatedByRotationOrMove() throws {
        let region = try #require(
            RepeatRegion(rect: Rect(x: -1800, y: 0, width: 300, height: 200), display: Arrangement.left))
        let rotated = TestSupport.display(id: 2, x: -1920, y: -180, width: 1920, height: 1080, scale: 1, rotation: 90)
        #expect(region.target(in: [Arrangement.primary, rotated]) == nil)
        let moved = TestSupport.display(id: 2, x: 1440, y: 0, width: 1920, height: 1080, scale: 1)
        #expect(region.target(in: [Arrangement.primary, moved]) == nil)
    }

    @Test("Removing the display invalidates the repeat region")
    func invalidatedByRemoval() throws {
        let region = try #require(
            RepeatRegion(rect: Rect(x: -1800, y: 0, width: 300, height: 200), display: Arrangement.left))
        #expect(region.target(in: [Arrangement.primary, Arrangement.above]) == nil)
        #expect(region.target(in: []) == nil)
    }
}
