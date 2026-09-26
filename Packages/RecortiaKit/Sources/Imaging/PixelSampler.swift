import CoreGraphics
import Domain
import Foundation

/// Color picker sampling (FR-11, PIX-01): the nearest pixel, never interpolated, reported as
/// straight-alpha 8-bit sRGB. Images in other color spaces are converted to sRGB.
public enum PixelSampler {
    /// `x`, `y` address pixels with a top-left origin; out-of-range coordinates return nil.
    public static func color(atX x: Int, y: Int, in image: CGImage) -> RGBA? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
            var pixel = try? RenderRaster(width: 1, height: 1)
        else { return nil }
        let rect = CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height)
        do {
            try pixel.withContext { context in
                context.setBlendMode(.copy)
                context.interpolationQuality = .none
                context.draw(image, in: rect)
            }
        } catch {
            return nil
        }
        let bytes = pixel.pixels(in: pixel.bounds)
        let a = bytes[3]
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func unpremultiply(_ value: UInt8) -> UInt8 { UInt8(min(255, (Int(value) * 255 + Int(a) / 2) / Int(a))) }
        return RGBA(r: unpremultiply(bytes[0]), g: unpremultiply(bytes[1]), b: unpremultiply(bytes[2]), a: a)
    }
}
