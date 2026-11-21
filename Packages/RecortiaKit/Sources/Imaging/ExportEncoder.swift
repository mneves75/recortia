import CoreGraphics
import Domain
import Foundation
import ImageIO

public enum ExportError: Error, Equatable, Sendable {
    case invalidOptions(ExportOptionsError)
    case render(RenderError)
    case encodingFailed
}

/// What this Mac's ImageIO can encode, asked once per process.
public enum ExportCapabilities {
    /// Whether HEIC export is offered: Macs without an HEVC encoder leave it out of
    /// `CGImageDestinationCopyTypeIdentifiers`.
    public static let encodesHEIC: Bool = {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(ExportFormat.heic(quality: 1).utTypeIdentifier)
    }()
}

/// Encodes a sanitized raster as a fresh PNG, JPEG or HEIC and passes it through the container
/// allowlist. ImageIO adds metadata on its own (an `eXIf` chunk in PNG, Exif APP1 and
/// Photoshop APP13 in JPEG), so the allowlist is enforced on the encoded bytes.
enum ExportEncoder {
    /// The bytes and the format they are in: `options.format`, or what Automatic chose.
    static func encodeResolvingFormat(_ image: CGImage, options: ExportOptions) throws(ExportError)
        -> (bytes: Data, format: ExportFormat)
    {
        guard options.automaticFormat else { return (try encode(image, options: options), options.format) }
        var fixed = options
        fixed.automaticFormat = false
        fixed.format = .png
        let png = try encode(image, options: fixed)
        // Under the floor no JPEG can win, so none is encoded.
        guard png.count > AutomaticFormatRule.minimumPNGByteCount, try !hasTransparency(image) else {
            return (png, .png)
        }
        fixed.format = .jpeg(quality: AutomaticFormatRule.jpegQuality)
        let jpeg = try encode(image, options: fixed)
        return AutomaticFormatRule.keepsJPEG(pngByteCount: png.count, jpegByteCount: jpeg.count)
            ? (jpeg, fixed.format) : (png, .png)
    }

    static func encode(_ image: CGImage, options: ExportOptions) throws(ExportError) -> Data {
        switch options.format {
        case .png:
            return try ExportContainerFilter.png(try imageIO(image, type: "public.png", properties: [:]))
        case .jpeg(let quality):
            let flattened = try flatten(image, on: options.jpegBackground)
            let encoded = try imageIO(
                flattened, type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: quality])
            return try ExportContainerFilter.jpeg(encoded)
        case .heic(let quality):
            let flattened = try flatten(image, on: options.jpegBackground)
            let encoded = try imageIO(
                flattened, type: "public.heic", properties: [kCGImageDestinationLossyCompressionQuality: quality])
            return try ExportContainerFilter.heic(encoded)
        }
    }

    /// Whether any pixel is not fully opaque; an image without an alpha channel never is.
    static func hasTransparency(_ image: CGImage) throws(ExportError) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        do {
            return !(try RenderRaster(image: image)).isOpaque
        } catch {
            throw ExportError.encodingFailed
        }
    }

    /// JPEG and HEIC exports have no alpha: composite over the declared opaque background first (FR-07).
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

/// Automatic format (FR-07): a JPEG replaces the PNG only when the PNG is over 0.5 MB and more
/// than 4× the JPEG, or over 2 MB and more than 2× the JPEG. Sizes are decimal megabytes.
enum AutomaticFormatRule {
    static let jpegQuality = 0.92
    static let minimumPNGByteCount = 500_000

    static func keepsJPEG(pngByteCount png: Int, jpegByteCount jpeg: Int) -> Bool {
        (png > minimumPNGByteCount && png > 4 * jpeg) || (png > 2_000_000 && png > 2 * jpeg)
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

    /// ISOBMFF boxes a HEIC export may hold: the file, its `meta` box, and the item properties.
    static let heicFileBoxes: Set<String> = ["ftyp", "meta", "mdat"]
    static let heicMetaBoxes: Set<String> = ["hdlr", "dinf", "pitm", "iinf", "iref", "iprp", "iloc", "idat"]
    static let heicPropertyBoxes: Set<String> = [
        "hvcC", "ispe", "colr", "pixi", "irot", "imir", "clap", "clli", "mdcv", "auxC",
    ]
    /// Image items only: no `Exif`, `mime` (XMP) or `uri ` item can carry metadata.
    static let heicItemTypes: Set<String> = ["hvc1", "grid"]

    /// ImageIO writes no metadata item for an image without properties, so nothing is stripped:
    /// the bytes are checked against the allowlists and refused, never passed, when anything else
    /// appears. Rewriting ISOBMFF would mean recomputing every item offset in `iloc`.
    static func heic(_ data: Data) throws(ExportError) -> Data {
        let reader = DecodeByteReader(data: data)
        let file = try isoBoxes(reader, in: 0..<reader.count)
        guard file.first?.type == "ftyp", Set(file.map(\.type)).isSubset(of: heicFileBoxes),
            file.filter({ $0.type == "meta" }).count == 1, file.contains(where: { $0.type == "mdat" }),
            let meta = file.first(where: { $0.type == "meta" }), meta.body.count >= 4
        else { throw ExportError.encodingFailed }
        // `meta` is a full box: a version and flags word precede its children.
        let children = try isoBoxes(reader, in: (meta.body.lowerBound + 4)..<meta.body.upperBound)
        guard Set(children.map(\.type)).isSubset(of: heicMetaBoxes),
            let iinf = children.first(where: { $0.type == "iinf" }),
            let iprp = children.first(where: { $0.type == "iprp" }),
            let pitm = children.first(where: { $0.type == "pitm" })
        else { throw ExportError.encodingFailed }
        let items = try checkItems(reader, iinf: iinf.body)
        try checkPicture(
            reader, items: items, primary: try primaryItem(reader, pitm: pitm.body),
            iref: children.first(where: { $0.type == "iref" })?.body)
        for container in try isoBoxes(reader, in: iprp.body) {
            switch container.type {
            case "ipco":
                let properties = try isoBoxes(reader, in: container.body)
                guard Set(properties.map(\.type)).isSubset(of: heicPropertyBoxes) else {
                    throw ExportError.encodingFailed
                }
            case "ipma": break
            default: throw ExportError.encodingFailed
            }
        }
        return data
    }

    /// The file holds one picture: the primary item, and when it is a `grid`, the `hvc1` tiles it
    /// names through `dimg`. A thumbnail (`thmb`), any other reference, or an item nothing reaches
    /// from the primary one (a second picture) is refused.
    private static func checkPicture(
        _ reader: DecodeByteReader, items: [Int: String], primary: Int, iref: Range<Int>?
    ) throws(ExportError) {
        guard let primaryType = items[primary] else { throw ExportError.encodingFailed }
        var picture: Set<Int> = [primary]
        if let iref {
            guard iref.count >= 4 else { throw ExportError.encodingFailed }
            let idSize = reader.byte(iref.lowerBound) == 0 ? 2 : 4
            for reference in try isoBoxes(reader, in: (iref.lowerBound + 4)..<iref.upperBound) {
                guard reference.type == "dimg", primaryType == "grid", reference.body.count >= idSize + 2,
                    itemID(reader, at: reference.body.lowerBound, size: idSize) == primary
                else { throw ExportError.encodingFailed }
                let count = reader.uint16(reference.body.lowerBound + idSize)
                let first = reference.body.lowerBound + idSize + 2
                guard first + count * idSize == reference.body.upperBound else { throw ExportError.encodingFailed }
                for index in 0..<count {
                    let tile = itemID(reader, at: first + index * idSize, size: idSize)
                    guard items[tile] == "hvc1" else { throw ExportError.encodingFailed }
                    picture.insert(tile)
                }
            }
        }
        guard Set(items.keys) == picture else { throw ExportError.encodingFailed }
    }

    /// `pitm` is a full box: version 0 names the item in 2 bytes, later versions in 4.
    private static func primaryItem(_ reader: DecodeByteReader, pitm: Range<Int>) throws(ExportError) -> Int {
        guard pitm.count >= 6 else { throw ExportError.encodingFailed }
        let size = reader.byte(pitm.lowerBound) == 0 ? 2 : 4
        guard pitm.count == 4 + size else { throw ExportError.encodingFailed }
        return itemID(reader, at: pitm.lowerBound + 4, size: size)
    }

    private static func itemID(_ reader: DecodeByteReader, at offset: Int, size: Int) -> Int {
        size == 2 ? reader.uint16(offset) : Int(reader.uint32(offset))
    }

    /// Every `infe` (version 2 or 3, which name their item type) is an image item; returns each
    /// item's ID and type.
    private static func checkItems(_ reader: DecodeByteReader, iinf: Range<Int>) throws(ExportError) -> [Int: String] {
        guard iinf.count >= 6 else { throw ExportError.encodingFailed }
        let version = reader.byte(iinf.lowerBound)
        let countSize = version == 0 ? 2 : 4
        let entries = try isoBoxes(reader, in: (iinf.lowerBound + 4 + countSize)..<iinf.upperBound)
        guard !entries.isEmpty else { throw ExportError.encodingFailed }
        var items: [Int: String] = [:]
        for entry in entries {
            guard entry.type == "infe", entry.body.count >= 12 else { throw ExportError.encodingFailed }
            let entryVersion = reader.byte(entry.body.lowerBound)
            guard entryVersion == 2 || entryVersion == 3 else { throw ExportError.encodingFailed }
            // version, flags, item ID (2 or 4 bytes), protection index (2), item type (4).
            let idSize = entryVersion == 2 ? 2 : 4
            let typeOffset = entry.body.lowerBound + 4 + idSize + 2
            guard typeOffset + 4 <= entry.body.upperBound else { throw ExportError.encodingFailed }
            let type = String(decoding: reader.slice(typeOffset..<(typeOffset + 4)), as: UTF8.self)
            let id = itemID(reader, at: entry.body.lowerBound + 4, size: idSize)
            guard heicItemTypes.contains(type), items.updateValue(type, forKey: id) == nil else {
                throw ExportError.encodingFailed
            }
        }
        return items
    }

    /// The boxes that exactly tile `range`: each one's type and body (after its header).
    private static func isoBoxes(_ reader: DecodeByteReader, in range: Range<Int>) throws(ExportError)
        -> [(type: String, body: Range<Int>)]
    {
        var boxes: [(type: String, body: Range<Int>)] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard offset + 8 <= range.upperBound else { throw ExportError.encodingFailed }
            let size32 = Int(reader.uint32(offset))
            let type = String(decoding: reader.slice((offset + 4)..<(offset + 8)), as: UTF8.self)
            var header = 8
            let size: Int
            switch size32 {
            case 0: size = range.upperBound - offset
            case 1:
                guard offset + 16 <= range.upperBound else { throw ExportError.encodingFailed }
                let large = (UInt64(reader.uint32(offset + 8)) << 32) | UInt64(reader.uint32(offset + 12))
                guard large <= UInt64(range.upperBound - offset) else { throw ExportError.encodingFailed }
                size = Int(large)
                header = 16
            default: size = size32
            }
            guard size >= header, size <= range.upperBound - offset else { throw ExportError.encodingFailed }
            boxes.append((type, (offset + header)..<(offset + size)))
            offset += size
        }
        return boxes
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
