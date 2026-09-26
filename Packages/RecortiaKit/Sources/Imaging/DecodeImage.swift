import CoreGraphics
import Domain
import Foundation
import ImageIO

/// Bounded PNG/JPEG import (FR-03, IO-01). Order of checks: byte count, magic bytes, container
/// structure and declared dimensions, frame count, then a single full decode. The output is the
/// canonical format with EXIF orientation applied exactly once. Decoding never touches the
/// network and never writes to the input.
public enum ImageDecoder {
    public static func decode(_ data: Data) throws(ImportError) -> DecodedImage {
        if ImportLimits.check(byteCount: data.count) != nil { throw ImportError.tooManyBytes }
        guard let format = DecodeFormat.sniff(data) else { throw ImportError.unsupportedFormat }

        let header: DecodeHeader
        let decodable: Data
        switch format {
        case .png:
            let layout = try DecodePNGStructure.layout(data)
            if layout.header.isAnimated { throw ImportError.multiFrame }
            try DecodePNGStructure.verifyImageData(data, layout: layout)
            header = layout.header
            decodable = DecodePNGStructure.decodableBytes(data, layout: layout)
        case .jpeg:
            header = try DecodeJPEGStructure.header(data)
            decodable = data
        }

        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(decodable as CFData, noCache) else { throw ImportError.corrupt }
        guard (CGImageSourceGetType(source) as String?) == format.typeIdentifier else {
            throw ImportError.unsupportedFormat
        }
        guard CGImageSourceGetCount(source) == 1 else { throw ImportError.multiFrame }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            PixelSize(width: width, height: height) == header.pixelSize
        else { throw ImportError.corrupt }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int).flatMap(DecodeOrientation.init) ?? .up

        let decodeOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions),
            image.width == width, image.height == height
        else { throw ImportError.corrupt }
        return try canonical(image, orientation: orientation)
    }

    /// Converts a capture (or any in-memory image) to the canonical format after the same limits.
    public static func canonicalize(_ image: CGImage) throws(ImportError) -> DecodedImage {
        try checkDimensions(PixelSize(width: image.width, height: image.height))
        return try canonical(image, orientation: .up)
    }

    /// The pre-decode limit check: positive sides, no overflow in the RGBA row/area arithmetic,
    /// and at most `ImportLimits.maxPixelArea` pixels.
    package static func checkDimensions(_ size: PixelSize) throws(ImportError) {
        switch ImportLimits.check(pixelSize: size) {
        case .tooManyPixels: throw ImportError.tooManyPixels
        case .invalidDimensions, .tooManyBytes: throw ImportError.invalidDimensions
        case nil: break
        }
        guard RenderRaster.byteCount(width: size.width, height: size.height) != nil else {
            throw ImportError.invalidDimensions
        }
    }

    private static func canonical(_ image: CGImage, orientation: DecodeOrientation) throws(ImportError) -> DecodedImage
    {
        let w = image.width, h = image.height
        let swapsAxes = orientation.swapsAxes
        let outputWidth = swapsAxes ? h : w, outputHeight = swapsAxes ? w : h
        var raster: RenderRaster
        do {
            raster = try RenderRaster(width: outputWidth, height: outputHeight)
            try raster.withTopLeftContext { context in
                context.setBlendMode(.copy)
                context.interpolationQuality = .none
                context.concatenate(orientation.transform(width: Double(w), height: Double(h)))
                // Draw upright in the stored image's own top-left pixel space.
                context.translateBy(x: 0, y: CGFloat(h))
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        } catch {
            throw ImportError.corrupt
        }
        guard let canonicalImage = raster.makeImage() else { throw ImportError.corrupt }
        return DecodedImage(image: canonicalImage)
    }
}

/// EXIF/TIFF orientation values 1–8.
enum DecodeOrientation: Int {
    case up = 1, upMirrored, down, downMirrored, leftMirrored, right, rightMirrored, left

    var swapsAxes: Bool { rawValue >= 5 }

    /// Maps stored top-left pixel coordinates to display coordinates (both y-down).
    func transform(width w: Double, height h: Double) -> CGAffineTransform {
        switch self {
        case .up: CGAffineTransform.identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .rightMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .left: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        }
    }
}
