import CoreGraphics
import Domain
import Foundation

/// The canonical working raster: sRGB, 8 bits per channel, premultiplied RGBA, tightly packed,
/// row 0 on top. Every render stage and the decoder write through this one type.
struct RenderRaster {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    static var colorSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.sRGB) }

    let width: Int
    let height: Int
    private(set) var bytes: Data

    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }
    var pixelCount: Int { width * height }

    /// `width × height × 4`, or nil for non-positive sides or overflow.
    static func byteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (total, totalOverflow) = area.multipliedReportingOverflow(by: 4)
        return areaOverflow || totalOverflow ? nil : total
    }

    init(width: Int, height: Int) throws(RenderError) {
        guard let count = Self.byteCount(width: width, height: height) else { throw RenderError.invalidGeometry }
        self.width = width
        self.height = height
        bytes = Data(count: count)
    }

    /// An exact copy of `image` converted to the canonical format.
    init(image: CGImage) throws(RenderError) {
        try self.init(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        try withContext { context in
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: rect)
        }
    }

    /// Runs `body` with a bitmap context over this raster (Core Graphics default: y up, pixel units).
    mutating func withContext(_ body: (CGContext) -> Void) throws(RenderError) {
        let (w, h) = (width, height)
        var created = false
        bytes.withUnsafeMutableBytes { buffer in
            // Invariant: the context points into `bytes` storage and must not outlive this closure.
            guard let base = buffer.baseAddress, let space = Self.colorSpace,
                let context = CGContext(
                    data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                    bitmapInfo: Self.bitmapInfo)
            else { return }
            created = true
            body(context)
        }
        guard created else { throw RenderError.allocationFailed }
    }

    /// Like `withContext`, with a top-left origin and y growing downward.
    mutating func withTopLeftContext(_ body: (CGContext) -> Void) throws(RenderError) {
        let h = CGFloat(height)
        try withContext { context in
            context.translateBy(x: 0, y: h)
            context.scaleBy(x: 1, y: -1)
            body(context)
        }
    }

    /// Writes `color` into every pixel of `rect` (clipped to the raster). No blending, no
    /// antialiasing: an opaque color replaces the pixels exactly.
    mutating func fill(_ rect: PixelRect, with color: RGBA) {
        guard let clipped = rect.clipped(to: bounds) else { return }
        let a = Int(color.a)
        let pixel = [color.r, color.g, color.b].map { UInt8((Int($0) * a + 127) / 255) } + [color.a]
        let rowBytes = width * 4
        bytes.withUnsafeMutableBytes { buffer in
            // Invariant: `clipped` lies inside the raster, so every index is below width × height × 4.
            for y in clipped.y..<clipped.maxY {
                var i = y * rowBytes + clipped.x * 4
                for _ in 0..<clipped.width {
                    buffer[i] = pixel[0]
                    buffer[i + 1] = pixel[1]
                    buffer[i + 2] = pixel[2]
                    buffer[i + 3] = pixel[3]
                    i += 4
                }
            }
        }
    }

    /// Fully transparent pixels carry RGB 0, so no color survives under alpha 0 (RED-02).
    mutating func normalizeTransparentPixels() {
        bytes.withUnsafeMutableBytes { buffer in
            var i = 0
            while i + 3 < buffer.count {
                if buffer[i + 3] == 0 {
                    buffer[i] = 0
                    buffer[i + 1] = 0
                    buffer[i + 2] = 0
                }
                i += 4
            }
        }
    }

    /// Copies the pixels of `rect` (which must lie inside the raster), row-major.
    func pixels(in rect: PixelRect) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        let rowBytes = width * 4, outRow = rect.width * 4
        bytes.withUnsafeBytes { buffer in
            for row in 0..<rect.height {
                let source = (rect.y + row) * rowBytes + rect.x * 4
                for i in 0..<outRow { out[row * outRow + i] = buffer[source + i] }
            }
        }
        return out
    }

    /// Writes `region` (row-major pixels of `regionRect`) back, only inside `target`.
    mutating func replace(_ target: PixelRect, from region: [UInt8], regionRect: PixelRect) {
        guard let clipped = target.clipped(to: bounds)?.clipped(to: regionRect) else { return }
        let rowBytes = width * 4, regionRow = regionRect.width * 4
        bytes.withUnsafeMutableBytes { buffer in
            for y in clipped.y..<clipped.maxY {
                let destination = y * rowBytes + clipped.x * 4
                let source = (y - regionRect.y) * regionRow + (clipped.x - regionRect.x) * 4
                for i in 0..<(clipped.width * 4) { buffer[destination + i] = region[source + i] }
            }
        }
    }

    /// An immutable image sharing this raster's current bytes (copy-on-write protects it).
    func makeImage(opaque: Bool = false) -> CGImage? {
        guard let space = Self.colorSpace, let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: alpha | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension PixelRect {
    func clipped(to other: PixelRect) -> PixelRect? {
        let x0 = Swift.max(x, other.x), y0 = Swift.max(y, other.y)
        let x1 = Swift.min(maxX, other.maxX), y1 = Swift.min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The smallest pixel rectangle covering `rect` (floor the minimum, ceil the maximum),
    /// clipped to `bounds`. Clamping happens in floating point, so huge values cannot trap.
    static func outward(_ rect: CGRect, within bounds: PixelRect) -> PixelRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        let x0 = Swift.max(Double(bounds.x), Double(rect.minX).rounded(.down))
        let y0 = Swift.max(Double(bounds.y), Double(rect.minY).rounded(.down))
        let x1 = Swift.min(Double(bounds.maxX), Double(rect.maxX).rounded(.up))
        let y1 = Swift.min(Double(bounds.maxY), Double(rect.maxY).rounded(.up))
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0))
    }
}
