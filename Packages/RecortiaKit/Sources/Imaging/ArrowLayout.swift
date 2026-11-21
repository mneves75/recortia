import CoreGraphics
import Domain
import Foundation

/// Operation-local painted geometry shared by rendering, hit testing and ink bounds.
public struct ArrowLayout {
    public let shaftPath: CGPath
    public let shaftInkPath: CGPath
    public let headPath: CGPath
    public let inkPath: CGPath
    public let inkBounds: Rect<DocumentSpace>

    public static func make(for annotation: Annotation) throws(RenderError) -> ArrowLayout {
        guard case .arrow(let start, let end, let control, let style) = annotation.kind,
            start.isFinite, end.isFinite, annotation.style.lineWidth.isFinite,
            annotation.style.lineWidth >= 0, annotation.style.opacity.isFinite
        else { throw .invalidGeometry }
        let head = style ?? .filled
        let width = annotation.style.lineWidth
        let shaft = CGMutablePath()
        // Filled heads are added as closed triangles; an open head is a V stroked below.
        let filledHeads = CGMutablePath()
        let openHead = CGMutablePath()
        if let control {
            guard control.isFinite, start != end else { throw .invalidGeometry }
            try addCurve(
                head: head, start: start.cg, end: end.cg, control: control.cg, width: width, shaft: shaft,
                filledHeads: filledHeads, openHead: openHead)
        } else {
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length.isFinite else { throw .invalidGeometry }
            if length == 0 {
                return ArrowLayout(
                    shaftPath: shaft, shaftInkPath: shaft, headPath: filledHeads, inkPath: shaft,
                    inkBounds: Rect(origin: start, size: Size(width: 0, height: 0)))
            }
            let nominal = max(max(width, 1) * 4.5, 14)
            let direction = CGPoint(x: dx / length, y: dy / length)
            func inset(_ point: Point<DocumentSpace>, by distance: Double, sign: Double) -> CGPoint {
                CGPoint(x: point.x + sign * direction.x * distance, y: point.y + sign * direction.y * distance)
            }
            switch head {
            case .filled:
                let headLength = min(length, nominal)
                shaft.move(to: start.cg)
                shaft.addLine(to: inset(end, by: headLength * 0.8, sign: -1))
                try addHead(to: filledHeads, end: end.cg, direction: direction, length: headLength, width: width)
            case .double:
                // Two heads share the length, so they never overlap.
                let headLength = min(length / 2, nominal)
                shaft.move(to: inset(start, by: headLength * 0.8, sign: 1))
                shaft.addLine(to: inset(end, by: headLength * 0.8, sign: -1))
                try addHead(to: filledHeads, end: end.cg, direction: direction, length: headLength, width: width)
                try addHead(
                    to: filledHeads, end: start.cg, direction: CGPoint(x: -direction.x, y: -direction.y),
                    length: headLength, width: width)
            case .open:
                shaft.move(to: start.cg)
                shaft.addLine(to: end.cg)
                try addOpenHead(
                    to: openHead, end: end.cg, direction: direction, length: min(length, nominal), width: width)
            case .plain:
                shaft.move(to: start.cg)
                shaft.addLine(to: end.cg)
            }
        }
        // A filled head takes the shaft's butt end inside it; free ends are round like a line.
        let cap: CGLineCap = head == .filled || head == .double ? .butt : .round
        let ink =
            width > 0
            ? shaft.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 10)
            : CGMutablePath()
        let headInk: CGPath =
            head == .open && width > 0
            ? openHead.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
            : filledHeads
        let painted = ink.union(headInk)
        let bounds = painted.isEmpty ? CGRect(origin: start.cg, size: .zero) : painted.boundingBoxOfPath
        guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.maxX.isFinite, bounds.maxY.isFinite,
            bounds.width.isFinite, bounds.height.isFinite
        else { throw .invalidGeometry }
        return ArrowLayout(
            shaftPath: shaft, shaftInkPath: ink, headPath: headInk, inkPath: painted,
            inkBounds: Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height))
    }

    private static func addCurve(
        head: Annotation.ArrowHead, start: CGPoint, end: CGPoint, control: CGPoint, width: Double,
        shaft: CGMutablePath, filledHeads: CGMutablePath, openHead: CGMutablePath
    ) throws(RenderError) {
        switch head {
        case .filled:
            let junction = try curvedJunction(start: start, end: end, control: control, width: width, share: 1)
            shaft.move(to: start)
            shaft.addQuadCurve(to: junction.point, control: junction.control)
            try addHead(
                to: filledHeads, end: end, direction: junction.direction, length: junction.headLength, width: width)
        case .double:
            // The same exact junction at each end; the reversed curve has the same control.
            let last = try curvedJunction(start: start, end: end, control: control, width: width, share: 0.5)
            let first = try curvedJunction(start: end, end: start, control: control, width: width, share: 0.5)
            let from = 1 - first.parameter, to = last.parameter
            guard from < to else { throw .invalidGeometry }
            // The quadratic's control on [from, to] is its blossom at (from, to).
            let middle = (1 - from) * to + from * (1 - to)
            let piece = CGPoint(
                x: (1 - from) * (1 - to) * start.x + middle * control.x + from * to * end.x,
                y: (1 - from) * (1 - to) * start.y + middle * control.y + from * to * end.y)
            guard piece.x.isFinite, piece.y.isFinite else { throw .invalidGeometry }
            shaft.move(to: first.point)
            shaft.addQuadCurve(to: last.point, control: piece)
            try addHead(to: filledHeads, end: end, direction: last.direction, length: last.headLength, width: width)
            try addHead(
                to: filledHeads, end: start, direction: first.direction, length: first.headLength, width: width)
        case .open, .plain:
            shaft.move(to: start)
            shaft.addQuadCurve(to: end, control: control)
            guard head == .open else { return }
            let dx = end.x - control.x, dy = end.y - control.y
            let terminal = hypot(dx, dy)
            let chord = hypot(end.x - start.x, end.y - start.y)
            guard terminal.isFinite, chord.isFinite, chord > 0 else { throw .invalidGeometry }
            let direction =
                terminal > 0
                ? CGPoint(x: dx / terminal, y: dy / terminal)
                : CGPoint(x: (end.x - start.x) / chord, y: (end.y - start.y) / chord)
            try addOpenHead(
                to: openHead, end: end, direction: direction, length: min(chord, max(max(width, 1) * 4.5, 14)),
                width: width)
        }
    }

    public func hitTest(_ point: Point<DocumentSpace>, tolerance: Double) -> Bool {
        guard point.isFinite, tolerance.isFinite, tolerance >= 0, (tolerance * 2).isFinite else { return false }
        if inkPath.contains(point.cg) { return true }
        guard tolerance > 0 else { return false }
        return inkPath.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .contains(point.cg)
    }

    private struct Junction {
        let point: CGPoint
        let control: CGPoint
        let direction: CGPoint
        let headLength: Double
        /// Where the shaft meets the head, as the curve's parameter from `start`.
        let parameter: Double
    }

    /// `share` limits the head to that fraction of the terminal branch (one half for two heads).
    private static func curvedJunction(
        start: CGPoint, end: CGPoint, control: CGPoint, width: Double, share: Double
    ) throws(RenderError) -> Junction {
        let dx = end.x - control.x, dy = end.y - control.y
        let terminalLength = hypot(dx, dy)
        let chordLength = hypot(end.x - start.x, end.y - start.y)
        guard terminalLength.isFinite, chordLength.isFinite, chordLength > 0 else { throw .invalidGeometry }
        let direction =
            terminalLength > 0
            ? CGPoint(x: dx / terminalLength, y: dy / terminalLength)
            : CGPoint(x: (end.x - start.x) / chordLength, y: (end.y - start.y) / chordLength)
        // In backward parameter s = 1-t, terminal projection is a*s + b*s².
        // Its first stationary point bounds the monotonic terminal branch; earlier turns
        // must never influence the root chosen for the head junction.
        let a = terminalLength * 2
        let b = (end.x - start.x) * direction.x + (end.y - start.y) * direction.y - a
        guard a.isFinite, b.isFinite else { throw .invalidGeometry }
        let branch = b < 0 ? min(1, -a / b / 2) : 1
        let maximum = branch * (a + b * branch)
        let nominalLength = max(max(width, 1) * 4.5, 14)
        let halfWidth = max(max(width, 1) * 3, 9)
        guard branch > 0, maximum.isFinite, maximum > 0, nominalLength.isFinite, halfWidth.isFinite else {
            throw .invalidGeometry
        }
        var headLength = min(nominalLength, maximum * share)
        for _ in 0..<24 {
            let depth = headLength * 0.8
            var low = 0.0, high = branch
            for _ in 0..<64 {
                let mid = low / 2 + high / 2
                if mid * (a + b * mid) < depth { low = mid } else { high = mid }
            }
            let t = 1 - (low / 2 + high / 2)
            let first = interpolate(start, control, t), second = interpolate(control, end, t)
            let point = interpolate(first, second, t)
            let tangentLength = hypot(second.x - first.x, second.y - first.y)
            if t > 0, t < 1, tangentLength.isFinite, tangentLength > 0 {
                let normal = CGPoint(x: -(second.y - first.y) / tangentLength, y: (second.x - first.x) / tangentLength)
                if fits(
                    point, normal: normal, radius: width / 2, end: end, direction: direction,
                    headLength: headLength, halfWidth: halfWidth)
                {
                    return Junction(
                        point: point, control: first, direction: direction, headLength: headLength, parameter: t)
                }
            }
            headLength /= 2
        }
        throw .invalidGeometry
    }

    private static func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x * (1 - t) + b.x * t, y: a.y * (1 - t) + b.y * t)
    }

    private static func fits(
        _ point: CGPoint, normal: CGPoint, radius: Double, end: CGPoint,
        direction: CGPoint, headLength: Double, halfWidth: Double
    ) -> Bool {
        // The whole butt cross-section must be strictly inside the convex filled head.
        for sign in [-1.0, 1.0] {
            let x = point.x + sign * normal.x * radius - end.x
            let y = point.y + sign * normal.y * radius - end.y
            let depth = -(x * direction.x + y * direction.y)
            let lateral = abs(-x * direction.y + y * direction.x)
            guard depth.isFinite, lateral.isFinite, depth > 0, depth < headLength,
                lateral < halfWidth * (depth / headLength)
            else { return false }
        }
        return true
    }

    /// The two arms of an open head, from each wing to the tip, for stroking.
    private static func addOpenHead(
        to path: CGMutablePath, end: CGPoint, direction: CGPoint, length: Double, width: Double
    ) throws(RenderError) {
        let halfWidth = max(max(width, 1) * 3, 9)
        let base = CGPoint(x: end.x - direction.x * length, y: end.y - direction.y * length)
        let first = CGPoint(x: base.x - direction.y * halfWidth, y: base.y + direction.x * halfWidth)
        let second = CGPoint(x: base.x + direction.y * halfWidth, y: base.y - direction.x * halfWidth)
        guard [end, first, second].allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw .invalidGeometry }
        path.addLines(between: [first, end, second])
    }

    private static func addHead(
        to path: CGMutablePath, end: CGPoint, direction: CGPoint, length: Double,
        width: Double
    ) throws(RenderError) {
        let halfWidth = max(max(width, 1) * 3, 9)
        let base = CGPoint(x: end.x - direction.x * length, y: end.y - direction.y * length)
        let first = CGPoint(x: base.x - direction.y * halfWidth, y: base.y + direction.x * halfWidth)
        let second = CGPoint(x: base.x + direction.y * halfWidth, y: base.y - direction.x * halfWidth)
        guard [end, first, second].allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw .invalidGeometry }
        path.addLines(between: [end, first, second])
        path.closeSubpath()
    }
}
