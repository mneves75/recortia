import Foundation
import Testing

@testable import Domain

// Failure modes (FR-02, A-4): a nudge or resize that leaves the display or shrinks a selection
// below the minimum; an aspect lock that breaks from one drag direction or at a display edge; a
// snap that reaches beyond the threshold, picks a farther edge, or still applies with Command; a
// guide drawn where the selection edge is not; a preference blob from before A-4 that no longer
// decodes.
@Suite("Region selection precision (FR-02, A-4)")
struct RegionPrecisionTests {
    private let display = Rect<DisplaySpace>(x: 0, y: 0, width: 100, height: 80)

    private func nudge(
        _ rect: Rect<DisplaySpace>, _ direction: NudgeDirection, shift: Bool = false, option: Bool = false,
        aspect: SelectionAspect = .free
    ) -> Rect<DisplaySpace> {
        RegionPrecision.nudged(
            rect, direction, keys: SelectionKeys(shift: shift, option: option), aspect: aspect, within: display,
            minimumSide: 1)
    }

    @Test("Arrows move 1 pt, Shift-arrows 10 pt, and a move stops at every display edge")
    func nudgeMovesWithinDisplay() {
        let rect = Rect<DisplaySpace>(x: 5, y: 4, width: 20, height: 10)
        #expect(nudge(rect, .right) == Rect(x: 6, y: 4, width: 20, height: 10))
        #expect(nudge(rect, .down, shift: true) == Rect(x: 5, y: 14, width: 20, height: 10))
        #expect(nudge(rect, .left, shift: true) == Rect(x: 0, y: 4, width: 20, height: 10))
        #expect(nudge(rect, .up, shift: true) == Rect(x: 5, y: 0, width: 20, height: 10))
        let corner = Rect<DisplaySpace>(x: 75, y: 65, width: 20, height: 10)
        #expect(nudge(corner, .right, shift: true) == Rect(x: 80, y: 65, width: 20, height: 10))
        #expect(nudge(corner, .down, shift: true) == Rect(x: 75, y: 70, width: 20, height: 10))
        let atEdge = Rect<DisplaySpace>(x: 0, y: 0, width: 100, height: 80)
        for direction in [NudgeDirection.left, .right, .up, .down] {
            #expect(nudge(atEdge, direction) == atEdge)
        }
    }

    @Test("Option-arrows resize from the bottom-right edge, never past the display or below the minimum")
    func nudgeResizes() {
        let rect = Rect<DisplaySpace>(x: 10, y: 10, width: 20, height: 10)
        #expect(nudge(rect, .right, option: true) == Rect(x: 10, y: 10, width: 21, height: 10))
        #expect(nudge(rect, .up, shift: true, option: true) == Rect(x: 10, y: 10, width: 20, height: 1))
        #expect(nudge(rect, .left, shift: true, option: true) == Rect(x: 10, y: 10, width: 10, height: 10))
        let thin = Rect<DisplaySpace>(x: 10, y: 10, width: 2, height: 2)
        #expect(nudge(thin, .left, shift: true, option: true) == Rect(x: 10, y: 10, width: 1, height: 2))
        let wide = Rect<DisplaySpace>(x: 85, y: 75, width: 10, height: 3)
        #expect(nudge(wide, .right, shift: true, option: true) == Rect(x: 85, y: 75, width: 15, height: 3))
        #expect(nudge(wide, .down, shift: true, option: true) == Rect(x: 85, y: 75, width: 10, height: 5))
    }

    @Test("A locked ratio survives a keyboard resize and a refit, and still fits the display")
    func resizeKeepsRatio() {
        let rect = Rect<DisplaySpace>(x: 0, y: 0, width: 32, height: 18)
        let wider = nudge(rect, .right, shift: true, option: true, aspect: .sixteenByNine)
        #expect(wider == Rect(x: 0, y: 0, width: 42, height: 23.625))
        let taller = nudge(rect, .down, shift: true, option: true, aspect: .sixteenByNine)
        #expect(taller == Rect(x: 0, y: 0, width: 448.0 / 9, height: 28))
        let grown = (0..<20).reduce(rect) { r, _ in
            nudge(r, .right, shift: true, option: true, aspect: .sixteenByNine)
        }
        #expect(grown.maxX <= display.maxX && grown.maxY <= display.maxY)
        #expect(abs(grown.width / grown.height - 16.0 / 9) < 1e-9)
        let refit = RegionPrecision.fitted(
            Rect(x: 10, y: 10, width: 60, height: 20), to: .square, within: display, minimumSide: 1)
        #expect(refit == Rect(x: 10, y: 10, width: 60, height: 60))
        let clipped = RegionPrecision.fitted(
            Rect(x: 10, y: 50, width: 60, height: 20), to: .square, within: display, minimumSide: 1)
        #expect(clipped == Rect(x: 10, y: 50, width: 30, height: 30))
        let free = Rect<DisplaySpace>(x: 10, y: 50, width: 60, height: 20)
        #expect(RegionPrecision.fitted(free, to: .free, within: display, minimumSide: 1) == free)
    }

    @Test("The ratio holds from each drag corner; Shift forces a square over any choice")
    func aspectFromEachCorner() {
        let bounds = Rect<DisplaySpace>(x: 0, y: 0, width: 400, height: 400)
        let anchor = Point<DisplaySpace>(x: 200, y: 200)
        func corner(_ x: Double, _ y: Double, _ aspect: SelectionAspect, shift: Bool = false) -> Point<DisplaySpace> {
            RegionPrecision.drag(
                anchor: anchor, pointer: Point(x: x, y: y), aspect: aspect, keys: SelectionKeys(shift: shift),
                guides: [], within: bounds
            ).corner
        }
        #expect(corner(360, 220, .sixteenByNine) == Point(x: 360, y: 290))
        #expect(corner(40, 220, .sixteenByNine) == Point(x: 40, y: 290))
        #expect(corner(360, 180, .sixteenByNine) == Point(x: 360, y: 110))
        #expect(corner(40, 180, .sixteenByNine) == Point(x: 40, y: 110))
        // The longer side follows the pointer: here the height drives the width.
        #expect(corner(210, 290, .sixteenByNine) == Point(x: 360, y: 290))
        #expect(corner(260, 240, .fourByThree) == Point(x: 260, y: 245))
        #expect(corner(230, 240, .threeByTwo) == Point(x: 260, y: 240))
        #expect(corner(260, 230, .free) == Point(x: 260, y: 230))
        for (x, y) in [(260.0, 230.0), (140, 230), (260, 170), (140, 170)] {
            let square = corner(x, y, .sixteenByNine, shift: true)
            #expect(abs(square.x - anchor.x) == 60 && abs(square.y - anchor.y) == 60)
        }
    }

    @Test("A locked ratio near a display edge shrinks to fit instead of leaving the display")
    func aspectStopsAtEdge() {
        let bounds = Rect<DisplaySpace>(x: 0, y: 0, width: 400, height: 300)
        let drag = RegionPrecision.drag(
            anchor: Point(x: 100, y: 200), pointer: Point(x: 400, y: 260), aspect: .sixteenByNine,
            keys: SelectionKeys(), guides: [], within: bounds)
        #expect(drag.corner.y == 300)
        #expect(abs((drag.corner.x - 100) / (drag.corner.y - 200) - 16.0 / 9) < 1e-9)
        let fromEdge = RegionPrecision.drag(
            anchor: Point(x: 400, y: 100), pointer: Point(x: 400, y: 160), aspect: .square, keys: SelectionKeys(),
            guides: [], within: bounds)
        #expect(fromEdge.corner == Point(x: 340, y: 160))
    }

    @Test("An edge within 6 pt snaps to the nearest display or window edge, and not one pt beyond")
    func snapsWithinThreshold() {
        let bounds = Rect<DisplaySpace>(x: 0, y: 0, width: 400, height: 300)
        let window = Rect<DisplaySpace>(x: 120, y: 40, width: 100, height: 80)
        let guides = RegionPrecision.guides(within: bounds, frames: [window])
        let anchor = Point<DisplaySpace>(x: 20, y: 60)
        func drag(_ x: Double, _ y: Double, command: Bool = false) -> SelectionDrag<DisplaySpace> {
            RegionPrecision.drag(
                anchor: anchor, pointer: Point(x: x, y: y), aspect: .free, keys: SelectionKeys(command: command),
                guides: guides, within: bounds)
        }
        let right = drag(226, 100)
        #expect(right.corner == Point(x: 220, y: 100))
        #expect(right.guides == [SnapGuide(axis: .vertical, position: 220, extent: 40...120)])
        #expect(drag(226.01, 100).corner == Point(x: 226.01, y: 100))
        #expect(drag(226.01, 100).guides.isEmpty)
        #expect(drag(115, 100).corner.x == 120)
        // Both of the window's edges near the corner snap: right (222 → 220) and bottom (117 → 120).
        #expect(drag(222, 117).corner == Point(x: 220, y: 120))
        #expect(drag(222, 117).guides.count == 2)
        #expect(drag(396, 296).corner == Point(x: 400, y: 300))
        // A window edge snaps only where the selection edge runs alongside it.
        let below = RegionPrecision.drag(
            anchor: Point(x: 20, y: 200), pointer: Point(x: 222, y: 250), aspect: .free, keys: SelectionKeys(),
            guides: guides, within: bounds)
        #expect(below.corner == Point(x: 222, y: 250))
        let anchorSnap = RegionPrecision.snappedAnchor(Point(x: 117, y: 43), keys: SelectionKeys(), guides: guides)
        #expect(anchorSnap.corner == Point(x: 120, y: 40))
    }

    @Test("Command turns snapping off for the drag and the start point")
    func commandDisablesSnapping() {
        let bounds = Rect<DisplaySpace>(x: 0, y: 0, width: 400, height: 300)
        let guides = RegionPrecision.guides(within: bounds, frames: [Rect(x: 120, y: 40, width: 100, height: 80)])
        let free = RegionPrecision.drag(
            anchor: Point(x: 20, y: 60), pointer: Point(x: 222, y: 117), aspect: .free,
            keys: SelectionKeys(command: true), guides: guides, within: bounds)
        #expect(free.corner == Point(x: 222, y: 117))
        #expect(free.guides.isEmpty)
        let start = RegionPrecision.snappedAnchor(
            Point(x: 117, y: 43), keys: SelectionKeys(command: true), guides: guides)
        #expect(start.corner == Point(x: 117, y: 43))
        #expect(start.guides.isEmpty)
    }

    @Test("With a ratio, a guide shows only when the constrained edge still lies on it")
    func guidesFollowTheConstrainedCorner() {
        let bounds = Rect<DisplaySpace>(x: 0, y: 0, width: 400, height: 300)
        let guides = RegionPrecision.guides(within: bounds, frames: [Rect(x: 120, y: 40, width: 100, height: 80)])
        let drag = RegionPrecision.drag(
            anchor: Point(x: 20, y: 30), pointer: Point(x: 218, y: 117), aspect: .square, keys: SelectionKeys(),
            guides: guides, within: bounds)
        #expect(drag.corner == Point(x: 220, y: 230))
        #expect(drag.guides == [SnapGuide(axis: .vertical, position: 220, extent: 40...120)])
    }

    @Test("Free by default, also for preferences saved before A-4; a choice is stored by name")
    func aspectPreference() throws {
        #expect(Preferences().regionAspect == .free)
        var stored = Preferences()
        stored.regionAspect = .sixteenByNine
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        #expect(object["regionAspectChoice"] as? String == "sixteenByNine")
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.regionAspect == .sixteenByNine)
        object["regionAspectChoice"] = nil
        let older = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.regionAspect == .free)
    }
}
