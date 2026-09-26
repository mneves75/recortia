import CoreGraphics
import CoreText
import Domain
import Foundation

/// Draws annotations in document space. The editor canvas and the export renderer both call
/// this, so preview and export geometry cannot drift apart (FR-13, EXP-01).
///
/// The context must already map document space with a top-left origin and y growing downward.
/// Font smoothing is disabled while drawing so the output does not depend on the display.
public enum AnnotationRenderer {
    public static func draw(_ annotations: [Annotation], in context: CGContext) {
        for annotation in annotations where isDrawable(annotation) {
            draw(annotation, in: context)
        }
    }

    /// Whether every coordinate and style value is finite and sensible; others are skipped.
    static func isDrawable(_ annotation: Annotation) -> Bool {
        let style = annotation.style
        guard style.lineWidth.isFinite, style.lineWidth >= 0, style.opacity.isFinite else { return false }
        let points: [Point<DocumentSpace>]
        switch annotation.kind {
        case .text(let text):
            guard text.fontSize.isFinite, text.fontSize > 0, text.maxWidth.map({ $0.isFinite && $0 > 0 }) ?? true else {
                return false
            }
            points = [text.origin]
        case .arrow(let start, let end):
            points = [start, end]
        case .rectangle(let rect), .ellipse(let rect):
            guard rect.size.width.isFinite, rect.size.height.isFinite, rect.width >= 0, rect.height >= 0 else {
                return false
            }
            points = [rect.origin]
        case .freehand(let list), .highlighter(let list):
            points = list
        case .step(let center, _):
            points = [center]
        }
        return points.allSatisfy(\.isFinite)
    }

    private static func draw(_ annotation: Annotation, in context: CGContext) {
        let style = annotation.style
        let opacity = min(max(style.opacity, 0), 1)
        guard opacity > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldSmoothFonts(false)
        context.setShouldAntialias(true)
        let layered = opacity < 1
        if layered {
            // One transparency layer per annotation, so overlapping parts do not double up.
            context.setAlpha(opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let stroke = cgColor(style.stroke)
        context.setStrokeColor(stroke)
        context.setFillColor(stroke)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.kind {
        case .text(let text):
            drawText(text, style: style, in: context)
        case .arrow(let start, let end):
            drawArrow(from: start.cg, to: end.cg, lineWidth: style.lineWidth, in: context)
        case .rectangle(let rect):
            drawShape(CGPath(rect: rect.cg, transform: nil), style: style, in: context)
        case .ellipse(let rect):
            drawShape(CGPath(ellipseIn: rect.cg, transform: nil), style: style, in: context)
        case .freehand(let points), .highlighter(let points):
            drawStroke(points.map(\.cg), lineWidth: style.lineWidth, in: context)
        case .step(let center, let number):
            drawStep(center: center.cg, number: number, radius: annotation.stepRadius, style: style, in: context)
        }

        if layered { context.endTransparencyLayer() }
    }

    static func cgColor(_ color: RGBA) -> CGColor {
        CGColor(
            srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255,
            alpha: CGFloat(color.a) / 255)
    }

    private static func drawShape(_ path: CGPath, style: Annotation.Style, in context: CGContext) {
        if let fill = style.fill {
            context.setFillColor(cgColor(fill))
            context.addPath(path)
            context.fillPath()
        }
        guard style.lineWidth > 0 else { return }
        context.addPath(path)
        context.strokePath()
    }

    private static func drawStroke(_ points: [CGPoint], lineWidth: Double, in context: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            let r = max(lineWidth, 1) / 2
            context.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: 2 * r, height: 2 * r))
            return
        }
        context.addLines(between: points)
        context.strokePath()
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, lineWidth: Double, in context: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return }
        let w = max(lineWidth, 1)
        let headLength = min(length, max(w * 4.5, 14))
        let headHalfWidth = max(w * 3, 9)
        let ux = dx / length, uy = dy / length
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        // The shaft stops inside the head so its round cap never pokes past the tip.
        let shaftEnd = CGPoint(x: end.x - ux * headLength * 0.8, y: end.y - uy * headLength * 0.8)
        context.setLineCap(.butt)
        context.addLines(between: [start, shaftEnd])
        context.strokePath()
        context.addLines(between: [
            end,
            CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth),
            CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth),
        ])
        context.closePath()
        context.fillPath()
    }

    private static func drawStep(
        center: CGPoint, number: Int, radius: Double, style: Annotation.Style, in context: CGContext
    ) {
        let fill = style.fill ?? style.stroke
        context.setFillColor(cgColor(fill))
        context.fillEllipse(
            in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        let luminance = 0.2126 * Double(fill.r) + 0.7152 * Double(fill.g) + 0.0722 * Double(fill.b)
        let textColor: RGBA = luminance > 150 ? .black : .white
        let font =
            CTFontCreateUIFontForLanguage(.emphasizedSystem, radius * 1.1, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, radius * 1.1, nil)
        guard let line = makeLine(String(number), font: font, color: textColor) else { return }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        context.saveGState()
        context.translateBy(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func makeLine(_ string: String, font: CTFont, color: RGBA) -> CTLine? {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: cgColor(color)]
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else {
            return nil
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Multiline Core Text layout: Unicode, emoji (font fallback), and bidirectional text are
    /// handled by the typesetter; alignment is natural for the paragraph's direction.
    private static func drawText(_ text: Annotation.TextContent, style: Annotation.Style, in context: CGContext) {
        guard !text.string.isEmpty else { return }
        let font =
            CTFontCreateUIFontForLanguage(.system, text.fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, text.fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: cgColor(style.stroke),
        ]
        guard let attributed = CFAttributedStringCreate(nil, text.string as CFString, attributes as CFDictionary)
        else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let unbounded = CGFloat.greatestFiniteMagnitude
        let constraint = CGSize(width: text.maxWidth.map { CGFloat($0) } ?? unbounded, height: unbounded)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let width = text.maxWidth.map { CGFloat($0) } ?? (suggested.width.rounded(.up) + 1)
        let height = suggested.height.rounded(.up) + 1
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }

        if let fill = style.fill {
            context.setFillColor(cgColor(fill))
            context.fill(CGRect(x: text.origin.x, y: text.origin.y, width: width, height: height))
        }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        // Core Text lays out with y up; flip locally so the first line sits at `origin`.
        context.translateBy(x: text.origin.x, y: text.origin.y + height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

extension Point {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

extension Rect {
    var cg: CGRect { CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height) }
}
