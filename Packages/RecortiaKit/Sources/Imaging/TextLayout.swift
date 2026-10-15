import CoreText
import Domain
import Foundation

import class AppKit.NSFont
import class AppKit.NSFontDescriptor

public enum TextLayoutError: Error, Equatable, Sendable {
    case invalidGeometry
    case unavailableFont(TextAppearance)
    case unmeasurableText
}

/// Geometry only: Core Text objects remain local to each measurement or drawing operation.
public struct TextLayoutMetrics: Hashable, Sendable {
    /// Conservative painted bounds, including glyph fallback, outline and antialiasing fringes.
    public let frame: Rect<DocumentSpace>
    /// The unchanged text origin and wrapping constraint, excluding decoration padding.
    public let contentFrame: Rect<DocumentSpace>
    /// The exact fill geometry; nil when the appearance and style have no background.
    public let backgroundFrame: Rect<DocumentSpace>?
    /// Background corner radius in document units.
    public let cornerRadius: Double
}

/// Stateless public-system-font resolution shared by native editing, selection and export.
public enum TextLayout {
    public static func nativeFont(for appearance: TextAppearance, size: Double) throws(TextLayoutError) -> NSFont {
        // Two-sided ink/decorations must have a representable extent before resolving a font.
        guard size.isFinite, size > 0, (size * 2).isFinite else { throw .invalidGeometry }
        let base = NSFont.systemFont(ofSize: size)
        let design: NSFontDescriptor.SystemDesign
        switch appearance {
        case .standard, .outlined, .boxed: return base
        case .rounded, .roundedBoxed: design = .rounded
        case .monospaced, .monospacedBoxed: design = .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design),
            let font = NSFont(descriptor: descriptor, size: size)
        else { throw .unavailableFont(appearance) }
        return font
    }

    public static func metrics(for text: Annotation.TextContent, style: Annotation.Style) throws(TextLayoutError)
        -> TextLayoutMetrics
    {
        try operation(for: text, style: style).metrics
    }

    struct Operation {
        let frame: CTFrame
        let metrics: TextLayoutMetrics

        func draw(in context: CGContext) {
            let content = metrics.contentFrame
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: content.minX, y: content.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
    }

    static func operation(for text: Annotation.TextContent, style: Annotation.Style) throws(TextLayoutError)
        -> Operation
    {
        guard text.origin.isFinite, text.maxWidth.map({ $0.isFinite && $0 > 0 }) ?? true,
            style.lineWidth.isFinite, style.lineWidth >= 0, style.opacity.isFinite
        else {
            throw .invalidGeometry
        }
        let outlined = text.resolvedAppearance == .outlined
        let percentage = outlined ? style.lineWidth / text.fontSize * 100 : 0
        // A full line width conservatively covers round outline joins and fallback glyphs;
        // image bounds alone omit the outside stroke. Export-pixel tests cover wide strokes.
        let inkPadding = outlined ? style.lineWidth + 1 : 1
        guard percentage.isFinite, (inkPadding * 2).isFinite else { throw .invalidGeometry }
        let font = try nativeFont(for: text.resolvedAppearance, size: text.fontSize) as CTFont
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: style.stroke.cgColor,
        ]
        if outlined {
            // Core Text's negative percentage requests stroke plus fill; its magnitude is
            // a percentage of font size, rather than a document-space width.
            attributes[kCTForegroundColorAttributeName] = RGBA.white.cgColor
            attributes[kCTStrokeColorAttributeName] = style.stroke.cgColor
            attributes[kCTStrokeWidthAttributeName] = -percentage
        }
        guard let attributed = CFAttributedStringCreate(nil, text.string as CFString, attributes as CFDictionary)
        else { throw .unmeasurableText }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(
            width: text.maxWidth ?? CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let width = text.maxWidth ?? (suggested.width.rounded(.up) + 1)
        let height = suggested.height.rounded(.up) + 1
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw .unmeasurableText }
        let content = Rect<DocumentSpace>(origin: text.origin, size: Size(width: width, height: height))
        guard content.maxX.isFinite, content.maxY.isFinite else { throw .unmeasurableText }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length == text.string.utf16.count else { throw .unmeasurableText }
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { throw .unmeasurableText }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var bounds = content
        for (line, origin) in zip(lines, origins) {
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
                .union(CTLineGetImageBounds(line, nil))
            guard !ink.isNull, ink.minX.isFinite, ink.minY.isFinite, ink.width.isFinite, ink.height.isFinite else {
                if ink.isNull { continue }
                throw .unmeasurableText
            }
            let painted = Rect<DocumentSpace>(
                x: content.minX + origin.x + ink.minX - inkPadding,
                y: content.maxY - origin.y - ink.maxY - inkPadding,
                width: ink.width + inkPadding * 2, height: ink.height + inkPadding * 2)
            guard painted.minX.isFinite, painted.minY.isFinite, painted.maxX.isFinite, painted.maxY.isFinite else {
                throw .unmeasurableText
            }
            bounds = bounds.union(painted)
        }
        let background: Rect<DocumentSpace>?
        if text.resolvedAppearance.isBoxed {
            let horizontal = text.fontSize * 0.25, vertical = text.fontSize * 0.16
            background = Rect(
                x: content.minX - horizontal, y: content.minY - vertical,
                width: content.width + horizontal * 2, height: content.height + vertical * 2)
        } else {
            background = style.fill == nil ? nil : content
        }
        if let background {
            guard background.minX.isFinite, background.minY.isFinite,
                background.maxX.isFinite, background.maxY.isFinite
            else { throw .unmeasurableText }
            let antialiasedBackground = Rect<DocumentSpace>(
                x: background.minX - 1, y: background.minY - 1,
                width: background.width + 2, height: background.height + 2)
            bounds = bounds.union(antialiasedBackground)
        }
        return Operation(
            frame: frame,
            metrics: TextLayoutMetrics(
                frame: bounds, contentFrame: content, backgroundFrame: background,
                cornerRadius: text.resolvedAppearance == .roundedBoxed ? text.fontSize * 0.2 : 0))
    }
}
