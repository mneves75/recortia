import CoreGraphics
import Domain
import Foundation
import Vision

// Text-only redaction (A-6, decisions.md 2026-11-21): the automatic-masking sweep, reading every
// recognized line instead of matching patterns. Same tiles, budgets, fragment runs and padding.
extension SensitiveTextScanner {
    /// Points of context read around the rectangle on each side, so a line the rectangle cuts
    /// through is still read whole (a half line seldom reads as text at all).
    static let lineContextPoints = 32.0

    /// Whole-pixel rectangles of the stored asset `id`, one per text line recognized inside `area`
    /// (source pixels, top-left origin), each padded like automatic masking's matches and clamped
    /// to `area`. The pixels are read here, inside Imaging, and never leave it. Throws
    /// `assetUnavailable` when the store no longer holds the asset, and otherwise as
    /// `textLineRegions(in:within:pixelsPerPoint:languages:)` does.
    @concurrent
    public func textLineRegions(
        of id: AssetID, in store: ImageStore, within area: PixelRect, pixelsPerPoint: Double,
        languages: [Locale.Language]
    ) async throws -> [PixelRect] {
        guard let image = await store.images(for: [id])[id] else { throw SensitiveTextError.assetUnavailable }
        return try await textLineRegions(in: image, within: area, pixelsPerPoint: pixelsPerPoint, languages: languages)
    }

    /// Lines of `image` inside `area`. Throws `regionOutsideImage` when `area` is empty or not wholly
    /// inside the image, `CancellationError` when cancelled, and a recognition or budget error when
    /// any tile cannot be read, so a caller never takes a partial sweep for a complete one.
    @concurrent
    func textLineRegions(
        in image: CGImage, within area: PixelRect, pixelsPerPoint: Double, languages: [Locale.Language]
    ) async throws -> [PixelRect] {
        try Task.checkCancellation()
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let target = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
        guard !area.isEmpty, bounds.contains(target) else { throw SensitiveTextError.regionOutsideImage }
        let margin = (Self.lineContextPoints * max(pixelsPerPoint, 1)).rounded(.up)
        let read = target.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        guard let crop = image.cropping(to: read) else { throw SensitiveTextError.tileUnavailable }
        let size = CGSize(width: crop.width, height: crop.height)
        let jobs = try Self.tileJobs(
            for: size, pixelsPerPoint: pixelsPerPoint, fineTileSide: fineTileSide,
            layouts: Self.lineLayouts(for: size, pixelsPerPoint: pixelsPerPoint, fineTileSide: fineTileSide))
        let recognizer = self.recognizer
        let found = try await Self.scanTiles(jobs, concurrency: Self.concurrentTiles) { job in
            try await Self.scanLines(
                of: crop, sourceRect: job.rect, scale: job.layout.scale, languages: languages,
                recognizer: recognizer)
        }
        let offset = found.map { $0.offsetBy(dx: read.minX, dy: read.minY) }
        return try Self.finalLineRegions(offset, read: read, target: target)
    }

    /// The standard sweeps, less every coarser one that a finer sweep already covers in a single
    /// tile: text in that tile is whole, and a resampled sliver of a small area reads nothing.
    static func lineLayouts(for size: CGSize, pixelsPerPoint: Double, fineTileSide: CGFloat) -> [TileLayout] {
        var layouts: [TileLayout] = []
        for layout in TileLayout.standard(pixelsPerPoint: pixelsPerPoint, fineTileSide: fineTileSide) {
            if let finer = layouts.last, tileCount(for: size, layout: finer) == 1 { break }
            layouts.append(layout)
        }
        return layouts
    }

    /// The source-pixel box of every line Vision recognized in one tile. Every observation counts,
    /// readable or not; neighbouring fragments of one line are joined into it (`fragmentRuns`).
    private static func scanLines(
        of image: CGImage, sourceRect: CGRect, scale: CGFloat, languages: [Locale.Language],
        recognizer: TextRecognizer
    ) async throws -> [CGRect] {
        try Task.checkCancellation()
        let tile = try renderTile(of: image, sourceRect: sourceRect, scale: scale)
        let observations = try await recognizer.recognizedObservations(tile, languages: languages).observations
        guard observations.count <= maximumObservationsPerTile else { throw SensitiveTextError.tooManyMatches }
        try Task.checkCancellation()
        let boxes = observations.map(\.boundingBox.cgRect)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        // A box Vision cannot place on the tile fails the sweep, as it does for matches (R05).
        guard boxes.allSatisfy({ isMappable($0, within: unit) }) else { throw SensitiveTextError.regionOutsideImage }
        let pixelBoxes = boxes.map {
            CGRect(
                x: $0.minX * CGFloat(tile.width), y: $0.minY * CGFloat(tile.height),
                width: $0.width * CGFloat(tile.width),
                height: $0.height * CGFloat(tile.height))
        }
        let lines = fragmentRuns(pixelBoxes).map { run in
            run.reduce(CGRect.null) { $0.union(boxes[$1.index]) }
        }
        guard lines.count <= maximumMatchesPerTile else { throw SensitiveTextError.tooManyMatches }
        return lines.map { sourceBox($0, in: sourceRect) }
    }

    /// Merges the lines found by several tiles and sweeps, drops those outside `target`, pads the
    /// rest and clamps them to `target`. A box that cannot be mapped onto the pixels read fails the
    /// sweep, and so does a cancellation that arrives while this runs.
    static func finalLineRegions(_ found: [CGRect], read: CGRect, target: CGRect) throws -> [PixelRect] {
        try Task.checkCancellation()
        guard found.count <= maximumMatches else { throw SensitiveTextError.tooManyMatches }
        // Validated before padding: padding must never turn an unmappable box into a mask.
        guard found.allSatisfy({ isMappable($0, within: read) }) else { throw SensitiveTextError.regionOutsideImage }
        let inside = mergeLines(found.filter { isMappable($0, within: target) })
        let regions = try inside.map { box throws(SensitiveTextError) in try outset(box, within: target) }
        try Task.checkCancellation()
        // `outset` returns whole pixels; rounding only drops floating-point noise.
        return regions.map {
            PixelRect(
                x: Int($0.minX.rounded()), y: Int($0.minY.rounded()), width: Int($0.width.rounded()),
                height: Int($0.height.rounded()))
        }
    }

    /// The same line is found by several tiles and sweeps; collapse those into one, as
    /// `mergeRegions` does for matches. Sorted first, so the result does not depend on the order in
    /// which tiles finish.
    static func mergeLines(_ boxes: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for box in boxes.sorted(by: { ($0.minY, $0.minX, $0.maxY, $0.maxX) < ($1.minY, $1.minX, $1.maxY, $1.maxX) }) {
            var current = box
            // A union can newly overlap a line accepted earlier, so keep absorbing until stable.
            while let index = merged.firstIndex(where: { overlapsSubstantially($0, current) }) {
                current = current.union(merged.remove(at: index))
            }
            merged.append(current)
        }
        return merged.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }
}
