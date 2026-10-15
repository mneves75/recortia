import AppKit
import Domain
import Features
import Imaging

/// Passive shared-renderer background underneath native text input; never owns focus or input.
final class EditorTextDecorationView: NSView {
    private struct Drawing {
        let text: Annotation.TextContent
        let style: Annotation.Style
        let origin: Point<DocumentSpace>
        let zoom: Double
    }

    private var drawing: Drawing?
    var onRenderFailure: (() -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func update(
        _ text: Annotation.TextContent, style: Annotation.Style, viewport: EditorViewport
    ) throws(TextLayoutError) {
        guard !text.string.isEmpty else {
            drawing = nil
            isHidden = true
            return
        }
        let metrics = try TextLayout.metrics(for: text, style: style)
        let rect = viewport.viewRect(metrics.frame)
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else {
            throw .invalidGeometry
        }
        drawing = Drawing(text: text, style: style, origin: metrics.frame.origin, zoom: viewport.zoom)
        frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawing, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: drawing.zoom, y: drawing.zoom)
        context.translateBy(x: -drawing.origin.x, y: -drawing.origin.y)
        do {
            try AnnotationRenderer.drawTextBackground(drawing.text, style: drawing.style, in: context)
        } catch {
            onRenderFailure?()
        }
    }
}
