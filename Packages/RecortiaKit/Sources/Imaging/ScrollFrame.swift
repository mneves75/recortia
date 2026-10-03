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
    /// `height` rows of `blockCount` blocks of mean R, G, B (three values each). Matching uses luma
    /// alone, which cannot tell two colors of equal luminance apart; this bounded signature keeps
    /// that evidence after the pixels are demoted, so stationarity can require colors to agree.
    package let colorSignature: [Float]

    /// Column-block layout shared by the luma and color signatures.
    private static func blockLayout(width: Int) -> (blockWidth: Int, blocks: Int) {
        let blockWidth = max(4, width / 32)
        return (blockWidth, max(1, width / blockWidth))
    }

    /// Bytes `init(image:)` holds at its peak for a frame of this size: the RGBA pixels, the luma
    /// plane and both signatures. The conversion's transient copy of the pixels is no larger than
    /// the pixels plus luma it precedes. `nil` when the arithmetic overflows.
    package static func plannedByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (cells, cellsOverflow) = height.multipliedReportingOverflow(by: blockLayout(width: width).blocks)
        guard !areaOverflow, !cellsOverflow else { return nil }
        let float = MemoryLayout<Float>.stride
        // Per pixel: 4 RGBA bytes plus one Float of luma. Per cell: one luma and three color means.
        let (pixelBytes, pixelOverflow) = area.multipliedReportingOverflow(by: 4 + float)
        let (cellBytes, cellOverflow) = cells.multipliedReportingOverflow(by: 4 * float)
        guard !pixelOverflow, !cellOverflow else { return nil }
        let (total, totalOverflow) = pixelBytes.addingReportingOverflow(cellBytes)
        return totalOverflow ? nil : total
    }

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

        let (blockWidth, blocks) = Self.blockLayout(width: width)
        var signature = [Float](repeating: 0, count: height * blocks)
        var color = [Float](repeating: 0, count: height * blocks * 3)
        var counts = [Float](repeating: 0, count: blocks)
        for x in 0..<width { counts[min(x / blockWidth, blocks - 1)] += 1 }
        for y in 0..<height {
            for x in 0..<width {
                let cell = y * blocks + min(x / blockWidth, blocks - 1)
                signature[cell] += luma[y * width + x]
                let p = (y * width + x) * 4
                color[cell * 3] += Float(pixels[p])
                color[cell * 3 + 1] += Float(pixels[p + 1])
                color[cell * 3 + 2] += Float(pixels[p + 2])
            }
            for b in 0..<blocks {
                let cell = y * blocks + b
                signature[cell] /= counts[b]
                for c in 0..<3 { color[cell * 3 + c] /= counts[b] }
            }
        }
        self.blockCount = blocks
        self.signature = signature
        self.colorSignature = color
    }

    /// Share of (row, block) cells whose mean color differs from `other`'s by at least `tolerance`
    /// in any channel. Luma-blind comparison cannot see this: two colors of equal luminance match.
    package func colorChangedFraction(comparedTo other: ScrollFrame, tolerance: Float) -> Double {
        guard width == other.width, height == other.height, colorSignature.count == other.colorSignature.count,
            !colorSignature.isEmpty
        else { return 1 }
        var changed = 0
        let cells = colorSignature.count / 3
        for cell in 0..<cells {
            let i = cell * 3
            if abs(colorSignature[i] - other.colorSignature[i]) >= tolerance
                || abs(colorSignature[i + 1] - other.colorSignature[i + 1]) >= tolerance
                || abs(colorSignature[i + 2] - other.colorSignature[i + 2]) >= tolerance
            {
                changed += 1
            }
        }
        return Double(changed) / Double(cells)
    }

    /// The matching data only; the pixels have either been appended or are no longer needed.
    package func demoted() -> ScrollFrame {
        var copy = self
        copy.pixels = []
        return copy
    }

    package var byteCount: Int {
        pixels.count + (luma.count + signature.count + colorSignature.count) * MemoryLayout<Float>.stride
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
