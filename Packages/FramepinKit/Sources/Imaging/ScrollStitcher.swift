import CoreGraphics
import Domain
import Foundation

public enum ScrollStitchError: Error, Equatable, Sendable {
    case noFrames
    case imageCreationFailed
}

/// Stitches already-captured viewport frames of a vertically scrolling page (FR-10).
///
/// The first frame is kept whole. Once the page first moves, rows identical at the same position
/// in both frames at the top and bottom become the fixed header and footer bands; only the region
/// between them is matched. Each accepted frame appends exactly the newly exposed rows, copied
/// from the frame without blending or resampling, and replaces the footer with its own. The
/// header comes from the first frame and the footer from the last accepted one.
///
/// Memory: the appended output rows, one footer band, and the matching planes of the previous
/// frame; during `append` the incoming frame is the second full frame. Matching temporaries are
/// strip-sized. The value is synchronous: run it off the main actor.
public struct ScrollStitcher: Sendable {
    public let limits: ScrollLimits
    /// Consecutive stationary frames after which the page is taken to have ended.
    public static let endOfPageStationaryFrames = 3

    public private(set) var acceptedFrameCount = 0
    public private(set) var consecutiveStationaryFrames = 0
    public private(set) var outputSize = PixelSize(width: 0, height: 0)

    private var frameWidth = 0
    private var frameHeight = 0
    /// Header plus scrolled content, RGBA8, top-down.
    private var rows: [UInt8] = []
    private var footer: [UInt8] = []
    private var bands: (top: Int, bottom: Int)?
    private var previous: ScrollFrame?
    private var reachedLimit: ScrollLimit?
    private let thresholds = ScrollMatcher.Thresholds.calibrated

    public init(limits: ScrollLimits = .default) {
        self.limits = limits
    }

    public var endOfPageDetected: Bool {
        acceptedFrameCount > 0 && consecutiveStationaryFrames >= Self.endOfPageStationaryFrames
    }

    public mutating func append(_ frame: CGImage, elapsed: Duration) -> ScrollAppendResult {
        if let reachedLimit { return .limitReached(reachedLimit) }
        let size = PixelSize(width: frame.width, height: frame.height)

        guard let previous else {
            // Checked before decoding so an oversized viewport is never materialized.
            if let limit = limits.firstExceeded(elapsed: elapsed, frames: 1, outputSize: size) { return stop(limit) }
            guard let first = ScrollFrame(image: frame) else { return .ambiguous(.lowConfidence) }
            frameWidth = size.width
            frameHeight = size.height
            rows = first.pixels
            outputSize = size
            acceptedFrameCount = 1
            self.previous = first.demoted()
            return .accepted(offset: 0)
        }
        if let limit = limits.firstExceeded(elapsed: elapsed, frames: acceptedFrameCount, outputSize: outputSize) {
            return stop(limit)
        }
        guard size.width == frameWidth, size.height == frameHeight, let current = ScrollFrame(image: frame) else {
            consecutiveStationaryFrames = 0
            return .ambiguous(.lowConfidence)
        }

        let frameBands =
            bands ?? Self.detectBands(previous: previous, current: current, tolerance: thresholds.pixelTolerance)
        let region = frameBands.top..<(frameHeight - frameBands.bottom)
        let decision: ScrollMatcher.Decision
        if bands == nil, region.count < ScrollMatcher.minimumRegionHeight(regionHeight: frameHeight, width: frameWidth)
        {
            // Before the first movement, (nearly) all rows unchanged at the same position: no
            // scrolling region can be located, so only stationarity can be decided.
            decision =
                ScrollMatcher.changedRowsAreStationary(previous: previous, current: current, thresholds: thresholds)
                ? .stationary : .pause(.lowConfidence)
        } else {
            decision = ScrollMatcher.decide(
                previous: previous, current: current, region: region, allowStationary: bands != nil,
                thresholds: thresholds)
        }
        switch decision {
        case .stationary:
            consecutiveStationaryFrames += 1
            return .stationary
        case .pause(let reason):
            consecutiveStationaryFrames = 0
            return .ambiguous(reason)
        case .displacement(let offset):
            let contentRows = bands == nil ? frameHeight - frameBands.bottom : outputSize.height - frameBands.bottom
            let projected = PixelSize(width: frameWidth, height: contentRows + offset + frameBands.bottom)
            if let limit = limits.firstExceeded(elapsed: elapsed, frames: acceptedFrameCount + 1, outputSize: projected)
            {
                return stop(limit)
            }
            if bands == nil {
                // The first frame's bottom band becomes the (replaceable) footer.
                rows.removeLast(frameBands.bottom * frameWidth * 4)
                bands = frameBands
            }
            let contentBottom = frameHeight - frameBands.bottom
            rows += current.pixelRows((contentBottom - offset)..<contentBottom)
            footer = Array(current.pixelRows(contentBottom..<frameHeight))
            outputSize = projected
            acceptedFrameCount += 1
            consecutiveStationaryFrames = 0
            self.previous = current.demoted()
            return .accepted(offset: offset)
        }
    }

    public func preview(maxHeight: Int) -> CGImage? {
        guard maxHeight > 0, acceptedFrameCount > 0, !outputSize.isEmpty else { return nil }
        guard outputSize.height > maxHeight else { return try? assemble() }
        let scale = Double(maxHeight) / Double(outputSize.height)
        let width = max(1, Int((Double(outputSize.width) * scale).rounded()))
        let height = max(1, min(maxHeight, Int((Double(outputSize.height) * scale).rounded())))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        let yScale = Double(height) / Double(outputSize.height)
        // Bounded working memory: draw the output in chunks instead of materializing it.
        let chunkRows = 512
        let totalRows = outputSize.height
        var top = 0
        while top < totalRows {
            let count = min(chunkRows, totalRows - top)
            guard let chunk = Self.image(width: frameWidth, rows: count, pixels: outputRows(top..<(top + count))) else {
                return nil
            }
            let destination = CGRect(
                x: 0, y: Double(height) - Double(top + count) * yScale, width: Double(width),
                height: Double(count) * yScale)
            context.draw(chunk, in: destination)
            top += count
        }
        return context.makeImage()
    }

    /// The full stitched image. Its size never exceeds `limits`, which were checked before every append.
    public func assemble() throws -> CGImage {
        guard acceptedFrameCount > 0, !outputSize.isEmpty else { throw ScrollStitchError.noFrames }
        guard let image = Self.image(width: frameWidth, rows: outputSize.height, pixels: ArraySlice(rows + footer))
        else {
            throw ScrollStitchError.imageCreationFailed
        }
        return image
    }

    // MARK: Accounting (SCR-04)

    package var retainedFullFrameCount: Int { previous == nil ? 0 : 1 }

    package var retainedByteCount: Int { rows.count + footer.count + (previous?.byteCount ?? 0) }

    /// Upper bound on transient matching memory per append: strip-sized luma differences.
    package static func workingBudgetBytes(forFrameWidth width: Int) -> Int {
        ScrollMatcher.maximumStripCount * ScrollMatcher.maximumStripHeight * width * MemoryLayout<Float>.stride * 4
    }

    // MARK: Private

    private mutating func stop(_ limit: ScrollLimit) -> ScrollAppendResult {
        reachedLimit = limit
        return .limitReached(limit)
    }

    private func outputRows(_ range: Range<Int>) -> ArraySlice<UInt8> {
        let rowBytes = frameWidth * 4
        let bodyRows = rows.count / rowBytes
        if range.upperBound <= bodyRows { return rows[(range.lowerBound * rowBytes)..<(range.upperBound * rowBytes)] }
        var chunk: [UInt8] = []
        chunk.reserveCapacity(range.count * rowBytes)
        for row in range {
            chunk +=
                row < bodyRows
                ? rows[(row * rowBytes)..<((row + 1) * rowBytes)]
                : footer[((row - bodyRows) * rowBytes)..<((row - bodyRows + 1) * rowBytes)]
        }
        return chunk[...]
    }

    /// Leading and trailing rows that are unchanged at the same position. Blank content rows can
    /// be mistaken for a band; that is harmless because header rows come from the first frame and
    /// footer rows from the latest one, so every page row is still emitted exactly once.
    static func detectBands(previous: ScrollFrame, current: ScrollFrame, tolerance: Float) -> (top: Int, bottom: Int) {
        let height = current.height
        // A small animated element (spinner, clock) may change part of a fixed row.
        let maximumChangedFraction = 0.25
        func isFixed(_ y: Int) -> Bool {
            ScrollMatcher.error(
                previous: previous, current: current, rows: y..<(y + 1), displacement: 0, tolerance: tolerance)
                <= maximumChangedFraction
        }
        var top = 0
        while top < height, isFixed(top) { top += 1 }
        var bottom = 0
        while bottom < height - top, isFixed(height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    private static func image(width: Int, rows: Int, pixels: ArraySlice<UInt8>) -> CGImage? {
        guard width > 0, rows > 0, pixels.count == width * rows * 4,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
