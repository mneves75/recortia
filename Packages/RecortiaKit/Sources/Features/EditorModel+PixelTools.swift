import CoreGraphics
import Domain
import Foundation
import Imaging

// Pixel tools (FR-11, PIX-01): nearest-pixel color sampling in sRGB, a nearest-neighbor loupe, and
// a ruler in document pixels. They sample only the sanitized base, and only while it is current,
// so they can never read a pixel a redaction covers. Results do not depend on zoom.
extension EditorModel {
    /// Screen points per document pixel for measurements, only when that is known: a single
    /// captured image shown unscaled and unrotated. Imported images have pixels, not points.
    public var measurementPointScale: Double? {
        let d = session.document
        guard d.layers.count == 1, let layer = d.layers.first, layer.placement.scale == 1,
            layer.placement.rotation == 0, let scale = d.assets[layer.assetID]?.pointPixelScale,
            scale.isFinite, scale > 0
        else { return nil }
        return scale
    }

    func measurement(from start: Point<DocumentSpace>, to end: Point<DocumentSpace>) -> EditorMeasurement {
        EditorMeasurement(start: start, end: end, pointPixelScale: measurementPointScale)
    }

    /// Places ruler anchors directly (keyboard alternative to dragging), snapped to pixel edges.
    public func setRuler(from start: Point<DocumentSpace>, to end: Point<DocumentSpace>) {
        guard start.isFinite, end.isFinite else { return }
        ruler = measurement(from: Self.snapped(start), to: Self.snapped(end))
    }

    public func clearRuler() { ruler = nil }

    /// The document pixel containing `p`, when it lies on the canvas.
    func pixel(at p: Point<DocumentSpace>) -> (x: Int, y: Int)? {
        let canvas = session.document.canvasRect
        guard p.isFinite, canvas.contains(p) else { return nil }
        return (Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
    }

    /// Samples the current sanitized base at document pixel (x, y).
    func sample(x: Int, y: Int) -> EditorColorSample? {
        guard isBaseCurrent, let base = baseImage else {
            post(.previewNotReady)
            return nil
        }
        let canvas = session.document.canvasSize
        let sx = canvas.width > 0 ? Double(base.width) / canvas.width : 1
        let sy = canvas.height > 0 ? Double(base.height) / canvas.height : 1
        let px = Int((Double(x) * sx).rounded(.down)), py = Int((Double(y) * sy).rounded(.down))
        guard let color = PixelSampler.color(atX: px, y: py, in: base) else { return nil }
        return EditorColorSample(x: x, y: y, color: color)
    }

    /// Loupe hover: records the pixel and color under `p`.
    public func inspect(at p: Point<DocumentSpace>) {
        guard let pixel = pixel(at: p) else {
            inspection = nil
            return
        }
        inspection = sample(x: pixel.x, y: pixel.y)
    }

    /// Color picker click: keeps the sampled color for display and explicit copy.
    public func pickColor(at p: Point<DocumentSpace>) {
        guard let pixel = pixel(at: p) else { return }
        if let picked = sample(x: pixel.x, y: pixel.y) { pickedColor = picked }
    }

    /// Copies the picked color as "#RRGGBB" or "R G B" plain text (explicit action only).
    @discardableResult
    public func copyPickedColor(asHex: Bool = true) -> Bool {
        guard let picked = pickedColor else { return false }
        return copyText(asHex ? picked.hex : picked.rgbText, success: .colorCopied)
    }

    /// An exact (2·radius+1)² crop of the current sanitized base around the inspected pixel, for
    /// drawing without interpolation. Nil when no pixel is inspected or the base is not current.
    public func loupe(radius: Int = 7) -> EditorLoupe? {
        guard let inspection, isBaseCurrent, let base = baseImage, radius >= 0 else { return nil }
        let canvas = session.document.canvasSize
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        // The base is rendered at scale 1, so base pixels are document pixels.
        guard base.width == Int(canvas.width.rounded()), base.height == Int(canvas.height.rounded()) else { return nil }
        let x0 = max(0, inspection.x - radius), y0 = max(0, inspection.y - radius)
        let x1 = min(base.width, inspection.x + radius + 1), y1 = min(base.height, inspection.y + radius + 1)
        guard x1 > x0, y1 > y0,
            let image = base.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        else { return nil }
        return EditorLoupe(image: image, originX: x0, originY: y0, centerX: inspection.x, centerY: inspection.y)
    }
}
