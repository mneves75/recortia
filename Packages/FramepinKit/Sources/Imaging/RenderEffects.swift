import Domain
import Foundation

/// Cosmetic obfuscation (FR-06: never secure). Integer arithmetic on premultiplied pixels keeps
/// results identical across runs and machines, which the RED-01 byte comparisons rely on.
enum RenderEffects {
    /// Box radii for three passes approximating a Gaussian with standard deviation `sigma`.
    static func boxRadii(sigma: Double) -> [Int] {
        guard sigma.isFinite, sigma >= 0.5 else { return [] }
        let passes = 3.0
        let ideal = (12 * sigma * sigma / passes + 1).squareRoot()
        var lower = Int(ideal.rounded(.down))
        if lower % 2 == 0 { lower -= 1 }
        lower = max(1, lower)
        let upper = lower + 2
        let lowerDouble = Double(lower)
        let split =
            (12 * sigma * sigma - passes * lowerDouble * lowerDouble - 4 * passes * lowerDouble - 3 * passes)
            / (-4 * lowerDouble - 4)
        let lowerCount = Int(split.rounded())
        // Widths are odd, so width / 2 is the box radius.
        return (0..<3).map { ($0 < lowerCount ? lower : upper) / 2 }
    }

    /// Blurs the pixels inside `rect`, sampling neighbors from the surrounding raster (which the
    /// caller has already sanitized). Pixels outside `rect` are unchanged.
    static func blur(_ raster: inout RenderRaster, rect: PixelRect, radius: Double) {
        let radii = boxRadii(sigma: radius)
        guard let target = rect.clipped(to: raster.bounds), !radii.isEmpty else { return }
        let margin = radii.reduce(0, +)
        let expanded = PixelRect(
            x: target.x - margin, y: target.y - margin, width: target.width + 2 * margin,
            height: target.height + 2 * margin)
        guard let region = expanded.clipped(to: raster.bounds) else { return }
        var pixels = raster.pixels(in: region)
        for r in radii where r > 0 {
            boxPass(&pixels, width: region.width, height: region.height, radius: r, horizontal: true)
            boxPass(&pixels, width: region.width, height: region.height, radius: r, horizontal: false)
        }
        raster.replace(target, from: pixels, regionRect: region)
    }

    /// One running-sum box filter pass with edge clamping.
    private static func boxPass(_ pixels: inout [UInt8], width: Int, height: Int, radius: Int, horizontal: Bool) {
        let lines = horizontal ? height : width
        let length = horizontal ? width : height
        let window = 2 * radius + 1
        var line = [Int](repeating: 0, count: length * 4)
        for l in 0..<lines {
            func index(_ i: Int) -> Int { (horizontal ? l * width + i : i * width + l) * 4 }
            for i in 0..<length {
                let p = index(i)
                for c in 0..<4 { line[i * 4 + c] = Int(pixels[p + c]) }
            }
            for c in 0..<4 {
                var sum = 0
                for k in -radius...radius { sum += line[min(max(k, 0), length - 1) * 4 + c] }
                for i in 0..<length {
                    pixels[index(i) + c] = UInt8((sum + window / 2) / window)
                    let leaving = min(max(i - radius, 0), length - 1)
                    let entering = min(max(i + radius + 1, 0), length - 1)
                    sum += line[entering * 4 + c] - line[leaving * 4 + c]
                }
            }
        }
    }

    /// Replaces each `blockSize` square (aligned to `rect`'s origin, clipped to it) with its mean.
    static func pixelate(_ raster: inout RenderRaster, rect: PixelRect, blockSize: Int) {
        guard let target = rect.clipped(to: raster.bounds), blockSize > 1 else { return }
        var pixels = raster.pixels(in: target)
        let w = target.width
        for by in stride(from: 0, to: target.height, by: blockSize) {
            for bx in stride(from: 0, to: w, by: blockSize) {
                let x1 = min(bx + blockSize, w), y1 = min(by + blockSize, target.height)
                let count = (x1 - bx) * (y1 - by)
                var sums = [0, 0, 0, 0]
                for y in by..<y1 {
                    for x in bx..<x1 {
                        for c in 0..<4 { sums[c] += Int(pixels[(y * w + x) * 4 + c]) }
                    }
                }
                let mean = sums.map { UInt8(($0 + count / 2) / count) }
                for y in by..<y1 {
                    for x in bx..<x1 {
                        for c in 0..<4 { pixels[(y * w + x) * 4 + c] = mean[c] }
                    }
                }
            }
        }
        raster.replace(target, from: pixels, regionRect: target)
    }
}
