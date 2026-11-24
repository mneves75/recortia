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

    /// Sides of the darkest-pixel box, in image pixels: 20 pt at up to 4 pixels per point.
    public static let darkestSides = 1...80

    /// The pixel of lowest Rec. 709 relative luminance in a `side`-pixel square around (x, y),
    /// clipped to the image, as straight-alpha sRGB; ties go to the first in reading order. Fully
    /// transparent pixels are skipped (their hidden RGB would read as black); all transparent
    /// returns `RGBA.clear`. Out-of-range coordinates or sides return nil. Runs off the caller's actor.
    @concurrent
    public static func darkestColor(centerX x: Int, y: Int, in image: CGImage, side: Int) async -> RGBA? {
        guard !Task.isCancelled, darkestSides.contains(side), x >= 0, y >= 0, x < image.width, y < image.height
        else { return nil }
        let x0 = max(0, x - side / 2), y0 = max(0, y - side / 2)
        let x1 = min(image.width, x - side / 2 + side), y1 = min(image.height, y - side / 2 + side)
        guard let bytes = pixels(x0: x0, y0: y0, x1: x1, y1: y1, in: image) else { return nil }
        var darkest: (color: RGBA, luminance: Double)?
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            guard a > 0 else { continue }
            func unpremultiply(_ value: UInt8) -> UInt8 { UInt8(min(255, (Int(value) * 255 + a / 2) / a)) }
            let color = RGBA(
                r: unpremultiply(bytes[i]), g: unpremultiply(bytes[i + 1]), b: unpremultiply(bytes[i + 2]), a: UInt8(a))
            let luminance = color.relativeLuminance
            if darkest.map({ luminance < $0.luminance }) ?? true { darkest = (color, luminance) }
        }
        return darkest?.color ?? .clear
    }

    /// Premultiplied sRGB bytes of the image rectangle x0..<x1, y0..<y1 (top-left origin), top row first.
    private static func pixels(x0: Int, y0: Int, x1: Int, y1: Int, in image: CGImage) -> [UInt8]? {
        guard var raster = try? RenderRaster(width: x1 - x0, height: y1 - y0) else { return nil }
        let rect = CGRect(x: -x0, y: -(image.height - y1), width: image.width, height: image.height)
        do {
            try raster.withContext { context in
                context.setBlendMode(.copy)
                context.interpolationQuality = .none
                context.draw(image, in: rect)
            }
        } catch {
            return nil
        }
        return raster.pixels(in: raster.bounds)
    }

    private static func sample(atX x: Int, y: Int, in image: CGImage, radius: Int) -> RGBA? {
        guard PixelSampleSize(rawValue: radius) != nil,
            x >= 0, y >= 0, x < image.width, y < image.height
        else { return nil }
        let x0 = x - min(radius, x), y0 = y - min(radius, y)
        let x1 = x + min(radius, image.width - x - 1) + 1
        let y1 = y + min(radius, image.height - y - 1) + 1
        guard let bytes = pixels(x0: x0, y0: y0, x1: x1, y1: y1, in: image) else { return nil }
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
        let count = bytes.count / 4
        let a = UInt8((alpha + count / 2) / count)
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        // At most 25 pixels: channel sums and their ×255 numerator remain bounded.
        func unpremultiply(_ value: Int) -> UInt8 { UInt8(min(255, (value * 255 + alpha / 2) / alpha)) }
        return RGBA(r: unpremultiply(red), g: unpremultiply(green), b: unpremultiply(blue), a: a)
    }
}
