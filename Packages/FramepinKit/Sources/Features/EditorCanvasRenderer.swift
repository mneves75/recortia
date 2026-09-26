import CoreGraphics
import Domain
import Foundation
import Imaging

/// Draws the editable surface in document space, in the export renderer's order: sanitized base,
/// annotations (through the same `AnnotationRenderer` export uses), secure masks as opaque fills
/// over them, then callouts. The editor canvas calls it at any zoom; tests compare it with the
/// export at scale 1 (EXP-01).
public enum EditorCanvasRenderer {
    /// `context` must already map document space with a top-left origin and y growing downward.
    /// `base` is the sanitized `renderBase` output for the whole canvas (any scale); when nil,
    /// nothing is drawn under the annotations, and masks are still drawn opaque. Magnifiers draw
    /// from `calloutBase`, which the caller passes only when it was rendered for the current
    /// privacy epoch, so a magnifier can never enlarge pixels a newer redaction covers.
    public static func draw(
        _ document: Document, base: CGImage?, calloutBase: CGImage?, draft: Annotation? = nil, in context: CGContext
    ) {
        let canvas = document.canvasRect.cg
        if let base {
            context.saveGState()
            context.interpolationQuality = .none
            drawUpright(base, in: canvas, context)
            context.restoreGState()
        }
        var annotations = document.annotations
        if let draft { annotations.append(draft) }
        context.saveGState()
        context.clip(to: canvas)
        AnnotationRenderer.draw(annotations, in: context)
        context.restoreGState()

        // Output-space coverage over vectors and text, rounded outward like the export.
        context.saveGState()
        context.setShouldAntialias(false)
        for mask in document.masks where mask.fill.isOpaque {
            context.setFillColor(cgColor(mask.fill))
            context.fill(EditorGeometry.outwardIntegral(mask.outputRect).cg.intersection(canvas))
        }
        context.restoreGState()

        drawCallouts(document, base: calloutBase, in: context)
    }

    static func drawCallouts(_ document: Document, base: CGImage?, in context: CGContext) {
        let content = document.contentRect.cg
        for callout in document.callouts {
            switch callout.kind {
            case .spotlight(let rect, let dimOpacity):
                context.saveGState()
                context.clip(to: content)
                context.addRect(content)
                context.addRect(rect.cg)
                context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: min(max(dimOpacity, 0), 1)))
                context.fillPath(using: .evenOdd)
                context.restoreGState()
            case .magnifier(let source, let destination):
                guard source.width > 0, source.height > 0 else { continue }
                if let base {
                    // The magnifier shows the sanitized base only, never annotations or itself.
                    context.saveGState()
                    context.clip(to: destination.cg.intersection(content))
                    context.translateBy(x: destination.minX, y: destination.minY)
                    context.scaleBy(x: destination.width / source.width, y: destination.height / source.height)
                    context.translateBy(x: -source.minX, y: -source.minY)
                    context.interpolationQuality = .none
                    drawUpright(base, in: document.canvasRect.cg, context)
                    context.restoreGState()
                }
                context.saveGState()
                context.clip(to: content)
                context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 0.9))
                context.setLineWidth(1)
                context.stroke(destination.cg)
                context.restoreGState()
            }
        }
    }

    /// Draws `image` upright into `rect` of a y-down context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    static func cgColor(_ color: RGBA) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255,
            alpha: CGFloat(color.a) / 255)
    }
}

extension Rect {
    var cg: CGRect { CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height) }
}
