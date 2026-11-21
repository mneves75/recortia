import CoreGraphics
import Domain

/// The centre line of a freehand or highlighter stroke, shared by rendering and hit testing so a
/// smoothed stroke is selected where it is painted.
public enum StrokePath {
    /// A polyline through `points`, or with `smoothed` the `StrokeSmoothing` spline through them.
    public static func make(_ points: [Point<DocumentSpace>], smoothed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first.cg)
        if smoothed {
            for segment in StrokeSmoothing.curve(through: points) {
                path.addCurve(to: segment.end.cg, control1: segment.control1.cg, control2: segment.control2.cg)
            }
        } else {
            for point in points.dropFirst() { path.addLine(to: point.cg) }
        }
        return path
    }
}
