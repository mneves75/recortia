import CoreGraphics
import Domain
import Foundation
import ImageIO

public enum ExportError: Error, Equatable, Sendable {
    case invalidOptions(ExportOptionsError)
    case render(RenderError)
    case encodingFailed
}

/// Encodes a sanitized raster as a fresh PNG or JPEG and passes it through the container
/// allowlist. ImageIO adds metadata on its own (an `eXIf` chunk in PNG, Exif APP1 and
/// Photoshop APP13 in JPEG), so the allowlist is enforced on the encoded bytes.
enum ExportEncoder {
    static func encode(_ image: CGImage, options: ExportOptions) throws(ExportError) -> Data {
        switch options.format {
        case .png:
            return try ExportContainerFilter.png(try imageIO(image, type: "public.png", properties: [:]))
        case .jpeg(let quality):
            let flattened = try flatten(image, on: options.jpegBackground)
            let encoded = try imageIO(
                flattened, type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: quality])
            return try ExportContainerFilter.jpeg(encoded)
        }
    }

    /// JPEG has no alpha: composite over the declared opaque background first (FR-07).
    static func flatten(_ image: CGImage, on background: RGBA) throws(ExportError) -> CGImage {
        guard background.isOpaque else { throw ExportError.invalidOptions(.translucentJPEGBackground) }
        return try redraw(image, on: background)
    }

    /// Redraws `image` pixel for pixel into a fresh premultiplied sRGB raster, so only what is
    /// visible survives: color under fully transparent pixels becomes zero (RED-02).
    static func redraw(_ image: CGImage) throws(ExportError) -> CGImage {
        try redraw(image, on: nil)
    }

    private static func redraw(_ image: CGImage, on background: RGBA?) throws(ExportError) -> CGImage {
        do {
            var raster = try RenderRaster(width: image.width, height: image.height)
            if let background { raster.fill(raster.bounds, with: background) }
            try raster.withContext { context in
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            guard let drawn = raster.makeImage(opaque: background != nil) else { throw ExportError.encodingFailed }
            return drawn
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.encodingFailed
        }
    }

    private static func imageIO(_ image: CGImage, type: String, properties: [CFString: Any]) throws(ExportError) -> Data
    {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
        return data as Data
    }
}

/// Byte-level container allowlist for exports (RED-02). Anything not needed to decode and color
/// the pixels is dropped: text chunks, Exif, XMP, IPTC, comments, timestamps, thumbnails.
enum ExportContainerFilter {
    static let pngChunks: Set<String> = ["IHDR", "PLTE", "tRNS", "sRGB", "iCCP", "gAMA", "cHRM", "IDAT", "IEND"]

    static func png(_ data: Data) throws(ExportError) -> Data {
        let reader = DecodeByteReader(data: data)
        guard DecodeFormat.sniff(data) == .png else { throw ExportError.encodingFailed }
        var output = Data(DecodeFormat.pngSignature)
        var offset = 8
        var types: [String] = []
        while offset + 12 <= reader.count {
            let length = Int(reader.uint32(offset))
            let end = offset + 12 + length
            guard length <= 0x7FFF_FFFF, end <= reader.count else { throw ExportError.encodingFailed }
            let type = String(decoding: reader.slice((offset + 4)..<(offset + 8)), as: UTF8.self)
            guard DecodeCRC32.checksum(reader.slice((offset + 4)..<(end - 4))) == reader.uint32(end - 4) else {
                throw ExportError.encodingFailed
            }
            if pngChunks.contains(type) {
                output.append(reader.slice(offset..<end))
                types.append(type)
            }
            offset = end
            if type == "IEND" { break }
        }
        guard types.first == "IHDR", types.last == "IEND", types.contains("IDAT") else {
            throw ExportError.encodingFailed
        }
        return output
    }

    /// Keeps SOI, JFIF APP0, ICC APP2, DQT, SOFn, DHT, DRI, and a single baseline scan through EOI.
    static func jpeg(_ data: Data) throws(ExportError) -> Data {
        let reader = DecodeByteReader(data: data)
        guard reader.count >= 4, reader.byte(0) == 0xFF, reader.byte(1) == 0xD8 else {
            throw ExportError.encodingFailed
        }
        var output = Data([0xFF, 0xD8])
        var offset = 2
        while true {
            guard offset + 4 <= reader.count, reader.byte(offset) == 0xFF else { throw ExportError.encodingFailed }
            let marker = reader.byte(offset + 1)
            let length = reader.uint16(offset + 2)
            let end = offset + 2 + length
            guard length >= 2, end <= reader.count else { throw ExportError.encodingFailed }
            let payload = reader.slice((offset + 4)..<end)
            if marker == 0xDA {
                try verifySingleScan(reader, from: end)
                output.append(reader.slice(offset..<reader.count))
                return output
            }
            if keeps(marker: marker, payload: payload) { output.append(reader.slice(offset..<end)) }
            offset = end
        }
    }

    private static func keeps(marker: UInt8, payload: Data) -> Bool {
        switch marker {
        case 0xE0: payload.starts(with: Array("JFIF\0".utf8))
        case 0xE2: payload.starts(with: Array("ICC_PROFILE\0".utf8))
        case 0xDB, 0xC4, 0xDD: true
        case 0xC0...0xCF: marker != 0xC8 && marker != 0xCC
        default: false
        }
    }

    /// After SOS only entropy-coded data, byte stuffing, restart markers, and a final EOI may
    /// follow; a second scan or any metadata marker is refused rather than passed through.
    private static func verifySingleScan(_ reader: DecodeByteReader, from start: Int) throws(ExportError) {
        guard reader.count >= start + 2, reader.byte(reader.count - 2) == 0xFF, reader.byte(reader.count - 1) == 0xD9
        else { throw ExportError.encodingFailed }
        var i = start
        let last = reader.count - 2
        while i < last {
            if reader.byte(i) == 0xFF {
                let next = reader.byte(i + 1)
                guard next == 0x00 || next == 0xFF || (0xD0...0xD7).contains(next) else {
                    throw ExportError.encodingFailed
                }
                i += next == 0xFF ? 1 : 2
            } else {
                i += 1
            }
        }
    }
}
