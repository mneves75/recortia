import CoreGraphics
import Domain
import Foundation

/// Bounded color-picker neighborhoods, measured in image pixels.
public enum PixelSampleSize: Int, CaseIterable, Hashable, Sendable {
    case singlePixel = 0
    case threeByThree = 1
    case fiveByFive = 2

    public var radius: Int { rawValue }
}

/// Color sampling (FR-11, PIX-01) reported as straight-alpha 8-bit sRGB.
/// Images in other color spaces are converted to sRGB.
public enum PixelSampler {
    /// `x`, `y` address pixels with a top-left origin; out-of-range coordinates return nil.
    public static func color(atX x: Int, y: Int, in image: CGImage) -> RGBA? {
        sample(atX: x, y: y, in: image, radius: 0)
    }

    /// A clipped, encoded-sRGB arithmetic mean in premultiplied space, unpremultiplied once.
    /// Radii outside 0...2 are rejected before allocation. Raster work runs off the caller's actor.
    @concurrent
    public static func averageColor(atX x: Int, y: Int, in image: CGImage, radius: Int) async -> RGBA? {
        guard !Task.isCancelled else { return nil }
        return sample(atX: x, y: y, in: image, radius: radius)
    }

    private static func sample(atX x: Int, y: Int, in image: CGImage, radius: Int) -> RGBA? {
        guard PixelSampleSize(rawValue: radius) != nil,
            x >= 0, y >= 0, x < image.width, y < image.height
        else { return nil }
        let x0 = x - min(radius, x), y0 = y - min(radius, y)
        let x1 = x + min(radius, image.width - x - 1) + 1
        let y1 = y + min(radius, image.height - y - 1) + 1
        guard var pixel = try? RenderRaster(width: x1 - x0, height: y1 - y0)
        else { return nil }
        let rect = CGRect(x: -x0, y: -(image.height - y1), width: image.width, height: image.height)
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
        var red = 0, green = 0, blue = 0, alpha = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            alpha += a
            if a > 0 {
                red += Int(bytes[i])
                green += Int(bytes[i + 1])
                blue += Int(bytes[i + 2])
            }
        }
        let count = pixel.pixelCount
        let a = UInt8((alpha + count / 2) / count)
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        // At most 25 pixels: channel sums and their ×255 numerator remain bounded.
        func unpremultiply(_ value: Int) -> UInt8 { UInt8(min(255, (value * 255 + alpha / 2) / alpha)) }
        return RGBA(r: unpremultiply(red), g: unpremultiply(green), b: unpremultiply(blue), a: a)
    }
}
