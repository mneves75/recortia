import CoreGraphics
import Foundation

/// One viewport frame prepared for matching: exact RGBA8 pixels (kept only while the frame's rows
/// may still be appended), a luma plane, and per-row column-block means for the coarse search.
package struct ScrollFrame: Sendable {
    package let width: Int
    package let height: Int
    /// sRGB, 8 bits per channel, premultiplied RGBA, rows top-down. Empty once demoted.
    package private(set) var pixels: [UInt8]
    package let luma: [Float]
    package let blockCount: Int
    /// `height` rows of `blockCount` mean-luma values.
    package let signature: [Float]

    package init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let pixels = Self.rgba(image) else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels

        var luma = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let p = i * 4
            luma[i] = 0.299 * Float(pixels[p]) + 0.587 * Float(pixels[p + 1]) + 0.114 * Float(pixels[p + 2])
        }
        self.luma = luma

        let blockWidth = max(4, width / 32)
        let blocks = max(1, width / blockWidth)
        var signature = [Float](repeating: 0, count: height * blocks)
        var counts = [Float](repeating: 0, count: blocks)
        for x in 0..<width { counts[min(x / blockWidth, blocks - 1)] += 1 }
        for y in 0..<height {
            for x in 0..<width { signature[y * blocks + min(x / blockWidth, blocks - 1)] += luma[y * width + x] }
            for b in 0..<blocks { signature[y * blocks + b] /= counts[b] }
        }
        self.blockCount = blocks
        self.signature = signature
    }

    /// The matching data only; the pixels have either been appended or are no longer needed.
    package func demoted() -> ScrollFrame {
        var copy = self
        copy.pixels = []
        return copy
    }

    package var byteCount: Int {
        pixels.count + luma.count * MemoryLayout<Float>.stride + signature.count * MemoryLayout<Float>.stride
    }

    package func pixelRows(_ rows: Range<Int>) -> ArraySlice<UInt8> {
        pixels[(rows.lowerBound * width * 4)..<(rows.upperBound * width * 4)]
    }

    package func lumaRows(_ rows: Range<Int>) -> ArraySlice<Float> {
        luma[(rows.lowerBound * width)..<(rows.upperBound * width)]
    }

    package func signatureRows(_ rows: Range<Int>) -> ArraySlice<Float> {
        signature[(rows.lowerBound * blockCount)..<(rows.upperBound * blockCount)]
    }

    /// Draws into a context of the canonical format, which copies sRGB RGBA8 sources exactly.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Padding in the made image's rows would shift every row index; fail closed instead.
        guard let copy = context.makeImage(), let data = copy.dataProvider?.data as Data?,
            data.count == image.width * image.height * 4
        else { return nil }
        return [UInt8](data)
    }
}
