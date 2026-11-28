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
        let opaque = try opaqueView(image)
        guard options.automaticFormat else {
            return (
                try encode(image, opaque: opaque, options.format, background: options.jpegBackground), options.format
            )
        }
        let png = try encode(image, opaque: opaque, .png, background: options.jpegBackground)
        // Under the floor no JPEG can win, and a translucent image keeps PNG, so no JPEG is encoded.
        guard png.count > AutomaticFormatRule.minimumPNGByteCount, opaque != nil else { return (png, .png) }
        let format = ExportFormat.jpeg(quality: AutomaticFormatRule.jpegQuality)
        let jpeg = try encode(image, opaque: opaque, format, background: options.jpegBackground)
        return AutomaticFormatRule.keepsJPEG(pngByteCount: png.count, jpegByteCount: jpeg.count)
            ? (jpeg, format) : (png, .png)
    }

    static func encode(_ image: CGImage, options: ExportOptions) throws(ExportError) -> Data {
        try encode(image, opaque: try opaqueView(image), options.format, background: options.jpegBackground)
    }

    private static func encode(
        _ image: CGImage, opaque: OpaqueView?, _ format: ExportFormat, background: RGBA
    ) throws(ExportError) -> Data {
        switch format {
        case .png:
            let source = opaque?.image ?? image
            return try ExportContainerFilter.png(
                try imageIO(source, type: "public.png", properties: pngProperties(source, pixels: opaque?.pixels)))
        case .jpeg(let quality):
            let source = try lossySource(image, opaque: opaque, background: background)
            return try ExportContainerFilter.jpeg(
                try imageIO(
                    source, type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: quality]))
        case .heic(let quality):
            let source = try lossySource(image, opaque: opaque, background: background)
            return try ExportContainerFilter.heic(
                try imageIO(
                    source, type: "public.heic", properties: [kCGImageDestinationLossyCompressionQuality: quality]))
        }
    }

    /// JPEG and HEIC have no alpha (FR-07). Compositing a canonical opaque raster over the
    /// background would redraw the same bytes into `RenderRaster.makeImage(opaque: true)`'s layout,
    /// which is exactly its opaque view, so that view is encoded instead.
    private static func lossySource(_ image: CGImage, opaque: OpaqueView?, background: RGBA) throws(ExportError)
        -> CGImage
    {
        guard background.isOpaque else { throw ExportError.invalidOptions(.translucentJPEGBackground) }
        if let opaque, opaque.pixels != nil { return opaque.image }
        return try flatten(image, on: background)
    }

    /// An opaque image seen without alpha. `pixels` are the bytes the opacity scan read, present
    /// only for the zero-copy view of a canonical `RenderRaster` image.
    struct OpaqueView {
        let image: CGImage
        let pixels: Data?
    }

    /// The same pixels without an alpha channel when every pixel is opaque, nil when one is not.
    /// At alpha 255 premultiplied color is straight color, so a canonical raster's view shares its
    /// bytes; any other layout with alpha is returned unchanged once found opaque.
    static func opaqueView(_ image: CGImage) throws(ExportError) -> OpaqueView? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return OpaqueView(image: image, pixels: nil)
        default: break
        }
        guard image.alphaInfo == .premultipliedLast, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
            image.byteOrderInfo == .order32Big, let space = RenderRaster.colorSpace, image.colorSpace == space,
            let provider = image.dataProvider, let pixels = provider.data as Data?
        else { return try hasTransparency(image) ? nil : OpaqueView(image: image, pixels: nil) }
        guard
            AlphaScan.isOpaque(pixels, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow)
        else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        // `decode: nil` passes no pointer.
        guard
            let view = unsafe CGImage(
                width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: image.bytesPerRow, space: space, bitmapInfo: info, provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { throw ExportError.encodingFailed }
        return OpaqueView(image: view, pixels: pixels)
    }

    /// ImageIO applies the PNG row-filter property only to images without alpha (an RGBA image
    /// encodes the same bytes whatever it says). Interface pixels compress smallest and fastest
    /// unfiltered; anything else gets Up, which measured no larger than the RGBA encoding on every
    /// probed photo, gradient and mixed screen. `pixels` are the image's bytes when already read.
    static func pngProperties(_ image: CGImage, pixels known: Data? = nil) -> [CFString: Any] {
        guard image.alphaInfo == .noneSkipLast, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
            let pixels = known ?? image.dataProvider?.data as Data?
        else { return [:] }
        let unfiltered = PNGRowFilter.prefersUnfiltered(
            pixels, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow)
        let filter = unfiltered ? IMAGEIO_PNG_FILTER_NONE : IMAGEIO_PNG_FILTER_UP
        return [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: filter]]
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

    /// Keeps SOI, the JFIF APP0 header without any thumbnail, ICC APP2, DQT, SOFn, DHT, DRI, and a
    /// single baseline scan through EOI.
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
            if marker == 0xE0 {
                // JFIF's fixed 14 bytes may be followed by an uncompressed thumbnail: keep the
                // identifier, version, units and density, with a 0x0 thumbnail.
                if payload.starts(with: Array("JFIF\0".utf8)), payload.count >= 14 {
                    output.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10])
                    output.append(payload.prefix(12))
                    output.append(contentsOf: [0, 0])
                }
            } else if keeps(marker: marker, payload: payload) {
                output.append(reader.slice(offset..<end))
            }
            offset = end
        }
    }

    /// ISOBMFF boxes a HEIC export may hold: the file, its `meta` box, and the item properties.
    static let heicFileBoxes: Set<String> = ["ftyp", "meta", "mdat"]
    static let heicMetaBoxes: Set<String> = ["hdlr", "dinf", "pitm", "iinf", "iref", "iprp", "iloc", "idat"]
    static let heicPropertyBoxes: Set<String> = [
        "hvcC", "ispe", "colr", "pixi", "irot", "imir", "clap", "clli", "mdcv",
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
        // ISOBMFF allows each of these once per `meta`; a second `iref` or `iinf` would go unread.
        let childTypes = children.map(\.type)
        guard Set(childTypes).isSubset(of: heicMetaBoxes), Set(childTypes).count == childTypes.count,
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
    /// names through its one `dimg` (a reader composes the grid from the first, so a later one is
    /// a picture of its own). A thumbnail (`thmb`), any other reference, or an item nothing
    /// reaches from the primary one (a second picture) is refused.
    private static func checkPicture(
        _ reader: DecodeByteReader, items: [Int: String], primary: Int, iref: Range<Int>?
    ) throws(ExportError) {
        guard let primaryType = items[primary] else { throw ExportError.encodingFailed }
        var picture: Set<Int> = [primary]
        if let iref {
            guard iref.count >= 4 else { throw ExportError.encodingFailed }
            let idSize = reader.byte(iref.lowerBound) == 0 ? 2 : 4
            let references = try isoBoxes(reader, in: (iref.lowerBound + 4)..<iref.upperBound)
            guard references.count <= 1 else { throw ExportError.encodingFailed }
            for reference in references {
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
        guard iinf.count >= 4 else { throw ExportError.encodingFailed }
        let version = reader.byte(iinf.lowerBound)
        let countSize = version == 0 ? 2 : 4
        guard iinf.count >= 4 + countSize else { throw ExportError.encodingFailed }
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

enum AlphaScan {
    /// Whether every alpha byte (the fourth of each 32-bit pixel) is 255. False for a buffer smaller
    /// than the rows it describes.
    static func isOpaque(_ bytes: Data, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !rowOverflow, bytesPerRow >= rowBytes,
            case let (start, o1) = (height - 1).multipliedReportingOverflow(by: bytesPerRow), !o1,
            case let (needed, o2) = start.addingReportingOverflow(rowBytes), !o2, bytes.count >= needed
        else { return false }
        // Eight bytes (two pixels) per load; the alpha bytes are bits 24-31 and 56-63 of a
        // little-endian word. Invariant: every load ends at or before `base + rowBytes`, which the
        // guard keeps inside the buffer.
        let alphas: UInt64 = 0xFF00_0000_FF00_0000
        return unsafe bytes.withUnsafeBytes { buffer in
            for row in 0..<height {
                let base = row * bytesPerRow
                var i = base
                var word: UInt64 = alphas
                while i + 8 <= base + rowBytes {
                    word &= unsafe buffer.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian
                    i += 8
                }
                if i < base + rowBytes, unsafe buffer[i + 3] != 255 { return false }
                if word & alphas != alphas { return false }
            }
            return true
        }
    }
}

enum PNGRowFilter {
    /// Whether a 32-bit RGBX buffer looks like interface content, sampled every eighth row: at
    /// least 90% of pixels repeat their left neighbor and at most a quarter of the rest are smooth
    /// steps (two levels or less, as in gradients and photos). False for a buffer smaller than the
    /// rows it describes.
    static func prefersUnfiltered(_ bytes: Data, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        let span = bytes.span
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 1, height > 0, !rowOverflow, bytesPerRow >= rowBytes,
            case let (start, o1) = (height - 1).multipliedReportingOverflow(by: bytesPerRow), !o1,
            case let (needed, o2) = start.addingReportingOverflow(rowBytes), !o2, span.count >= needed
        else { return false }
        func step(_ a: UInt8, _ b: UInt8) -> UInt8 { a > b ? a - b : b - a }
        var same = 0
        var smooth = 0
        var total = 0
        var row = 0
        while row < height {
            let base = row * bytesPerRow
            var i = base + 4
            while i < base + rowBytes {
                let largest = max(
                    step(span[i], span[i - 4]), step(span[i + 1], span[i - 3]), step(span[i + 2], span[i - 2]))
                if largest == 0 { same += 1 } else if largest <= 2 { smooth += 1 }
                i += 4
            }
            total += width - 1
            row += 8
        }
        return same * 10 >= total * 9 && smooth * 4 <= total - same
    }
}
