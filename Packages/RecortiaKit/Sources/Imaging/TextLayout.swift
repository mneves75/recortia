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
    public let frame: Rect<DocumentSpace>
    public let contentFrame: Rect<DocumentSpace>
}

/// Stateless public-system-font resolution shared by native editing, selection and export.
public enum TextLayout {
    public static func nativeFont(for appearance: TextAppearance, size: Double) throws(TextLayoutError) -> NSFont {
        guard size.isFinite, size > 0 else { throw .invalidGeometry }
        let base = NSFont.systemFont(ofSize: size)
        guard appearance != .standard else { return base }
        let design: NSFontDescriptor.SystemDesign = appearance == .rounded ? .rounded : .monospaced
        guard let descriptor = base.fontDescriptor.withDesign(design),
            let font = NSFont(descriptor: descriptor, size: size)
        else { throw .unavailableFont(appearance) }
        return font
    }

    public static func metrics(for text: Annotation.TextContent) throws(TextLayoutError) -> TextLayoutMetrics {
        try operation(for: text, color: .black).metrics
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

    static func operation(for text: Annotation.TextContent, color: RGBA) throws(TextLayoutError) -> Operation {
        guard text.origin.isFinite, text.maxWidth.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw .invalidGeometry
        }
        let font = try nativeFont(for: text.resolvedAppearance, size: text.fontSize) as CTFont
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: color.cgColor,
        ]
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
                x: content.minX + origin.x + ink.minX - 1,
                y: content.maxY - origin.y - ink.maxY - 1, width: ink.width + 2, height: ink.height + 2)
            bounds = bounds.union(painted)
        }
        return Operation(frame: frame, metrics: TextLayoutMetrics(frame: bounds, contentFrame: content))
    }
}
