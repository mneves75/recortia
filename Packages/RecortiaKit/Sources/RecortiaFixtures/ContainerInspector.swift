import CoreGraphics
import Foundation
import ImageIO

public enum ContainerInspectionError: Error, Equatable, Sendable {
    case notPNG
    case notJPEG
    case truncated
    case badCRC(chunk: String)
    case undecodable
}

/// Lists container structure straight from raw bytes, independently of the Imaging module, so
/// export tests never trust the code under test to describe its own output.
public enum ContainerInspector {
    public struct JPEGSegment: Hashable, Sendable {
        public let marker: UInt8
        /// Printable ASCII prefix of the payload (for APPn: "JFIF", "Exif", "ICC_PROFILE", ...).
        public let identifier: String
        public let length: Int
    }

    /// PNG chunk types in file order. Verifies every CRC.
    public static func pngChunkTypes(_ data: Data) throws(ContainerInspectionError) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == ContainerCrafting.pngSignature else {
            throw ContainerInspectionError.notPNG
        }
        var types: [String] = []
        var offset = 8
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { throw ContainerInspectionError.truncated }
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            let end = offset + 12 + length
            guard end <= bytes.count else { throw ContainerInspectionError.truncated }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let stored = bytes[(end - 4)..<end].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard ContainerCrafting.crc32(bytes[(offset + 4)..<(end - 4)]) == stored else {
                throw ContainerInspectionError.badCRC(chunk: type)
            }
            types.append(type)
            offset = end
            if type == "IEND" { break }
        }
        return types
    }

    /// JPEG marker segments from SOI through SOS (the entropy-coded scan is not parsed).
    /// Also reports whether the stream ends with EOI.
    public static func jpegSegments(_ data: Data) throws(ContainerInspectionError) -> (
        segments: [JPEGSegment], endsWithEOI: Bool
    ) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw ContainerInspectionError.notJPEG }
        var segments = [JPEGSegment(marker: 0xD8, identifier: "", length: 0)]
        var offset = 2
        while true {
            guard offset + 4 <= bytes.count, bytes[offset] == 0xFF else { throw ContainerInspectionError.truncated }
            let marker = bytes[offset + 1]
            if marker == 0xFF {
                offset += 1
                continue
            }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { throw ContainerInspectionError.truncated }
            let payload = bytes[(offset + 4)..<(offset + 2 + length)]
            let identifier = String(
                decoding: payload.prefix(16).prefix { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            segments.append(JPEGSegment(marker: marker, identifier: identifier, length: length))
            offset += 2 + length
            if marker == 0xDA { break }
        }
        let endsWithEOI = bytes.count >= 2 && bytes[bytes.count - 2] == 0xFF && bytes[bytes.count - 1] == 0xD9
        return (segments, endsWithEOI)
    }

    /// Whether `needle` occurs anywhere in `data` (ASCII / UTF-8 canary search).
    public static func contains(_ needle: String, in data: Data) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    /// The item types a HEIC file's `meta` box declares (`hvc1`, `grid`, `Exif`, `mime`, ...), and
    /// every box type met on the way, read straight from the ISOBMFF structure.
    public static func heicStructure(_ data: Data) throws(ContainerInspectionError)
        -> (boxes: [String], itemTypes: [String])
    {
        let bytes = [UInt8](data)
        func uint32(_ i: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(bytes[i + $1]) } }
        func type(_ i: Int) -> String { String(decoding: bytes[i..<(i + 4)], as: UTF8.self) }
        var boxes: [String] = []
        var items: [String] = []
        func walk(_ start: Int, _ end: Int) throws(ContainerInspectionError) {
            var offset = start
            while offset + 8 <= end {
                var size = uint32(offset), header = 8
                if size == 1 {
                    guard offset + 16 <= end else { throw .truncated }
                    size = uint32(offset + 8) << 32 | uint32(offset + 12)
                    header = 16
                } else if size == 0 {
                    size = end - offset
                }
                guard size >= header, offset + size <= end else { throw .truncated }
                let name = type(offset + 4)
                boxes.append(name)
                let body = offset + header
                switch name {
                case "meta": try walk(body + 4, offset + size)
                case "iprp", "ipco", "dinf": try walk(body, offset + size)
                case "iinf": try walk(body + 4 + (bytes[body] == 0 ? 2 : 4), offset + size)
                case "infe":
                    let version = bytes[body]
                    guard version >= 2 else { break }
                    let at = body + 4 + (version == 2 ? 2 : 4) + 2
                    guard at + 4 <= offset + size else { throw .truncated }
                    items.append(type(at))
                default: break
                }
                offset += size
            }
            guard offset == end else { throw .truncated }
        }
        guard bytes.count >= 12, type(4) == "ftyp" else { throw .undecodable }
        try walk(0, bytes.count)
        return (boxes, items)
    }

    /// The keys of one nested ImageIO property dictionary (such as `{TIFF}`); empty when absent.
    public static func propertyKeys(_ data: Data, in dictionary: String) -> Set<String> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let nested = properties[dictionary] as? [String: Any]
        else { return [] }
        return Set(nested.keys)
    }

    /// Top-level ImageIO property keys plus nested dictionary names, for metadata assertions.
    public static func propertyKeys(_ data: Data) -> Set<String> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [] }
        return Set(properties.keys)
    }
}

/// Decoded pixels for comparisons, produced with ImageIO and Core Graphics only.
public struct DecodedPixels: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// Premultiplied sRGB RGBA, row 0 on top.
    public let bytes: [UInt8]

    public func pixel(x: Int, y: Int) -> ChartFixture.Color {
        let i = (y * width + x) * 4
        return ChartFixture.Color(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }
}

extension ContainerInspector {
    /// Decodes an encoded image and redraws it into premultiplied sRGB RGBA.
    public static func decodePixels(_ data: Data) throws(ContainerInspectionError) -> DecodedPixels {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ContainerInspectionError.undecodable }
        return try pixels(of: image)
    }

    /// Redraws any image into premultiplied sRGB RGBA at its own size, without interpolation.
    public static func pixels(of image: CGImage) throws(ContainerInspectionError) -> DecodedPixels {
        let width = image.width, height = image.height
        guard let context = ChartFixture.context(width: width, height: height) else {
            throw ContainerInspectionError.undecodable
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixelData = context.makeImage()?.dataProvider?.data as Data? else {
            throw ContainerInspectionError.undecodable
        }
        return DecodedPixels(width: width, height: height, bytes: [UInt8](pixelData.prefix(width * height * 4)))
    }

    /// The decoder's stored pixel bytes without any redraw, so straight-alpha RGB under alpha 0 is
    /// visible exactly as encoded. Returns nil unless the decoded layout is 8-bit RGBA straight alpha.
    public static func straightRGBAIfAvailable(_ data: Data) -> DecodedPixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last,
            let raw = image.dataProvider?.data as Data?
        else { return nil }
        let rowBytes = image.bytesPerRow
        var bytes: [UInt8] = []
        bytes.reserveCapacity(image.width * image.height * 4)
        let all = [UInt8](raw)
        for y in 0..<image.height {
            let start = y * rowBytes
            bytes += all[start..<(start + image.width * 4)]
        }
        return DecodedPixels(width: image.width, height: image.height, bytes: bytes)
    }
}
