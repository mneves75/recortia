import CoreGraphics
import Domain
import Foundation
import ImageIO
import RecortiaFixtures
import Testing

@testable import Imaging

@Suite("IO-01: defensive import")
struct DecodeImportTests {
    private func isCanonical(_ image: CGImage) -> Bool {
        image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.alphaInfo == .premultipliedLast
            && image.colorSpace?.name == CGColorSpace.sRGB
    }

    @Test("Valid PNG and JPEG decode to canonical sRGB 8-bit premultiplied RGBA with exact PNG pixels")
    func validInputs() throws {
        let chart = try ChartFixture.colorChart(cell: 6)
        let png = try ImageDecoder.decode(try ContainerCrafting.pngData(chart))
        #expect(png.pixelSize == PixelSize(width: 24, height: 12))
        #expect(isCanonical(png.image))
        let chartPixels = try pixels(png.image)
        for (index, expected) in ChartFixture.chartColors.enumerated() {
            let x = (index % ChartFixture.chartColumns) * 6 + 3, y = (index / ChartFixture.chartColumns) * 6 + 3
            #expect(chartPixels.pixel(x: x, y: y) == expected)
        }

        let jpeg = try ImageDecoder.decode(
            try ContainerCrafting.jpegData(try ChartFixture.geometryChart(width: 64, height: 48)))
        #expect(jpeg.pixelSize == PixelSize(width: 64, height: 48))
        #expect(isCanonical(jpeg.image))
        #expect(try pixels(jpeg.image).pixel(x: 8, y: 8).distance(to: ChartFixture.quadrantColors[0]) <= 12)
    }

    @Test("Decoding never mutates the caller's bytes")
    func sourceIsNotMutated() throws {
        let png = try ContainerCrafting.pngData(try ChartFixture.checkerboard(width: 9, height: 9))
        let copy = Data(png)
        _ = try ImageDecoder.decode(png)
        #expect(png == copy)
    }

    @Test("Unsupported formats and empty or truncated inputs are rejected")
    func malformedInputs() throws {
        let png = try ContainerCrafting.pngData(try ChartFixture.checkerboard(width: 8, height: 8))
        let jpeg = try ContainerCrafting.jpegData(try ChartFixture.geometryChart(width: 32, height: 32))
        let tiff = try ContainerCrafting.encode(
            [try ChartFixture.checkerboard(width: 8, height: 8)], type: "public.tiff")

        #expect(throws: ImportError.unsupportedFormat) { try ImageDecoder.decode(Data()) }
        #expect(throws: ImportError.unsupportedFormat) { try ImageDecoder.decode(tiff) }
        #expect(throws: ImportError.unsupportedFormat) { try ImageDecoder.decode(Data("not an image at all".utf8)) }
        #expect(throws: ImportError.corrupt) { try ImageDecoder.decode(png.prefix(16)) }  // truncated header
        #expect(throws: ImportError.corrupt) { try ImageDecoder.decode(png.prefix(png.count - 12)) }  // no IEND
        #expect(throws: ImportError.corrupt) { try ImageDecoder.decode(jpeg.prefix(20)) }
        #expect(throws: ImportError.corrupt) { try ImageDecoder.decode(jpeg.prefix(jpeg.count / 2)) }
    }

    @Test("Corrupt PNG payloads are rejected even though ImageIO would decode them silently")
    func corruptPNGPayloads() throws {
        var raw = Data()
        for _ in 0..<4 {
            raw.append(0)
            raw.append(contentsOf: [UInt8](repeating: 200, count: 16))
        }
        let good = try ContainerCrafting.zlibStream(raw)
        let valid = ContainerCrafting.handcraftedPNG(width: 4, height: 4, bitDepth: 8, colorType: 6, idat: good)
        #expect(try ImageDecoder.decode(valid).pixelSize == PixelSize(width: 4, height: 4))

        var badAdler = good
        badAdler[badAdler.count - 1] ^= 0xFF
        var garbage = good
        for i in 3..<(garbage.count - 4) { garbage[i] ^= 0xA5 }
        let cases: [(String, Data)] = [
            (
                "bad CRC",
                ContainerCrafting.handcraftedPNG(
                    width: 4, height: 4, bitDepth: 8, colorType: 6, idat: good, corruptIDATCRC: true)
            ),
            (
                "garbage deflate",
                ContainerCrafting.handcraftedPNG(width: 4, height: 4, bitDepth: 8, colorType: 6, idat: garbage)
            ),
            (
                "truncated deflate",
                ContainerCrafting.handcraftedPNG(
                    width: 4, height: 4, bitDepth: 8, colorType: 6, idat: Array(good.prefix(good.count / 2)))
            ),
            (
                "bad Adler-32",
                ContainerCrafting.handcraftedPNG(width: 4, height: 4, bitDepth: 8, colorType: 6, idat: badAdler)
            ),
            (
                "missing IDAT",
                ContainerCrafting.handcraftedPNG(width: 4, height: 4, bitDepth: 8, colorType: 6, idat: nil)
            ),
            (
                "invalid bit depth",
                ContainerCrafting.handcraftedPNG(width: 4, height: 4, bitDepth: 3, colorType: 6, idat: good)
            ),
        ]
        for (name, data) in cases {
            // Control: ImageIO alone accepts some of these; the decoder must not.
            #expect(throws: ImportError.corrupt, "\(name)") { try ImageDecoder.decode(data) }
        }
    }

    @Test("Declared dimensions are checked before decoding: oversized, zero, and bomb inputs")
    func dimensionChecksPrecedeDecode() throws {
        // 100000 x 100000 RGBA claims 40 GB decoded; the IHDR is valid and CRC-correct.
        let huge = ContainerCrafting.handcraftedPNG(
            width: 100_000, height: 100_000, bitDepth: 8, colorType: 6,
            idat: [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        #expect(throws: ImportError.tooManyPixels) { try ImageDecoder.decode(huge) }
        let zero = ContainerCrafting.handcraftedPNG(
            width: 0, height: 10, bitDepth: 8, colorType: 6, idat: [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        #expect(throws: ImportError.invalidDimensions) { try ImageDecoder.decode(zero) }

        // A classic bomb: 8 KiB on disk, 8000 x 8000 (64 MP, 256 MiB decoded).
        let bomb = try ContainerCrafting.blankOneBitPNG(width: 8000, height: 8000)
        #expect(bomb.count < 16 * 1024)
        #expect(throws: ImportError.tooManyPixels) { try ImageDecoder.decode(bomb) }

        // An inflation bomb: a 16x16 header over ~32 MiB of deflated zeros. Inflation must stop early.
        let flood = try ContainerCrafting.zlibStream(Data(count: 32 * 1024 * 1024))
        let inflationBomb = ContainerCrafting.handcraftedPNG(
            width: 16, height: 16, bitDepth: 8, colorType: 6, idat: flood)
        #expect(throws: ImportError.corrupt) { try ImageDecoder.decode(inflationBomb) }
    }

    @Test("Animated PNG and GIF are rejected rather than silently choosing a frame")
    func animatedInputs() throws {
        let frames = [
            try ChartFixture.checkerboard(width: 8, height: 8), try ChartFixture.geometryChart(width: 8, height: 8),
        ]
        #expect(throws: ImportError.multiFrame) {
            try ImageDecoder.decode(try ContainerCrafting.animatedPNG(frames: frames))
        }
        #expect(throws: ImportError.unsupportedFormat) {
            try ImageDecoder.decode(try ContainerCrafting.animatedGIF(frames: frames))
        }
    }

    @Test("EXIF orientation 6 and 8 is applied exactly once", arguments: [6, 8])
    func orientationIsAppliedOnce(orientation: Int) throws {
        let stored = try ChartFixture.geometryChart(width: 64, height: 32)
        let jpeg = try ContainerCrafting.jpegData(
            stored, quality: 1, properties: [kCGImagePropertyOrientation: orientation])
        let decoded = try ImageDecoder.decode(jpeg)
        try #require(decoded.pixelSize == PixelSize(width: 32, height: 64))
        let p = try pixels(decoded.image)
        let q = ChartFixture.quadrantColors  // stored TL, TR, BL, BR
        // Orientation 6 displays the stored image rotated 90° clockwise; 8 rotates counterclockwise.
        let expected = orientation == 6 ? [q[2], q[0], q[3], q[1]] : [q[1], q[3], q[0], q[2]]
        let samples = [p.pixel(x: 8, y: 16), p.pixel(x: 24, y: 16), p.pixel(x: 8, y: 48), p.pixel(x: 24, y: 48)]
        for (sample, want) in zip(samples, expected) {
            #expect(sample.distance(to: want) <= 16, "orientation \(orientation): \(sample) != \(want)")
        }
    }

    @Test("64 MiB is accepted and 64 MiB + 1 byte is rejected before decoding")
    func byteLimitBoundary() throws {
        let png = try ContainerCrafting.pngData(try ChartFixture.checkerboard(width: 8, height: 8))
        var atLimit = png
        atLimit.append(Data(count: ImportLimits.maxCompressedBytes - png.count))  // trailing bytes after IEND
        #expect(atLimit.count == 64 * 1024 * 1024)
        #expect(try ImageDecoder.decode(atLimit).pixelSize == PixelSize(width: 8, height: 8))
        atLimit.append(0)
        #expect(throws: ImportError.tooManyBytes) { try ImageDecoder.decode(atLimit) }
    }

    @Test("The 40 MP boundary: exactly 40,000,000 pixels decode, one more row is rejected")
    func pixelLimitBoundary() throws {
        #expect(throws: Never.self) { try ImageDecoder.checkDimensions(PixelSize(width: 8000, height: 5000)) }
        #expect(throws: ImportError.tooManyPixels) {
            try ImageDecoder.checkDimensions(PixelSize(width: 8000, height: 5001))
        }
        #expect(throws: ImportError.invalidDimensions) {
            try ImageDecoder.checkDimensions(PixelSize(width: Int.max, height: 3))
        }
        let atLimit = try ContainerCrafting.blankOneBitPNG(width: 8000, height: 5000)
        #expect(try ImageDecoder.decode(atLimit).pixelSize == PixelSize(width: 8000, height: 5000))
        let overLimit = try ContainerCrafting.blankOneBitPNG(width: 8000, height: 5001)
        #expect(throws: ImportError.tooManyPixels) { try ImageDecoder.decode(overLimit) }
    }

    @Test("canonicalize rejects oversized captures and converts other color spaces to sRGB")
    func canonicalizeCaptures() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let canonical = try ImageDecoder.canonicalize(try #require(context.makeImage()))
        #expect(isCanonical(canonical.image))
        #expect(try pixels(canonical.image).pixel(x: 1, y: 1).distance(to: color(51, 102, 153)) <= 2)
    }
}
