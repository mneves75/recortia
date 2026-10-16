import Foundation

/// Quadratic-arrow values in document space. Imaging admits their drawable geometry.
public enum ArrowCurve {
    public static func bend(start: Point<DocumentSpace>, end: Point<DocumentSpace>, control: Point<DocumentSpace>)
        -> Point<DocumentSpace>
    {
        Point(x: start.x / 4 + control.x / 2 + end.x / 4, y: start.y / 4 + control.y / 2 + end.y / 4)
    }

    public static func control(start: Point<DocumentSpace>, end: Point<DocumentSpace>, bend: Point<DocumentSpace>)
        -> Point<DocumentSpace>
    {
        Point(x: bend.x + (bend.x - start.x / 2 - end.x / 2), y: bend.y + (bend.y - start.y / 2 - end.y / 2))
    }

    public static func defaultControl(start: Point<DocumentSpace>, end: Point<DocumentSpace>) -> Point<DocumentSpace> {
        Point(
            x: start.x / 2 + end.x / 2 - (end.y - start.y) / 4,
            y: start.y / 2 + end.y / 2 + (end.x - start.x) / 4)
    }

    static func bounds(start: Point<DocumentSpace>, end: Point<DocumentSpace>, control: Point<DocumentSpace>)
        -> Rect<DocumentSpace>
    {
        func extent(_ a: Double, _ c: Double, _ b: Double) -> (Double, Double) {
            var low = min(a, b), high = max(a, b)
            let denominator = a / 2 - c + b / 2
            let t = (a / 2 - c / 2) / denominator
            if t > 0, t < 1 {
                let first = a * (1 - t) + c * t
                let second = c * (1 - t) + b * t
                let value = first * (1 - t) + second * t
                low = min(low, value)
                high = max(high, value)
            }
            return (low, high)
        }
        let x = extent(start.x, control.x, end.x), y = extent(start.y, control.y, end.y)
        return Rect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
    }
}
