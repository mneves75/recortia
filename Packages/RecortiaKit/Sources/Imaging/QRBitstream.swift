import Foundation

/// Recovers the encoded message bytes from a QR code's data codewords (ISO/IEC 18004 §7.4).
///
/// Vision's `BarcodeObservation.payloadData` is the raw data-codeword stream (mode indicators,
/// character counts, segment data, terminator, padding), not the message. The symbol version,
/// which sets the character-count widths, is not reported, so each of the three width classes is
/// tried; a parse must consume the stream exactly and, when several classes parse, agree or be
/// disambiguated by Vision's decoded string. When Vision reports a string, the chosen bytes must
/// decode as UTF-8 to exactly that string, so Recortia never shows a payload other scanners would
/// not. Anything else yields nil: no payload is better than wrong bytes.
package enum QRBitstream {
    private enum VersionClass: CaseIterable {
        case small  // versions 1-9
        case medium  // 10-26
        case large  // 27-40

        var numericCountBits: Int { [10, 12, 14][index] }
        var alphanumericCountBits: Int { [9, 11, 13][index] }
        var byteCountBits: Int { [8, 16, 16][index] }
        var kanjiCountBits: Int { [8, 10, 12][index] }

        private var index: Int {
            switch self {
            case .small: 0
            case .medium: 1
            case .large: 2
            }
        }
    }

    private struct Parse {
        var bytes: Data
        /// Terminator, zero fill, and alternating 0xEC/0x11 pad codewords exactly as specified.
        var hasStandardPadding: Bool
    }

    private struct BitReader {
        let data: Data
        var position = 0

        var remaining: Int { data.count * 8 - position }

        mutating func read(_ count: Int) -> Int? {
            guard count >= 0, count <= remaining else { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = data[data.startIndex + position / 8]
                value = (value << 1) | Int((byte >> (7 - UInt8(position % 8))) & 1)
                position += 1
            }
            return value
        }
    }

    private static let alphanumericTable = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)

    package static func messageBytes(fromDataCodewords codewords: Data, expectedString: String?) -> Data? {
        guard let bytes = parsedBytes(codewords, expectedString: expectedString) else { return nil }
        // UTF-8 bytes must match what Vision (and other scanners) show; only UTF-8 can become a
        // link. Other bytes (Shift JIS, an ECI charset) cannot be compared and stay binary payloads.
        if let expectedString, let text = String(validating: bytes, as: UTF8.self), text != expectedString {
            return nil
        }
        return bytes
    }

    private static func parsedBytes(_ codewords: Data, expectedString: String?) -> Data? {
        guard !codewords.isEmpty else { return nil }
        let parses = VersionClass.allCases.compactMap { parse(codewords, as: $0) }
        let standard = parses.filter(\.hasStandardPadding).map(\.bytes)
        let tiers = standard.isEmpty ? [parses.map(\.bytes)] : [standard]
        for candidates in tiers {
            let unique = candidates.reduce(into: [Data]()) { if !$0.contains($1) { $0.append($1) } }
            if unique.count == 1 { return unique[0] }
            if let expectedString {
                let matching = unique.filter { String(validating: $0, as: UTF8.self) == expectedString }
                if matching.count == 1 { return matching[0] }
            }
        }
        return nil
    }

    private static func parse(_ data: Data, as version: VersionClass) -> Parse? {
        var reader = BitReader(data: data)
        var bytes = Data()
        while reader.remaining >= 4 {
            guard let mode = reader.read(4) else { return nil }
            switch mode {
            case 0b0000:
                return Parse(bytes: bytes, hasStandardPadding: paddingIsStandard(&reader))
            case 0b0001:
                guard let count = reader.read(version.numericCountBits), decodeNumeric(count, &reader, into: &bytes)
                else { return nil }
            case 0b0010:
                guard let count = reader.read(version.alphanumericCountBits),
                    decodeAlphanumeric(count, &reader, into: &bytes)
                else { return nil }
            case 0b0100:
                guard let count = reader.read(version.byteCountBits) else { return nil }
                for _ in 0..<count {
                    guard let byte = reader.read(8) else { return nil }
                    bytes.append(UInt8(byte))
                }
            case 0b1000:
                guard let count = reader.read(version.kanjiCountBits), decodeKanji(count, &reader, into: &bytes)
                else { return nil }
            case 0b0111:
                // ECI designator (1-3 bytes). The designator selects an interpretation; the bytes
                // themselves are the payload and are kept unchanged.
                guard let first = reader.read(8) else { return nil }
                if first & 0x80 == 0 { break }
                if first & 0xC0 == 0x80 {
                    guard reader.read(8) != nil else { return nil }
                } else if first & 0xE0 == 0xC0 {
                    guard reader.read(16) != nil else { return nil }
                } else {
                    return nil
                }
            case 0b0011:
                guard reader.read(16) != nil else { return nil }  // structured append header
            case 0b0101:
                break  // FNC1 in first position
            case 0b1001:
                guard reader.read(8) != nil else { return nil }  // FNC1 application indicator
            default:
                return nil
            }
        }
        // Stream full without a terminator: the leftover (fewer than four) bits must be zero.
        let leftover = reader.remaining
        return Parse(bytes: bytes, hasStandardPadding: reader.read(leftover) == 0)
    }

    private static func paddingIsStandard(_ reader: inout BitReader) -> Bool {
        let fill = (8 - reader.position % 8) % 8
        guard reader.read(fill) == 0 else { return false }
        var expected = 0xEC
        while reader.remaining >= 8 {
            guard reader.read(8) == expected else { return false }
            expected = expected == 0xEC ? 0x11 : 0xEC
        }
        return reader.remaining == 0
    }

    private static func decodeNumeric(_ count: Int, _ reader: inout BitReader, into bytes: inout Data) -> Bool {
        var left = count
        while left > 0 {
            let digits = min(3, left)
            let bits = [0, 4, 7, 10][digits]
            guard let value = reader.read(bits), value < [1, 10, 100, 1000][digits] else { return false }
            let text = String(value)
            bytes.append(contentsOf: Array(repeating: UInt8(ascii: "0"), count: digits - text.count) + Array(text.utf8))
            left -= digits
        }
        return true
    }

    private static func decodeAlphanumeric(_ count: Int, _ reader: inout BitReader, into bytes: inout Data) -> Bool {
        var left = count
        while left >= 2 {
            guard let value = reader.read(11), value < 45 * 45 else { return false }
            bytes.append(alphanumericTable[value / 45])
            bytes.append(alphanumericTable[value % 45])
            left -= 2
        }
        if left == 1 {
            guard let value = reader.read(6), value < 45 else { return false }
            bytes.append(alphanumericTable[value])
        }
        return true
    }

    /// Kanji mode packs Shift JIS pairs into 13 bits.
    private static func decodeKanji(_ count: Int, _ reader: inout BitReader, into bytes: inout Data) -> Bool {
        for _ in 0..<count {
            guard let value = reader.read(13) else { return false }
            let packed = ((value / 0xC0) << 8) | (value % 0xC0)
            let shiftJIS = packed + (packed < 0x1F00 ? 0x8140 : 0xC140)
            guard shiftJIS <= 0xFFFF else { return false }
            bytes.append(UInt8(shiftJIS >> 8))
            bytes.append(UInt8(shiftJIS & 0xFF))
        }
        return true
    }
}
