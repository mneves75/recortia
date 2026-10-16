import CoreGraphics
import Foundation
import ImageIO

/// Builds PNG/JPEG/GIF byte streams for import and metadata tests, including deliberately
/// malformed ones. Nothing here reads from disk or the network.
public enum ContainerCrafting {
    public static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    public static func bigEndian32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// One PNG chunk with a correct CRC unless `corruptCRC` is set.
    public static func pngChunk(_ type: String, _ payload: [UInt8], corruptCRC: Bool = false) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        let crc = crc32(typeBytes + payload) ^ (corruptCRC ? 1 : 0)
        return bigEndian32(UInt32(payload.count)) + typeBytes + payload + bigEndian32(crc)
    }

    /// A zlib stream (RFC 1950) around Apple's raw DEFLATE output.
    public static func zlibStream(_ raw: Data) throws(FixtureError) -> [UInt8] {
        let deflated: Data
        do { deflated = try (raw as NSData).compressed(using: .zlib) as Data } catch {
            throw FixtureError.encodingFailed
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return [0x78, 0x9C] + [UInt8](deflated) + bigEndian32(b << 16 | a)
    }

    /// A hand-built PNG: IHDR (non-interlaced), optional IDAT payload, IEND.
    public static func handcraftedPNG(
        width: UInt32, height: UInt32, bitDepth: UInt8, colorType: UInt8, idat: [UInt8]?, corruptIDATCRC: Bool = false
    ) -> Data {
        var bytes = pngSignature
        bytes += pngChunk("IHDR", bigEndian32(width) + bigEndian32(height) + [bitDepth, colorType, 0, 0, 0])
        if let idat { bytes += pngChunk("IDAT", idat, corruptCRC: corruptIDATCRC) }
        bytes += pngChunk("IEND", [])
        return Data(bytes)
    }

    /// A valid 1-bit grayscale PNG of zero-valued pixels; tiny on disk however large it claims to be.
    public static func blankOneBitPNG(width: UInt32, height: UInt32) throws(FixtureError) -> Data {
        let rowBytes = 1 + (Int(width) + 7) / 8
        let raw = Data(count: rowBytes * Int(height))
        return handcraftedPNG(width: width, height: height, bitDepth: 1, colorType: 0, idat: try zlibStream(raw))
    }

    public static func encode(
        _ images: [CGImage], type: String, properties: [CFString: Any] = [:],
        containerProperties: [CFString: Any]? = nil
    ) throws(FixtureError) -> Data {
        let data = NSMutableData()
        guard !images.isEmpty,
            let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil)
        else { throw FixtureError.encodingFailed }
        if let containerProperties { CGImageDestinationSetProperties(destination, containerProperties as CFDictionary) }
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encodingFailed }
        return data as Data
    }

    public static func pngData(_ image: CGImage, properties: [CFString: Any] = [:]) throws(FixtureError) -> Data {
        try encode([image], type: "public.png", properties: properties)
    }

    public static func jpegData(
        _ image: CGImage, quality: Double = 0.95, properties: [CFString: Any] = [:]
    ) throws(FixtureError) -> Data {
        var merged = properties
        merged[kCGImageDestinationLossyCompressionQuality] = quality
        return try encode([image], type: "public.jpeg", properties: merged)
    }

    public static func animatedPNG(frames: [CGImage]) throws(FixtureError) -> Data {
        try encode(
            frames, type: "public.png",
            properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]],
            containerProperties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]])
    }

    public static func animatedGIF(frames: [CGImage]) throws(FixtureError) -> Data {
        try encode(
            frames, type: "com.compuserve.gif",
            properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])
    }

    /// Canary strings planted in `metadataRichJPEG`; none may appear in any export.
    public static let metadataCanaries = [
        "RECORTIA-CANARY-EXIF", "RECORTIA-CANARY-MAKE", "RECORTIA-CANARY-IPTC", "RECORTIA-CANARY-COMMENT",
        "RECORTIA-CANARY-DESCRIPTION",
    ]

    /// A JPEG carrying EXIF, TIFF, GPS, IPTC, and a COM segment full of canaries.
    public static func metadataRichJPEG(_ image: CGImage) throws(FixtureError) -> Data {
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "RECORTIA-CANARY-EXIF",
                kCGImagePropertyExifDateTimeOriginal: "2026:09:26 10:11:12",
                kCGImagePropertyExifLensMake: "RECORTIA-CANARY-EXIF",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "RECORTIA-CANARY-MAKE",
                kCGImagePropertyTIFFImageDescription: "RECORTIA-CANARY-DESCRIPTION",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 38.7223, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 9.1393, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "RECORTIA-CANARY-IPTC"],
        ]
        let jpeg = try jpegData(image, quality: 0.95, properties: properties)
        return try insertingJPEGComment("RECORTIA-CANARY-COMMENT", into: jpeg)
    }

    /// Inserts a COM segment right after SOI.
    public static func insertingJPEGComment(_ text: String, into jpeg: Data) throws(FixtureError) -> Data {
        let bytes = [UInt8](jpeg)
        let payload = Array(text.utf8)
        guard bytes.count > 2, bytes[0] == 0xFF, bytes[1] == 0xD8, payload.count + 2 <= 0xFFFF else {
            throw FixtureError.invalidArgument
        }
        let length = payload.count + 2
        let segment: [UInt8] = [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        return Data(Array(bytes[0..<2]) + segment + Array(bytes[2...]))
    }
}
