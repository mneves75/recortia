import Compression
import Domain
import Foundation

/// Container formats accepted in v1 (FR-03).
enum DecodeFormat: Equatable {
    case png
    case jpeg

    var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        }
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Identifies the format from magic bytes alone.
    static func sniff(_ data: Data) -> DecodeFormat? {
        if data.count >= 8, data.prefix(8).elementsEqual(pngSignature) { return .png }
        if data.count >= 3, data.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]) { return .jpeg }
        return nil
    }
}

/// Dimensions and frame facts read from container headers, before any pixel decode.
struct DecodeHeader: Equatable {
    var pixelSize: PixelSize
    var isAnimated = false
}

/// Bounds-checked big-endian reads over `Data` with any start index.
struct DecodeByteReader {
    let data: Data

    var count: Int { data.count }

    func byte(_ offset: Int) -> UInt8 { data[data.startIndex + offset] }

    func uint16(_ offset: Int) -> Int { Int(byte(offset)) << 8 | Int(byte(offset + 1)) }

    func uint32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(byte(offset + $1)) }
    }

    func slice(_ range: Range<Int>) -> Data {
        data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
    }
}

enum DecodeCRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// PNG structure checks. ImageIO silently decodes damaged PNGs (bad CRCs, broken or truncated
/// deflate streams) into blank pixels, so the decoder validates the container itself.
enum DecodePNGStructure {
    struct Layout {
        var header: DecodeHeader
        var bitDepth: Int
        var colorType: Int
        var interlaced: Bool
        /// Payload ranges of the IDAT chunks, in order.
        var imageData: [Range<Int>]
    }

    private static let validDepths: [Int: Set<Int>] = [
        0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16],
    ]
    private static let channels: [Int: Int] = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4]

    /// Parses IHDR and enforces the dimension limits before walking the remaining chunks.
    static func layout(_ data: Data) throws(ImportError) -> Layout {
        let reader = DecodeByteReader(data: data)
        guard reader.count >= 8 + 25, String(decoding: reader.slice(12..<16), as: UTF8.self) == "IHDR",
            reader.uint32(8) == 13
        else { throw ImportError.corrupt }
        try verifyCRC(reader, chunkAt: 8, length: 13)
        let width = reader.uint32(16), height = reader.uint32(20)
        guard width > 0, height > 0, width <= 0x7FFF_FFFF, height <= 0x7FFF_FFFF else {
            throw ImportError.invalidDimensions
        }
        let size = PixelSize(width: Int(width), height: Int(height))
        try ImageDecoder.checkDimensions(size)

        let bitDepth = Int(reader.byte(24)), colorType = Int(reader.byte(25))
        guard validDepths[colorType]?.contains(bitDepth) == true, reader.byte(26) == 0, reader.byte(27) == 0,
            reader.byte(28) <= 1
        else { throw ImportError.corrupt }

        var layout = Layout(
            header: DecodeHeader(pixelSize: size), bitDepth: bitDepth, colorType: colorType,
            interlaced: reader.byte(28) == 1, imageData: [])
        var offset = 8 + 25
        var sawPalette = false, sawEnd = false, idatClosed = false
        while offset < reader.count {
            guard offset + 12 <= reader.count else { throw ImportError.corrupt }
            let length = Int(reader.uint32(offset))
            let (end, overflow) = (offset + 12).addingReportingOverflow(length)
            guard length <= 0x7FFF_FFFF, !overflow, end <= reader.count else { throw ImportError.corrupt }
            try verifyCRC(reader, chunkAt: offset, length: length)
            let type = String(decoding: reader.slice((offset + 4)..<(offset + 8)), as: UTF8.self)
            switch type {
            case "IDAT":
                guard !idatClosed else { throw ImportError.corrupt }
                layout.imageData.append((offset + 8)..<(offset + 8 + length))
            case "acTL", "fcTL", "fdAT":
                layout.header.isAnimated = true
            case "PLTE":
                sawPalette = true
            case "IHDR":
                throw ImportError.corrupt
            default:
                break
            }
            if !layout.imageData.isEmpty, type != "IDAT" { idatClosed = true }
            offset = end
            if type == "IEND" {
                sawEnd = true
                break  // bytes after IEND are ignored, never decoded
            }
        }
        guard sawEnd, !layout.imageData.isEmpty, colorType != 3 || sawPalette else { throw ImportError.corrupt }
        return layout
    }

    private static func verifyCRC(_ reader: DecodeByteReader, chunkAt offset: Int, length: Int) throws(ImportError) {
        let stored = reader.uint32(offset + 8 + length)
        guard DecodeCRC32.checksum(reader.slice((offset + 4)..<(offset + 8 + length))) == stored else {
            throw ImportError.corrupt
        }
    }

    /// Filtered scanline bytes the image data must inflate to (Adam7 passes when interlaced).
    static func expectedInflatedSize(_ layout: Layout) -> Int? {
        guard let channelCount = channels[layout.colorType] else { return nil }
        let bitsPerPixel = channelCount * layout.bitDepth
        let size = layout.header.pixelSize
        func passBytes(width: Int, height: Int) -> Int? {
            guard width > 0, height > 0 else { return 0 }
            let (bits, overflow) = width.multipliedReportingOverflow(by: bitsPerPixel)
            guard !overflow else { return nil }
            let (total, overflow2) = height.multipliedReportingOverflow(by: 1 + (bits + 7) / 8)
            return overflow2 ? nil : total
        }
        guard layout.interlaced else { return passBytes(width: size.width, height: size.height) }
        let passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        var total = 0
        for (x0, y0, dx, dy) in passes {
            let w = size.width > x0 ? (size.width - x0 + dx - 1) / dx : 0
            let h = size.height > y0 ? (size.height - y0 + dy - 1) / dy : 0
            guard let bytes = passBytes(width: w, height: h) else { return nil }
            total += bytes
        }
        return total
    }

    private struct InflationLimit: Error {}

    /// Inflates the zlib stream in bounded pieces, checking its header, exact output size, and
    /// Adler-32 without holding the inflated data. A stream that inflates past the expected size
    /// (an inflation bomb) is abandoned as soon as it crosses the limit.
    static func verifyImageData(_ data: Data, layout: Layout) throws(ImportError) {
        guard let expected = expectedInflatedSize(layout) else { throw ImportError.invalidDimensions }
        let reader = DecodeByteReader(data: data)
        let total = layout.imageData.reduce(0) { $0 + $1.count }
        guard total >= 6 else { throw ImportError.corrupt }

        func logicalByte(_ index: Int) -> UInt8 {
            var remaining = index
            for range in layout.imageData {
                if remaining < range.count { return reader.byte(range.lowerBound + remaining) }
                remaining -= range.count
            }
            return 0
        }
        let cmf = Int(logicalByte(0)), flg = Int(logicalByte(1))
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else {
            throw ImportError.corrupt
        }
        let storedAdler = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(logicalByte(total - 4 + $1)) }

        var produced = 0
        var adlerA: UInt32 = 1, adlerB: UInt32 = 0
        do {
            let filter = try OutputFilter(.decompress, using: .zlib, bufferCapacity: 64 * 1024) { chunk in
                guard let chunk else { return }
                produced += chunk.count
                if produced > expected { throw InflationLimit() }
                for byte in chunk {
                    adlerA = (adlerA + UInt32(byte)) % 65521
                    adlerB = (adlerB + adlerA) % 65521
                }
            }
            // Feed the raw DEFLATE body: skip the 2-byte zlib header, hold back the Adler-32 trailer.
            var logical = 0
            let bodyEnd = total - 4
            for range in layout.imageData {
                let start = max(logical, 2), end = min(logical + range.count, bodyEnd)
                var cursor = start
                while cursor < end {
                    let next = min(end, cursor + 64 * 1024)
                    let local = (range.lowerBound + cursor - logical)..<(range.lowerBound + next - logical)
                    try filter.write(reader.slice(local))
                    cursor = next
                }
                logical += range.count
            }
            try filter.finalize()
        } catch {
            throw ImportError.corrupt
        }
        guard produced == expected, (adlerB << 16 | adlerA) == storedAdler else { throw ImportError.corrupt }
    }
}

/// JPEG header parsing: dimensions come from the first SOFn segment, before any decode.
enum DecodeJPEGStructure {
    static func header(_ data: Data) throws(ImportError) -> DecodeHeader {
        let reader = DecodeByteReader(data: data)
        var offset = 2
        while offset + 4 <= reader.count {
            guard reader.byte(offset) == 0xFF else { throw ImportError.corrupt }
            let marker = reader.byte(offset + 1)
            if marker == 0xFF {
                offset += 1
                continue
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                offset += 2
                continue
            }
            let length = reader.uint16(offset + 2)
            guard length >= 2, offset + 2 + length <= reader.count else { throw ImportError.corrupt }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard length >= 8 else { throw ImportError.corrupt }
                let height = reader.uint16(offset + 5), width = reader.uint16(offset + 7)
                guard width > 0, height > 0 else { throw ImportError.invalidDimensions }
                let size = PixelSize(width: width, height: height)
                try ImageDecoder.checkDimensions(size)
                return DecodeHeader(pixelSize: size)
            }
            if marker == 0xDA || marker == 0xD9 { break }
            offset += 2 + length
        }
        throw ImportError.corrupt
    }
}
