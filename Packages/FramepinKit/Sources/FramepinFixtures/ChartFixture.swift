import CoreGraphics
import Foundation

/// Known-color and known-geometry synthetic charts. Every chart is sRGB, 8-bit, top-left addressed.
public enum ChartFixture {
    /// Straight (non-premultiplied) sRGB RGBA.
    public struct Color: Hashable, Sendable {
        public var r: UInt8
        public var g: UInt8
        public var b: UInt8
        public var a: UInt8

        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    }

    /// The color chart's cells, row-major, 4 columns × 2 rows.
    public static let chartColors: [Color] = [
        Color(0xFF, 0x00, 0x00), Color(0x00, 0xFF, 0x00), Color(0x00, 0x00, 0xFF), Color(0x1A, 0x2B, 0x3C),
        Color(0x80, 0x80, 0x80), Color(0xFE, 0xDC, 0xBA), Color(0x01, 0x02, 0x03), Color(0xFF, 0xFF, 0xFF),
    ]
    public static let chartColumns = 4
    public static let chartRows = 2

    /// Corner colors of the geometry chart: top-left, top-right, bottom-left, bottom-right.
    public static let quadrantColors: [Color] = [
        Color(220, 20, 20), Color(20, 200, 20), Color(20, 20, 220), Color(240, 200, 0),
    ]

    public static var sRGB: CGColorSpace? { CGColorSpace(name: CGColorSpace.sRGB) }

    public static func context(width: Int, height: Int) -> CGContext? {
        guard let space = sRGB else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    /// Wraps premultiplied RGBA bytes (row 0 is the top row) as an sRGB image.
    public static func image(width: Int, height: Int, premultipliedRGBA bytes: [UInt8]) throws(FixtureError) -> CGImage
    {
        try image(width: width, height: height, bytes: bytes, alpha: .premultipliedLast)
    }

    /// Wraps straight-alpha RGBA bytes, so fully transparent pixels can carry nonzero RGB.
    public static func image(width: Int, height: Int, straightRGBA bytes: [UInt8]) throws(FixtureError) -> CGImage {
        try image(width: width, height: height, bytes: bytes, alpha: .last)
    }

    private static func image(
        width: Int, height: Int, bytes: [UInt8], alpha: CGImageAlphaInfo
    ) throws(FixtureError) -> CGImage {
        guard width > 0, height > 0, bytes.count == width * height * 4, let space = sRGB,
            let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { throw FixtureError.invalidArgument }
        guard
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw FixtureError.imageUnavailable }
        return image
    }

    public static func solid(width: Int, height: Int, color: Color) throws(FixtureError) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let premultiplied = [color.r, color.g, color.b].map { UInt8((Int($0) * Int(color.a) + 127) / 255) }
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = premultiplied[0]
            bytes[i + 1] = premultiplied[1]
            bytes[i + 2] = premultiplied[2]
            bytes[i + 3] = color.a
        }
        return try image(width: width, height: height, premultipliedRGBA: bytes)
    }

    /// 4×2 cells of `chartColors`, each `cell`×`cell` pixels.
    public static func colorChart(cell: Int = 8) throws(FixtureError) -> CGImage {
        guard cell > 0 else { throw FixtureError.invalidArgument }
        let width = chartColumns * cell, height = chartRows * cell
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = chartColors[(y / cell) * chartColumns + x / cell]
                let i = (y * width + x) * 4
                bytes[i] = color.r
                bytes[i + 1] = color.g
                bytes[i + 2] = color.b
                bytes[i + 3] = 255
            }
        }
        return try image(width: width, height: height, premultipliedRGBA: bytes)
    }

    /// A one-pixel black/white checkerboard; pixel (0, 0) is black.
    public static func checkerboard(width: Int, height: Int) throws(FixtureError) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where (x + y) % 2 == 0 {
                let i = (y * width + x) * 4
                bytes[i] = 0
                bytes[i + 1] = 0
                bytes[i + 2] = 0
            }
        }
        return try image(width: width, height: height, premultipliedRGBA: bytes)
    }

    /// Four solid quadrants in `quadrantColors` order, so orientation and placement are unambiguous.
    public static func geometryChart(width: Int, height: Int) throws(FixtureError) -> CGImage {
        guard width > 1, height > 1 else { throw FixtureError.invalidArgument }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                let color = quadrantColors[index]
                let i = (y * width + x) * 4
                bytes[i] = color.r
                bytes[i + 1] = color.g
                bytes[i + 2] = color.b
                bytes[i + 3] = 255
            }
        }
        return try image(width: width, height: height, premultipliedRGBA: bytes)
    }
}
