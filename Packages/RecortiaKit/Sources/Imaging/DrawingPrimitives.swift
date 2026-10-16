import CoreGraphics
import Domain

/// Drawing helpers shared by the export renderer and the editor canvas, so preview and export
/// draw the same way (EXP-01).
public enum DrawingPrimitives {
    /// Draws `image` upright into `rect` of a context whose y axis grows downward (top-left origin).
    public static func drawUpright(_ image: CGImage, in rect: CGRect, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}

extension RGBA {
    /// The color in the sRGB space with straight alpha.
    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// The color converted to 8-bit sRGB, or nil when it cannot be converted.
    public init?(cgColor: CGColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
            let c = converted.components, c.count >= 4
        else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(r: byte(c[0]), g: byte(c[1]), b: byte(c[2]), a: byte(c[3]))
    }
}
