import Foundation

/// A fixed width-to-height ratio for a region selection (FR-02, A-4). The choice is a preference;
/// `free` constrains nothing.
public enum SelectionAspect: String, CaseIterable, Hashable, Sendable, Codable {
    case free
    case square
    case fourByThree
    case sixteenByNine
    case threeByTwo

    /// Width and height as whole numbers, so derived sides stay exact where they can; nil for `free`.
    public var ratio: (width: Double, height: Double)? {
        switch self {
        case .free: nil
        case .square: (1, 1)
        case .fourByThree: (4, 3)
        case .sixteenByNine: (16, 9)
        case .threeByTwo: (3, 2)
        }
    }
}

/// Modifier keys held while selecting a region.
public struct SelectionKeys: Hashable, Sendable {
    public var shift: Bool
    public var option: Bool
    public var command: Bool

    public init(shift: Bool = false, option: Bool = false, command: Bool = false) {
        self.shift = shift
        self.option = option
        self.command = command
    }
}

public enum NudgeDirection: Hashable, Sendable {
    case left, right, up, down
}

/// A line a dragged selection edge snaps to: vertical lines sit at an x `position`, horizontal
/// ones at a y. `extent` is the span the line covers along its own direction.
public struct SnapGuide<Space>: Hashable, Sendable {
    public enum Axis: Hashable, Sendable {
        case vertical, horizontal
    }

    public var axis: Axis
    public var position: Double
    public var extent: ClosedRange<Double>

    public init(axis: Axis, position: Double, extent: ClosedRange<Double>) {
        self.axis = axis
        self.position = position
        self.extent = extent
    }
}

/// Where the moving corner of a selection lands, and the guides it lies on.
public struct SelectionDrag<Space>: Hashable, Sendable {
    public var corner: Point<Space>
    public var guides: [SnapGuide<Space>]

    public init(corner: Point<Space>, guides: [SnapGuide<Space>]) {
        self.corner = corner
        self.guides = guides
    }
}

/// Precise region selection (FR-02, A-4): keyboard nudges, an aspect lock and edge snapping. Every
/// value is in one display's points, top-left origin; the caller converts to pixels afterwards.
public enum RegionPrecision {
    /// How close, in points, a dragged edge must come to a display or window edge to snap.
    public static let snapThreshold = 6.0
    public static let step = 1.0
    public static let largeStep = 10.0

    /// The display's own edges, then each frame's edges. Frames that miss the display are dropped.
    public static func guides<Space>(within bounds: Rect<Space>, frames: [Rect<Space>]) -> [SnapGuide<Space>] {
        let rects = [bounds] + frames.filter { $0.isValid && !$0.isEmpty && $0.intersects(bounds) }
        return rects.flatMap { rect in
            [
                SnapGuide(axis: .vertical, position: rect.minX, extent: rect.minY...rect.maxY),
                SnapGuide(axis: .vertical, position: rect.maxX, extent: rect.minY...rect.maxY),
                SnapGuide(axis: .horizontal, position: rect.minY, extent: rect.minX...rect.maxX),
                SnapGuide(axis: .horizontal, position: rect.maxY, extent: rect.minX...rect.maxX),
            ]
        }
    }

    /// The start point of a drag, snapped unless Command is held.
    public static func snappedAnchor<Space>(
        _ point: Point<Space>, keys: SelectionKeys, guides: [SnapGuide<Space>]
    ) -> SelectionDrag<Space> {
        guard !keys.command else { return SelectionDrag(corner: point, guides: []) }
        return snap(point, anchor: point, guides: guides)
    }

    /// One drag sample: the pointer is clamped to `bounds` and snapped (unless Command is held),
    /// then held to the ratio (a square while Shift is held). Snapping comes first so the ratio
    /// always holds; a guide is reported only when the constrained corner still lies on it.
    public static func drag<Space>(
        anchor: Point<Space>, pointer: Point<Space>, aspect: SelectionAspect, keys: SelectionKeys,
        guides: [SnapGuide<Space>], within bounds: Rect<Space>
    ) -> SelectionDrag<Space> {
        let clamped = Point<Space>(
            x: min(max(pointer.x, bounds.minX), bounds.maxX), y: min(max(pointer.y, bounds.minY), bounds.maxY))
        let snapped =
            keys.command ? SelectionDrag(corner: clamped, guides: []) : snap(clamped, anchor: anchor, guides: guides)
        guard let ratio = keys.shift ? (width: 1, height: 1) : aspect.ratio else { return snapped }
        let corner = constrained(anchor: anchor, pointer: snapped.corner, ratio: ratio, within: bounds)
        let shown = snapped.guides.filter { ($0.axis == .vertical ? corner.x : corner.y) == $0.position }
        return SelectionDrag(corner: corner, guides: shown)
    }

    /// An arrow key: moves by 1 pt (10 with Shift), or with Option resizes from the bottom-right
    /// edge. The selection never leaves `bounds`, never gets smaller than `minimumSide`, and keeps
    /// a locked ratio.
    public static func nudged<Space>(
        _ rect: Rect<Space>, _ direction: NudgeDirection, keys: SelectionKeys, aspect: SelectionAspect,
        within bounds: Rect<Space>, minimumSide: Double
    ) -> Rect<Space> {
        let distance = keys.shift ? largeStep : step
        let (dx, dy): (Double, Double) =
            switch direction {
            case .left: (-distance, 0)
            case .right: (distance, 0)
            case .up: (0, -distance)
            case .down: (0, distance)
            }
        if keys.option {
            return resized(rect, dx: dx, dy: dy, ratio: aspect.ratio, within: bounds, minimumSide: minimumSide)
        }
        let x = min(max(rect.minX + dx, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + dy, bounds.minY), bounds.maxY - rect.height)
        return Rect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// `rect` with its width kept and its height following `aspect`, shrunk to fit `bounds`.
    public static func fitted<Space>(
        _ rect: Rect<Space>, to aspect: SelectionAspect, within bounds: Rect<Space>, minimumSide: Double
    ) -> Rect<Space> {
        resized(rect, dx: 0, dy: 0, ratio: aspect.ratio, within: bounds, minimumSide: minimumSide)
    }

    // MARK: Rules

    private static func snap<Space>(_ point: Point<Space>, anchor: Point<Space>, guides: [SnapGuide<Space>])
        -> SelectionDrag<Space>
    {
        var corner = point
        var matched: [SnapGuide<Space>] = []
        if let guide = nearest(
            corner.x, .vertical, alongside: min(anchor.y, corner.y)...max(anchor.y, corner.y), in: guides)
        {
            corner.x = guide.position
            matched.append(guide)
        }
        if let guide = nearest(
            corner.y, .horizontal, alongside: min(anchor.x, corner.x)...max(anchor.x, corner.x), in: guides)
        {
            corner.y = guide.position
            matched.append(guide)
        }
        return SelectionDrag(corner: corner, guides: matched)
    }

    /// The guide nearest `value` within the threshold whose extent runs alongside `span` (the
    /// selection edge that would move onto it), within the threshold too.
    private static func nearest<Space>(
        _ value: Double, _ axis: SnapGuide<Space>.Axis, alongside span: ClosedRange<Double>,
        in guides: [SnapGuide<Space>]
    ) -> SnapGuide<Space>? {
        let reach = (span.lowerBound - snapThreshold)...(span.upperBound + snapThreshold)
        var best: (guide: SnapGuide<Space>, distance: Double)?
        for guide in guides where guide.axis == axis && guide.extent.overlaps(reach) {
            let distance = abs(guide.position - value)
            if distance <= snapThreshold, distance < best?.distance ?? .infinity { best = (guide, distance) }
        }
        return best?.guide
    }

    /// The corner opposite `anchor` for a selection of `ratio`: the longer side follows the
    /// pointer and the other is derived, then both shrink until the selection fits `bounds`.
    private static func constrained<Space>(
        anchor: Point<Space>, pointer: Point<Space>, ratio: (width: Double, height: Double), within bounds: Rect<Space>
    ) -> Point<Space> {
        let dx = pointer.x - anchor.x, dy = pointer.y - anchor.y
        let goesLeft = dx < 0 || (dx == 0 && anchor.x >= bounds.maxX)
        let goesUp = dy < 0 || (dy == 0 && anchor.y >= bounds.maxY)
        let edgeX = goesLeft ? bounds.minX : bounds.maxX, edgeY = goesUp ? bounds.minY : bounds.maxY
        let roomX = abs(edgeX - anchor.x), roomY = abs(edgeY - anchor.y)
        let w = abs(dx), h = abs(dy)
        var width: Double, height: Double
        if w * ratio.height >= h * ratio.width {
            width = w
            height = w * ratio.height / ratio.width
        } else {
            height = h
            width = h * ratio.width / ratio.height
        }
        if width > roomX {
            width = roomX
            height = width * ratio.height / ratio.width
        }
        if height > roomY {
            height = roomY
            width = height * ratio.width / ratio.height
        }
        // Exact where a side came from the pointer or an edge, so a snapped edge stays on its guide.
        let x = width == w ? pointer.x : width == roomX ? edgeX : anchor.x + (goesLeft ? -width : width)
        let y = height == h ? pointer.y : height == roomY ? edgeY : anchor.y + (goesUp ? -height : height)
        return Point(x: x, y: y)
    }

    private static func resized<Space>(
        _ rect: Rect<Space>, dx: Double, dy: Double, ratio: (width: Double, height: Double)?,
        within bounds: Rect<Space>, minimumSide: Double
    ) -> Rect<Space> {
        let maxWidth = bounds.maxX - rect.minX, maxHeight = bounds.maxY - rect.minY
        var width = rect.width + dx, height = rect.height + dy
        if let ratio {
            // Only a vertical key lets the height drive; otherwise the width does.
            if dx == 0, dy != 0 {
                width = height * ratio.width / ratio.height
            } else {
                height = width * ratio.height / ratio.width
            }
            if width > maxWidth {
                width = maxWidth
                height = width * ratio.height / ratio.width
            }
            if height > maxHeight {
                height = maxHeight
                width = height * ratio.width / ratio.height
            }
            if height < minimumSide {
                height = minimumSide
                width = height * ratio.width / ratio.height
            }
            if width < minimumSide {
                width = minimumSide
                height = width * ratio.height / ratio.width
            }
        }
        width = min(max(width, minimumSide), maxWidth)
        height = min(max(height, minimumSide), maxHeight)
        return Rect(x: rect.minX, y: rect.minY, width: width, height: height)
    }
}
