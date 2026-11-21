import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-04, Settings › General): the opening zoom ignores the preference, opens a
// large image at 100 % so it overflows the canvas, or enlarges a small one past 100 %; the wheel
// zooms without the preference, scrolls when it should zoom, ignores Option, zooms the wrong
// way when reversed, leaves the zoom range, or jumps on non-finite deltas.
@Suite("Editor zoom preferences (FR-04)")
@MainActor
struct EditorZoomPreferenceTests {
    private func harness(
        width: Int, height: Int, _ change: (inout Preferences) -> Void = { _ in }
    ) -> EditorHarness {
        let settings = SettingsStore(storage: MemoryPreferenceStorage())
        settings.update(change)
        return EditorHarness(session: EditorFixtures.session(width: width, height: height), settings: settings)
    }

    private func wheel(_ deltaY: Double, precise: Bool = true, command: Bool = false, option: Bool = false)
        -> EditorScrollWheel
    {
        EditorScrollWheel(deltaX: 3, deltaY: deltaY, isPrecise: precise, command: command, option: option)
    }

    private static func near(_ a: Point<DocumentSpace>, _ b: Point<DocumentSpace>) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    @Test("Fit stays the default: an image that fits 100 % but not the fit margin opens below 100 %")
    func fitIsDefault() {
        let m = harness(width: 1000, height: 500).model
        #expect(m.environment.settings.preferences.editorOpenZoom == .fit)
        m.setViewportSize(Size(width: 1020, height: 520), backingScale: 1)
        #expect(m.viewport.zoom == (520 - 48) / 500.0)
    }

    @Test("Actual size when it fits opens at 100 % when the image fits the canvas")
    func actualSizeWhenItFits() {
        let m = harness(width: 1000, height: 500) { $0.editorOpenZoom = .actualSizeWhenFits }.model
        m.setViewportSize(Size(width: 1020, height: 520), backingScale: 1)
        #expect(m.zoomPercent == 100)
        let shown = m.viewport.viewRect(m.document.contentRect)
        #expect(shown.midX == 510 && shown.midY == 260)
    }

    @Test("Actual size when it fits uses the backing scale and falls back to Fit when it does not fit")
    func actualSizeFallsBackToFit() {
        let fits = harness(width: 2000, height: 1000) { $0.editorOpenZoom = .actualSizeWhenFits }.model
        fits.setViewportSize(Size(width: 1010, height: 510), backingScale: 2)
        #expect(fits.zoomPercent == 100)

        let large = harness(width: 3000, height: 1000) { $0.editorOpenZoom = .actualSizeWhenFits }.model
        large.setViewportSize(Size(width: 1048, height: 548), backingScale: 1)
        #expect(large.viewport.zoom == 1000 / 3000.0)
    }

    @Test("The opening zoom is applied once; later layouts keep the person's zoom")
    func openingZoomOnce() {
        let m = harness(width: 1000, height: 500) { $0.editorOpenZoom = .actualSizeWhenFits }.model
        m.setViewportSize(Size(width: 1020, height: 520), backingScale: 1)
        m.setZoom(3)
        m.setViewportSize(Size(width: 2000, height: 900), backingScale: 1)
        #expect(m.viewport.zoom == 3)
    }

    @Test("Without wheel zoom the wheel scrolls and ⌘-wheel zooms around the pointer, as before")
    func wheelDefault() {
        let m = harness(width: 400, height: 300).model
        m.setViewport(EditorViewport(zoom: 1, offset: Point(x: 10, y: 20)))
        m.scrollWheel(wheel(5), at: Point(x: 50, y: 50))
        #expect(m.viewport.zoom == 1 && m.viewport.offset == Point(x: 13, y: 25))
        m.scrollWheel(wheel(1, precise: false), at: Point(x: 50, y: 50))
        #expect(m.viewport.offset == Point(x: 43, y: 35), "a notched wheel moves ten points a line")

        let anchor = Point<ViewSpace>(x: 120, y: 80)
        let fixed = m.viewport.documentPoint(anchor)
        m.scrollWheel(wheel(10, command: true), at: anchor)
        #expect(abs(m.viewport.zoom - exp(0.1)) < 1e-12)
        #expect(Self.near(m.viewport.documentPoint(anchor), fixed))
    }

    @Test("With wheel zoom on, the wheel zooms around the pointer and ⌥-wheel scrolls")
    func wheelZoom() {
        let m = harness(width: 400, height: 300) { $0.zoomsWithScrollWheel = true }.model
        m.setViewport(EditorViewport(zoom: 1, offset: .zero))
        let anchor = Point<ViewSpace>(x: 200, y: 150)
        let fixed = m.viewport.documentPoint(anchor)
        m.scrollWheel(wheel(10), at: anchor)
        #expect(abs(m.viewport.zoom - exp(0.1)) < 1e-12)
        #expect(Self.near(m.viewport.documentPoint(anchor), fixed))
        m.scrollWheel(wheel(-1, precise: false), at: anchor)
        #expect(abs(m.viewport.zoom - 1) < 1e-12, "one notch down undoes ten points up")

        let zoom = m.viewport.zoom, offset = m.viewport.offset
        m.scrollWheel(wheel(5, option: true), at: anchor)
        #expect(m.viewport.zoom == zoom)
        #expect(m.viewport.offset == offset.offset(dx: 3, dy: 5))
    }

    @Test("Reverse zoom direction inverts wheel zoom and matters only while wheel zoom is on")
    func reversedWheel() {
        let reversed = harness(width: 400, height: 300) {
            $0.zoomsWithScrollWheel = true
            $0.reversesScrollWheelZoom = true
        }.model
        reversed.setViewport(EditorViewport(zoom: 1))
        reversed.scrollWheel(wheel(10), at: .zero)
        #expect(abs(reversed.viewport.zoom - exp(-0.1)) < 1e-12)
        reversed.scrollWheel(wheel(10, command: true), at: .zero)
        #expect(abs(reversed.viewport.zoom - exp(-0.2)) < 1e-12, "⌘-wheel follows the same direction")

        let off = harness(width: 400, height: 300) { $0.reversesScrollWheelZoom = true }.model
        off.setViewport(EditorViewport(zoom: 1))
        off.scrollWheel(wheel(10, command: true), at: .zero)
        #expect(abs(off.viewport.zoom - exp(0.1)) < 1e-12)
    }

    @Test("Wheel zoom stays inside the zoom range and ignores non-finite deltas")
    func wheelClampsAndRejectsNonFinite() {
        let m = harness(width: 400, height: 300) { $0.zoomsWithScrollWheel = true }.model
        m.setViewport(EditorViewport(zoom: 1))
        for _ in 0..<200 { m.scrollWheel(wheel(100), at: .zero) }
        #expect(m.viewport.zoom == EditorViewport.zoomRange.upperBound)
        for _ in 0..<400 { m.scrollWheel(wheel(-100), at: .zero) }
        #expect(m.viewport.zoom == EditorViewport.zoomRange.lowerBound)

        let before = m.viewport
        m.scrollWheel(wheel(.nan), at: .zero)
        m.scrollWheel(EditorScrollWheel(deltaX: .infinity, deltaY: 1, isPrecise: true), at: .zero)
        m.scrollWheel(wheel(1, option: true), at: Point(x: Double.nan, y: 0))
        #expect(m.viewport.zoom == before.zoom)
        #expect(m.viewport.offset.isFinite)
    }
}
