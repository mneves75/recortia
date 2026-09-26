import Domain
import Foundation

/// Zoom and pan: view state only. Document geometry never depends on it (FR-04, EDIT-02); the
/// canvas converts pointer locations to document space through it before calling the model.
public struct EditorViewport: Hashable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 0.05...32
    /// Zoom presets for zoom in/out, in view points per document pixel.
    public static let steps: [Double] = [
        0.05, 0.1, 0.125, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32,
    ]

    /// View points per document unit.
    public private(set) var zoom: Double
    /// View location of the document origin.
    public private(set) var offset: Point<ViewSpace>

    public init(zoom: Double = 1, offset: Point<ViewSpace> = .zero) {
        self.zoom = Self.clamp(zoom)
        self.offset = offset.isFinite ? offset : .zero
    }

    public var documentToView: AffineMap<DocumentSpace, ViewSpace> {
        AffineMap(a: zoom, b: 0, c: 0, d: zoom, tx: offset.x, ty: offset.y)
    }

    public func viewPoint(_ p: Point<DocumentSpace>) -> Point<ViewSpace> {
        Point(x: p.x * zoom + offset.x, y: p.y * zoom + offset.y)
    }

    public func documentPoint(_ p: Point<ViewSpace>) -> Point<DocumentSpace> {
        Point(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
    }

    public func viewRect(_ r: Rect<DocumentSpace>) -> Rect<ViewSpace> {
        Rect(origin: viewPoint(r.origin), size: Size(width: r.width * zoom, height: r.height * zoom))
    }

    public func documentRect(_ r: Rect<ViewSpace>) -> Rect<DocumentSpace> {
        Rect(origin: documentPoint(r.origin), size: Size(width: r.width / zoom, height: r.height / zoom))
    }

    /// A length of `viewPoints` on screen, in document units at the current zoom.
    public func documentLength(_ viewPoints: Double) -> Double { viewPoints / zoom }

    /// Sets the zoom so the document point under `anchor` stays under it.
    public mutating func setZoom(_ newZoom: Double, anchor: Point<ViewSpace>) {
        let clamped = Self.clamp(newZoom)
        guard anchor.isFinite else {
            zoom = clamped
            return
        }
        let fixed = documentPoint(anchor)
        zoom = clamped
        offset = Point(x: anchor.x - fixed.x * zoom, y: anchor.y - fixed.y * zoom)
    }

    public mutating func pan(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return }
        offset = offset.offset(dx: dx, dy: dy)
    }

    public func nextZoomIn() -> Double { Self.steps.first { $0 > zoom * 1.0001 } ?? Self.zoomRange.upperBound }

    public func nextZoomOut() -> Double {
        Self.steps.last { $0 < zoom / 1.0001 } ?? Self.zoomRange.lowerBound
    }

    /// The viewport that shows `rect` centered in a view of `size`, with `margin` points around it.
    public static func fitting(
        _ rect: Rect<DocumentSpace>, in size: Size<ViewSpace>, margin: Double = 24, maxZoom: Double = 32
    ) -> EditorViewport {
        let availableWidth = max(1, size.width - 2 * margin), availableHeight = max(1, size.height - 2 * margin)
        guard rect.width > 0, rect.height > 0, availableWidth.isFinite, availableHeight.isFinite else {
            return EditorViewport()
        }
        let zoom = clamp(min(availableWidth / rect.width, availableHeight / rect.height, maxZoom))
        return centered(on: rect, in: size, zoom: zoom)
    }

    /// The viewport at `zoom` whose center shows the center of `rect`.
    public static func centered(on rect: Rect<DocumentSpace>, in size: Size<ViewSpace>, zoom: Double)
        -> EditorViewport
    {
        let z = clamp(zoom)
        return EditorViewport(
            zoom: z, offset: Point(x: size.width / 2 - rect.midX * z, y: size.height / 2 - rect.midY * z))
    }

    static func clamp(_ zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0 else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }
}
