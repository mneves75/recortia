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
    /// Paints only the passive decoration, in document space, with the annotation's opacity.
    public static func drawTextBackground(
        _ text: Annotation.TextContent, style: Annotation.Style, in context: CGContext
    ) throws(RenderError) {
        let layout: TextLayout.Operation
        do { layout = try TextLayout.operation(for: text, style: style) } catch {
            throw .textLayoutFailed(error)
        }
        guard !text.string.isEmpty, style.opacity > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        context.setAlpha(min(style.opacity, 1))
        drawTextBackground(text, style: style, metrics: layout.metrics, in: context)
    }

    public static func draw(_ annotations: [Annotation], in context: CGContext) throws(RenderError) {
        for annotation in annotations {
            guard hasFiniteValues(annotation) else {
                if case .text = annotation.kind { throw .textLayoutFailed(.invalidGeometry) }
                if case .arrow = annotation.kind { throw .invalidGeometry }
                continue
            }
            try draw(annotation, in: context)
        }
    }

    /// Whether every coordinate and style value is finite and sensible, and an arrow has a layout.
    /// `draw` rejects invalid text and arrows and skips other invalid annotations.
    static func isDrawable(_ annotation: Annotation) -> Bool {
        guard hasFiniteValues(annotation) else { return false }
        if case .arrow = annotation.kind { return (try? ArrowLayout.make(for: annotation)) != nil }
        return true
    }

    private static func hasFiniteValues(_ annotation: Annotation) -> Bool {
        let style = annotation.style
        guard style.lineWidth.isFinite, style.lineWidth >= 0, style.opacity.isFinite else { return false }
        let points: [Point<DocumentSpace>]
        switch annotation.kind {
        case .text(let text):
            guard text.fontSize.isFinite, text.fontSize > 0, text.maxWidth.map({ $0.isFinite && $0 > 0 }) ?? true else {
                return false
            }
            points = [text.origin]
        case .arrow(let start, let end, let control, _):
            points = [start, end] + (control.map { [$0] } ?? [])
        case .line(let start, let end):
            points = [start, end]
        case .rectangle(let rect), .ellipse(let rect):
            guard rect.size.width.isFinite, rect.size.height.isFinite, rect.width >= 0, rect.height >= 0 else {
                return false
            }
            points = [rect.origin]
        case .freehand(let list, _), .highlighter(let list, _):
            points = list
        case .step(let center, _):
            points = [center]
        }
        return points.allSatisfy(\.isFinite)
    }

    private static func draw(_ annotation: Annotation, in context: CGContext) throws(RenderError) {
        let textLayout: TextLayout.Operation?
        if case .text(let text) = annotation.kind {
            do { textLayout = try TextLayout.operation(for: text, style: annotation.style) } catch {
                throw .textLayoutFailed(error)
            }
        } else {
            textLayout = nil
        }
        // An arrow that cannot be laid out fails the render: an export never drops it silently.
        let arrowLayout: ArrowLayout? =
            if case .arrow = annotation.kind { try ArrowLayout.make(for: annotation) } else { nil }
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
        defer { if layered { context.endTransparencyLayer() } }
        let stroke = style.stroke.cgColor
        context.setStrokeColor(stroke)
        context.setFillColor(stroke)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.kind {
        case .text(let text):
            if !text.string.isEmpty, let textLayout {
                drawTextBackground(text, style: style, metrics: textLayout.metrics, in: context)
                textLayout.draw(in: context)
            }
        case .arrow:
            // One filled union, so a translucent color covers the shaft/head overlap once.
            if let arrowLayout {
                context.addPath(arrowLayout.inkPath)
                context.fillPath()
            }
        case .line(let start, let end):
            context.addLines(between: [start.cg, end.cg])
            context.strokePath()
        case .rectangle(let rect):
            let path = CGMutablePath()
            path.addRect(rect.cg)
            drawShape(path, style: style, in: context)
        case .ellipse(let rect):
            let path = CGMutablePath()
            path.addEllipse(in: rect.cg)
            drawShape(path, style: style, in: context)
        case .freehand(let points, let smoothed), .highlighter(let points, let smoothed):
            drawStroke(points, smoothed: smoothed == true, lineWidth: style.lineWidth, in: context)
        case .step(let center, let number):
            drawStep(center: center.cg, number: number, radius: annotation.stepRadius, style: style, in: context)
        }

    }

    private static func drawTextBackground(
        _ text: Annotation.TextContent, style: Annotation.Style, metrics: TextLayoutMetrics, in context: CGContext
    ) {
        guard let background = metrics.backgroundFrame,
            let fill = style.fill ?? (text.resolvedAppearance.isBoxed ? .white : nil)
        else { return }
        context.setFillColor(fill.cgColor)
        if metrics.cornerRadius > 0 {
            let path = CGMutablePath()
            path.addRoundedRect(
                in: background.cg, cornerWidth: metrics.cornerRadius, cornerHeight: metrics.cornerRadius)
            context.addPath(path)
            context.fillPath()
        } else {
            context.fill(background.cg)
        }
    }

    private static func drawShape(_ path: CGPath, style: Annotation.Style, in context: CGContext) {
        if let fill = style.fill {
            context.setFillColor(fill.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        guard style.lineWidth > 0 else { return }
        context.addPath(path)
        context.strokePath()
    }

    private static func drawStroke(
        _ points: [Point<DocumentSpace>], smoothed: Bool, lineWidth: Double, in context: CGContext
    ) {
        guard let first = points.first else { return }
        if points.count == 1 {
            let r = max(lineWidth, 1) / 2
            context.fillEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: 2 * r, height: 2 * r))
            return
        }
        context.addPath(StrokePath.make(points, smoothed: smoothed))
        context.strokePath()
    }

    private static func drawStep(
        center: CGPoint, number: Int, radius: Double, style: Annotation.Style, in context: CGContext
    ) {
        let fill = style.fill ?? style.stroke
        context.setFillColor(fill.cgColor)
        context.fillEllipse(
            in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        // WCAG 2 relative luminance of the sRGB fill; the numeral takes the higher-contrast extreme.
        let luminance = fill.relativeLuminance
        let textColor: RGBA = (luminance + 0.05) / 0.05 > 1.05 / (luminance + 0.05) ? .black : .white
        let font =
            CTFontCreateUIFontForLanguage(.emphasizedSystem, radius * 1.1, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, radius * 1.1, nil)
        guard let line = makeLine(String(number), font: font, color: textColor, outline: nil) else { return }
        // A translucent fill shows an unknown background, so the numeral sits on an opposite-color
        // outline, stroked first so the fill on top keeps the glyph's full width.
        let halo =
            fill.a < 255
            ? makeLine(String(number), font: font, color: textColor, outline: textColor == .black ? .white : .black)
            : nil
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        // The inout pointers are valid for the call only, and Core Text writes one value through each.
        let width = unsafe CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        context.saveGState()
        context.translateBy(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        if let halo {
            CTLineDraw(halo, context)
            context.textPosition = .zero
        }
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func makeLine(_ string: String, font: CTFont, color: RGBA, outline: RGBA?) -> CTLine? {
        var attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color.cgColor]
        if let outline {
            // A positive width strokes without filling; the width is a percentage of the font size.
            attributes[kCTStrokeWidthAttributeName] = 24.0
            attributes[kCTStrokeColorAttributeName] = outline.cgColor
        }
        guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else {
            return nil
        }
        return CTLineCreateWithAttributedString(attributed)
    }

}

extension Point {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

extension Rect {
    var cg: CGRect { CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height) }
}
