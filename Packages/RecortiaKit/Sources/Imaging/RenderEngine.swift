import CoreGraphics
import Darwin
import Domain
import Foundation

/// The synchronous render core. Order (SPEC §8): validate and budget → fill source-bound masks
/// on a copy of each source → crop/transform/resample → cosmetic effects sampled from the
/// sanitized composite → annotations → output-space masks → callouts → output-space masks → presentation → alpha
/// normalization. Nothing downstream of the sanitized copies can see an original source pixel.
enum RenderEngine {
    static func isMainThread() -> Bool { pthread_main_np() != 0 }

    static let maxEffectRadius = 512.0

    // MARK: - Entry points

    static func render(_ document: Document, sources: [AssetID: CGImage], scale: Double) throws(RenderError)
        -> CGImage
    {
        guard scale.isFinite, scale > 0, document.resizeScale.isFinite, document.resizeScale > 0 else {
            throw RenderError.invalidScale
        }
        let s = scale * document.resizeScale
        guard s.isFinite, s > 0 else { throw RenderError.invalidScale }
        try validate(document, sources: sources)
        let content = document.contentRect
        guard !content.isEmpty else { throw RenderError.invalidGeometry }

        let frame = document.outputFrame(exportScale: scale)
        let size = frame.pixelSize
        let map = CGAffineTransform(
            a: s, b: 0, c: 0, d: s, tx: frame.contentOriginX - content.minX * s,
            ty: frame.contentOriginY - content.minY * s)
        var framing = document.presentation
        framing.border = nil
        framing.watermark = nil
        let presented = !framing.isPlain
        try checkBudget(
            document, sources: sources, outputSize: size, map: map, presented: presented, drawsCallouts: true,
            watermarkOpacityLayer: (document.presentation.watermark?.opacity ?? 1) < 1)

        let images = try sanitizedLayerImages(document, sources: sources)
        var raster = try RenderRaster(width: size.width, height: size.height)
        let contentPixels = content.cg.applying(map)
        guard let contentBounds = PixelRect.outward(contentPixels, within: raster.bounds) else {
            throw RenderError.invalidGeometry
        }
        try composeBase(into: &raster, document, images: images, map: map, clip: content, pixelClip: contentBounds)
        try raster.withTopLeftContext { (context: CGContext) throws(RenderError) in
            context.concatenate(map)
            context.clip(to: content.cg)
            try AnnotationRenderer.draw(document.annotations, in: context)
        }
        applyOutputMasks(&raster, document, map: map, pixelClip: contentBounds)
        try drawCallouts(&raster, document, images: images, map: map, content: content, pixelClip: contentBounds)
        // Secure masks are the topmost layer: a mask drawn over a callout (a magnifier's
        // destination) must hide what the callout draws there.
        applyOutputMasks(&raster, document, map: map, pixelClip: contentBounds)

        // Balance moves the finished, sanitized content as a whole, so it cannot uncover anything.
        let shift = document.presentation.centresOpaqueContent ? balanceShift(raster, content: contentBounds) : (0, 0)
        var final =
            presented
            ? try present(raster, framing, contentRect: contentPixels, scale: s, shift: shift)
            : raster
        try decorate(&final, with: document.presentation, scale: s)
        final.normalizeTransparentPixels()
        guard let image = final.makeImage() else { throw RenderError.allocationFailed }
        return image
    }

    static func renderBase(_ document: Document, sources: [AssetID: CGImage], scale: Double) throws(RenderError)
        -> CGImage
    {
        guard scale.isFinite, scale > 0 else { throw RenderError.invalidScale }
        try validate(document, sources: sources)
        let w = (document.canvasSize.width * scale).rounded(), h = (document.canvasSize.height * scale).rounded()
        guard w.isFinite, h.isFinite, w < Double(Int32.max), h < Double(Int32.max) else {
            throw RenderError.budgetExceeded(estimatedBytes: Int.max, limit: RenderLimits.maxWorkingBytes)
        }
        let size = PixelSize(width: max(1, Int(w)), height: max(1, Int(h)))
        let map = CGAffineTransform(scaleX: scale, y: scale)
        try checkBudget(
            document, sources: sources, outputSize: size, map: map, presented: false, drawsCallouts: false)

        let images = try sanitizedLayerImages(document, sources: sources)
        var raster = try RenderRaster(width: size.width, height: size.height)
        try composeBase(
            into: &raster, document, images: images, map: map, clip: document.canvasRect, pixelClip: raster.bounds)
        applyOutputMasks(&raster, document, map: map, pixelClip: raster.bounds)
        raster.normalizeTransparentPixels()
        guard let image = raster.makeImage() else { throw RenderError.allocationFailed }
        return image
    }

    // MARK: - Validation and budget

    private static func isFinite(_ rect: Rect<DocumentSpace>) -> Bool {
        rect.origin.isFinite && rect.size.width.isFinite && rect.size.height.isFinite && rect.width >= 0
            && rect.height >= 0
    }

    private static func isSafe(_ rect: PixelRect) -> Bool {
        rect.width >= 0 && rect.height >= 0 && !rect.x.addingReportingOverflow(rect.width).overflow
            && !rect.y.addingReportingOverflow(rect.height).overflow
    }

    static func validate(_ document: Document, sources: [AssetID: CGImage]) throws(RenderError) {
        let canvas = document.canvasSize
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else {
            throw RenderError.invalidGeometry
        }
        for layer in document.layers {
            guard let asset = document.assets[layer.assetID] else { throw RenderError.unknownAsset }
            guard let image = sources[layer.assetID] else { throw RenderError.missingPixels }
            guard image.width == asset.pixelSize.width, image.height == asset.pixelSize.height else {
                throw RenderError.invalidGeometry
            }
            let placement = layer.placement
            guard placement.translation.isFinite, placement.scale.isFinite, placement.scale > 0,
                placement.rotation.isFinite, layer.opacity.isFinite, (0...1).contains(layer.opacity)
            else { throw RenderError.invalidGeometry }
            if let crop = layer.sourceCrop {
                guard isSafe(crop), !crop.isEmpty, crop.x >= 0, crop.y >= 0, crop.maxX <= asset.pixelSize.width,
                    crop.maxY <= asset.pixelSize.height
                else { throw RenderError.invalidGeometry }
            }
        }
        for mask in document.masks {
            guard mask.fill.isOpaque else { throw RenderError.translucentSecureMask }
            guard isFinite(mask.outputRect), mask.sourceRegions.values.allSatisfy({ $0.allSatisfy(isSafe) }) else {
                throw RenderError.invalidGeometry
            }
        }
        for obfuscation in document.obfuscations {
            let amount: Double
            switch obfuscation.style {
            case .blur(let radius): amount = radius
            case .pixelate(let blockSize): amount = blockSize
            }
            guard isFinite(obfuscation.rect), amount.isFinite, amount > 0 else { throw RenderError.invalidGeometry }
        }
        guard document.annotations.allSatisfy(AnnotationRenderer.isDrawable) else { throw RenderError.invalidGeometry }
        if let crop = document.crop, !isFinite(crop) { throw RenderError.invalidGeometry }
        let presentation = document.presentation
        guard presentation.padding.isFinite, presentation.padding >= 0, presentation.cornerRadius.isFinite,
            presentation.cornerRadius >= 0, presentation.border?.isValid != false,
            presentation.watermark?.isValid != false
        else { throw RenderError.invalidGeometry }
        if let shadow = presentation.shadow {
            guard shadow.radius.isFinite, shadow.radius >= 0, shadow.offsetY.isFinite, shadow.opacity.isFinite else {
                throw RenderError.invalidGeometry
            }
        }
        if case .linearGradient(_, _, let angle) = presentation.background, !angle.isFinite {
            throw RenderError.invalidGeometry
        }
        for callout in document.callouts {
            switch callout.kind {
            case .spotlight(let rect, let dim):
                guard isFinite(rect), dim.isFinite else { throw RenderError.invalidGeometry }
            case .magnifier(let source, let destination):
                guard isFinite(source), isFinite(destination), !source.isEmpty, !destination.isEmpty else {
                    throw RenderError.invalidGeometry
                }
            }
        }
    }

    /// Estimates the renderer's own buffers and refuses before allocating any of them.
    static func checkBudget(
        _ document: Document, sources: [AssetID: CGImage], outputSize: PixelSize, map: CGAffineTransform,
        presented: Bool, drawsCallouts: Bool, watermarkOpacityLayer: Bool = false
    ) throws(RenderError) {
        let limit = RenderLimits.maxWorkingBytes
        var pixels = 0
        var overflow = false
        func add(_ value: Int) {
            let (sum, didOverflow) = pixels.addingReportingOverflow(value)
            pixels = sum
            overflow = overflow || didOverflow
        }
        guard !outputSize.isEmpty, let outputArea = outputSize.checkedArea,
            outputSize.width <= RenderLimits.maxOutputSide, outputSize.height <= RenderLimits.maxOutputSide,
            outputArea <= RenderLimits.maxOutputPixels
        else {
            let area = outputSize.checkedArea ?? Int.max
            let (bytes, didOverflow) = area.multipliedReportingOverflow(by: 4)
            throw RenderError.budgetExceeded(
                estimatedBytes: didOverflow ? Int.max : max(bytes, limit + 1), limit: limit)
        }
        add(outputArea)
        if presented { add(outputArea) }
        if watermarkOpacityLayer { add(outputArea) }
        var seen = Set<AssetID>()
        // `RenderRaster.fill` writes from one temporary row, at most as wide as the widest raster.
        var fillRow = outputSize.width
        for layer in document.layers {
            if seen.insert(layer.assetID).inserted, let image = sources[layer.assetID] {
                add(image.width * image.height)
                fillRow = max(fillRow, image.width)
            }
            if let crop = layer.sourceCrop { add(crop.width * crop.height) }
        }
        add(fillRow)
        let outputBounds = PixelRect(x: 0, y: 0, width: outputSize.width, height: outputSize.height)
        let factor = abs(map.a * map.d - map.b * map.c).squareRoot()
        var scratch = 0
        for callout in document.callouts where drawsCallouts {
            if case .magnifier(_, let destination) = callout.kind,
                let area = PixelRect.outward(destination.cg.applying(map), within: outputBounds)
            {
                // The magnified base plus one effect scratch region inside it.
                scratch = max(scratch, 2 * area.width * area.height)
            }
        }
        for obfuscation in document.obfuscations {
            guard let area = PixelRect.outward(obfuscation.rect.cg.applying(map), within: outputBounds) else {
                continue
            }
            var margin = 0
            if case .blur(let radius) = obfuscation.style {
                margin = RenderEffects.boxRadii(sigma: min(radius * factor, maxEffectRadius)).reduce(0, +)
            }
            let region = min(outputArea, (area.width + 2 * margin) * (area.height + 2 * margin))
            scratch = max(scratch, region)
        }
        add(scratch)
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow, !bytesOverflow, bytes <= limit else {
            throw RenderError.budgetExceeded(estimatedBytes: overflow || bytesOverflow ? Int.max : bytes, limit: limit)
        }
    }

    // MARK: - Stages

    /// One image per layer: a copy of the source with every source-bound mask filled opaquely,
    /// then cropped. Masks bound to an asset apply to every layer that references it (FR-06).
    static func sanitizedLayerImages(_ document: Document, sources: [AssetID: CGImage]) throws(RenderError)
        -> [CGImage]
    {
        var perAsset: [AssetID: CGImage] = [:]
        var result: [CGImage] = []
        // A mask also covers, in source pixels, whatever layer lies under its output rectangle now
        // (a layer added or moved there after the mask was drawn has no stored source regions), so
        // those pixels are filled before any resampling can blend them into the mask's edge.
        let underMasks: [(fill: RGBA, regions: [AssetID: [PixelRect]])]
        do {
            underMasks = try document.masks.map { ($0.fill, try document.sourceRegions(for: $0.outputRect)) }
        } catch {
            throw RenderError.invalidGeometry
        }
        for layer in document.layers {
            if Task.isCancelled { throw RenderError.canceled }
            let sanitized: CGImage
            if let cached = perAsset[layer.assetID] {
                sanitized = cached
            } else {
                guard let raw = sources[layer.assetID] else { throw RenderError.missingPixels }
                var raster = try RenderRaster(image: raw)
                for mask in document.masks {
                    for region in mask.sourceRegions[layer.assetID] ?? [] { raster.fill(region, with: mask.fill) }
                }
                for mask in underMasks {
                    for region in mask.regions[layer.assetID] ?? [] { raster.fill(region, with: mask.fill) }
                }
                guard let image = raster.makeImage() else { throw RenderError.allocationFailed }
                perAsset[layer.assetID] = image
                sanitized = image
            }
            let full = PixelRect(x: 0, y: 0, width: sanitized.width, height: sanitized.height)
            guard let crop = layer.sourceCrop, crop != full else {
                result.append(sanitized)
                continue
            }
            // A real copy, so resampling at the crop edge cannot read pixels outside the crop.
            var cropped = try RenderRaster(width: crop.width, height: crop.height)
            try cropped.withTopLeftContext { context in
                context.setBlendMode(.copy)
                context.interpolationQuality = .none
                DrawingPrimitives.drawUpright(
                    sanitized,
                    in: CGRect(x: -crop.x, y: -crop.y, width: sanitized.width, height: sanitized.height), context)
            }
            guard let image = cropped.makeImage() else { throw RenderError.allocationFailed }
            result.append(image)
        }
        return result
    }

    /// Sanitized layers, then cosmetic effects sampled from that composite.
    static func composeBase(
        into raster: inout RenderRaster, _ document: Document, images: [CGImage], map: CGAffineTransform,
        clip: Rect<DocumentSpace>, pixelClip: PixelRect
    ) throws(RenderError) {
        for (layer, image) in zip(document.layers, images) {
            if Task.isCancelled { throw RenderError.canceled }
            guard let asset = document.assets[layer.assetID] else { throw RenderError.unknownAsset }
            let visible = layer.visibleSourceRect(assetSize: asset.pixelSize)
            let imageToDocument = AffineMap<SourcePixelSpace, SourcePixelSpace>
                .translation(dx: Double(visible.x), dy: Double(visible.y))
                .then(layer.sourceToDocument(assetSize: asset.pixelSize))
            try raster.withTopLeftContext { context in
                context.concatenate(map)
                context.clip(to: clip.cg)
                context.concatenate(imageToDocument.cg)
                context.setAlpha(layer.opacity)
                context.interpolationQuality = .high
                DrawingPrimitives.drawUpright(
                    image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context)
            }
        }
        // Output-space coverage before any neighborhood effect: a layer added or moved under an
        // existing mask has no source-bound region for it, and blur/pixelate must never sample the
        // pixels that mask hides (FR-06). Masks are filled again after annotations.
        applyOutputMasks(&raster, document, map: map, pixelClip: pixelClip)
        let factor = abs(map.a * map.d - map.b * map.c).squareRoot()
        for obfuscation in document.obfuscations {
            guard let area = PixelRect.outward(obfuscation.rect.cg.applying(map), within: pixelClip) else { continue }
            switch obfuscation.style {
            case .blur(let radius):
                RenderEffects.blur(&raster, rect: area, radius: min(radius * factor, maxEffectRadius))
            case .pixelate(let blockSize):
                let block = min((blockSize * factor).rounded(), Double(RenderLimits.maxOutputSide))
                RenderEffects.pixelate(&raster, rect: area, blockSize: max(1, Int(block)))
            }
        }
    }

    /// Opaque output-space coverage, rounded outward in output pixels, for vectors and text.
    static func applyOutputMasks(
        _ raster: inout RenderRaster, _ document: Document, map: CGAffineTransform, pixelClip: PixelRect
    ) {
        for mask in document.masks {
            guard let area = PixelRect.outward(mask.outputRect.cg.applying(map), within: pixelClip) else { continue }
            raster.fill(area, with: mask.fill)
        }
    }

    static func drawCallouts(
        _ raster: inout RenderRaster, _ document: Document, images: [CGImage], map: CGAffineTransform,
        content: Rect<DocumentSpace>, pixelClip: PixelRect
    ) throws(RenderError) {
        for callout in document.callouts {
            if Task.isCancelled { throw RenderError.canceled }
            switch callout.kind {
            case .spotlight(let rect, let dimOpacity):
                let alpha = min(max(dimOpacity, 0), 1)
                try raster.withTopLeftContext { context in
                    context.concatenate(map)
                    context.clip(to: content.cg)
                    context.addRect(content.cg)
                    context.addRect(rect.cg)
                    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha))
                    context.fillPath(using: .evenOdd)
                }
            case .magnifier(let source, let destination):
                try drawMagnifier(
                    &raster, document, images: images, map: map, source: source, destination: destination,
                    content: content, pixelClip: pixelClip)
            }
        }
    }

    /// A magnifier re-renders the sanitized base (layers, effects, masks) through a magnifying
    /// transform. It never reads the output raster, so it cannot show annotations, other
    /// callouts, or itself, and cannot form a render cycle. Its source is clipped to the content
    /// rect, so a crop also excludes what the magnifier shows; outside it the destination is
    /// transparent, as for a source beyond the canvas.
    private static func drawMagnifier(
        _ raster: inout RenderRaster, _ document: Document, images: [CGImage], map: CGAffineTransform,
        source: Rect<DocumentSpace>, destination: Rect<DocumentSpace>, content: Rect<DocumentSpace>,
        pixelClip: PixelRect
    ) throws(RenderError) {
        let destinationPixels = destination.cg.applying(map)
        guard let area = PixelRect.outward(destinationPixels, within: pixelClip) else { return }
        var magnified = try RenderRaster(width: area.width, height: area.height)
        let magnify = CGAffineTransform(translationX: -source.minX, y: -source.minY)
            .concatenating(
                CGAffineTransform(scaleX: destination.width / source.width, y: destination.height / source.height)
            )
            .concatenating(CGAffineTransform(translationX: destination.minX, y: destination.minY))
        let magnifiedMap = magnify.concatenating(map)
            .concatenating(CGAffineTransform(translationX: -Double(area.x), y: -Double(area.y)))
        try composeBase(
            into: &magnified, document, images: images, map: magnifiedMap, clip: content, pixelClip: magnified.bounds)
        applyOutputMasks(&magnified, document, map: magnifiedMap, pixelClip: magnified.bounds)
        guard let image = magnified.makeImage() else { throw RenderError.allocationFailed }

        let contentPixels = content.cg.applying(map)
        try raster.withTopLeftContext { context in
            context.clip(to: destinationPixels.intersection(contentPixels))
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            DrawingPrimitives.drawUpright(
                image, in: CGRect(x: area.x, y: area.y, width: area.width, height: area.height), context)
        }
        try raster.withTopLeftContext { context in
            context.concatenate(map)
            context.clip(to: content.cg)
            context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 0.9))
            context.setLineWidth(1)
            context.stroke(destination.cg)
        }
    }

    /// The whole-pixel move that centres the content's fully opaque pixels in the output instead of
    /// its box (FR-13 balance), limited so the content box stays inside the output. A window
    /// capture's translucent shadow margin is not opaque, so the window itself ends up centred.
    /// Content with no opaque pixel does not move.
    static func balanceShift(_ raster: RenderRaster, content: PixelRect) -> (dx: Int, dy: Int) {
        guard let opaque = raster.opaqueBounds(in: content) else { return (0, 0) }
        let dx = (raster.width - opaque.width) / 2 - opaque.x
        let dy = (raster.height - opaque.height) / 2 - opaque.y
        return (
            min(max(dx, -content.x), raster.width - content.maxX),
            min(max(dy, -content.y), raster.height - content.maxY)
        )
    }

    /// Background, card shadow, and the content clipped to a rounded card, the content moved by
    /// `shift` whole pixels.
    static func present(
        _ content: RenderRaster, _ presentation: Presentation, contentRect unshifted: CGRect, scale: Double,
        shift: (dx: Int, dy: Int) = (0, 0)
    ) throws(RenderError) -> RenderRaster {
        guard let contentImage = content.makeImage() else { throw RenderError.allocationFailed }
        var output = try RenderRaster(width: content.width, height: content.height)
        let full = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let contentRect = unshifted.offsetBy(dx: CGFloat(shift.dx), dy: CGFloat(shift.dy))
        let radius = min(presentation.cornerRadius * scale, min(contentRect.width, contentRect.height) / 2)
        let card = CGMutablePath()
        card.addRoundedRect(in: contentRect, cornerWidth: radius, cornerHeight: radius)
        try output.withTopLeftContext { context in
            drawBackground(presentation.background, in: full, context)
            if let shadow = presentation.shadow, shadow.opacity > 0 {
                // Draw only the shadow: the card itself is translated off-canvas and the shadow
                // offset (in device space, y up) brings the shadow back under the card.
                let far = full.width + full.height + 64
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: -far, height: -shadow.offsetY * scale), blur: shadow.radius * scale,
                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: min(max(shadow.opacity, 0), 1)))
                context.translateBy(x: far, y: 0)
                context.addPath(card)
                context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                context.fillPath()
                context.restoreGState()
                // Keep the shadow from showing through transparent content inside the card.
                context.saveGState()
                context.addPath(card)
                context.clip()
                context.setBlendMode(.copy)
                drawBackground(presentation.background, in: full, context)
                context.restoreGState()
            }
            context.saveGState()
            context.addPath(card)
            context.clip()
            context.interpolationQuality = .none
            DrawingPrimitives.drawUpright(
                contentImage, in: full.offsetBy(dx: CGFloat(shift.dx), dy: CGFloat(shift.dy)), context)
            context.restoreGState()
        }
        return output
    }

    private static func decorate(
        _ raster: inout RenderRaster, with presentation: Presentation, scale: Double
    ) throws(RenderError) {
        guard presentation.border != nil || presentation.watermark != nil else { return }
        let output = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        try raster.withTopLeftContext { (context: CGContext) throws(RenderError) in
            if let border = presentation.border {
                let inset = min(border.width * scale, min(output.width, output.height) / 2)
                let inner = output.insetBy(dx: inset, dy: inset)
                let ring = CGMutablePath()
                ring.addRect(output)
                if !inner.isEmpty { ring.addRect(inner) }
                context.addPath(ring)
                context.setFillColor(border.color.cgColor)
                context.fillPath(using: .evenOdd)
            }
            if let watermark = presentation.watermark {
                try drawWatermark(watermark, in: output, scale: scale, context)
            }
        }
    }

    private static func drawWatermark(
        _ watermark: Presentation.Watermark, in output: CGRect, scale: Double, _ context: CGContext
    ) throws(RenderError) {
        let shortSide = min(output.width, output.height)
        let fontSize = max(8, min(44 * scale, shortSide * 0.12))
        let text = Annotation.TextContent(
            origin: Point(x: 0, y: 0), string: watermark.text, fontSize: fontSize, appearance: .outlined)
        let layout: TextLayout.Operation
        do {
            layout = try TextLayout.operation(
                for: text, style: Annotation.Style(stroke: .black, lineWidth: max(0.6, fontSize * 0.07)))
        } catch {
            throw .textLayoutFailed(error)
        }
        let ink = layout.metrics.frame.cg
        let angle = watermark.rotationDegrees * .pi / 180
        let cosine = abs(cos(angle)), sine = abs(sin(angle))
        let rotatedWidth = ink.width * cosine + ink.height * sine
        let rotatedHeight = ink.width * sine + ink.height * cosine
        let interior = output.insetBy(dx: shortSide * 0.04, dy: shortSide * 0.04)
        guard rotatedWidth > 0, rotatedHeight > 0 else { throw .invalidGeometry }
        let fit = min(1, interior.width / rotatedWidth, interior.height / rotatedHeight)
        let halfWidth = rotatedWidth * fit / 2, halfHeight = rotatedHeight * fit / 2
        let left = interior.minX + halfWidth, right = interior.maxX - halfWidth
        let top = interior.minY + halfHeight, bottom = interior.maxY - halfHeight
        let center: CGPoint
        switch watermark.position {
        case .topLeft: center = CGPoint(x: left, y: top)
        case .topRight: center = CGPoint(x: right, y: top)
        case .center: center = CGPoint(x: output.midX, y: output.midY)
        case .bottomLeft: center = CGPoint(x: left, y: bottom)
        case .bottomRight: center = CGPoint(x: right, y: bottom)
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldSmoothFonts(false)
        context.setShouldAntialias(true)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.scaleBy(x: fit, y: fit)
        context.translateBy(x: -ink.midX, y: -ink.midY)
        if watermark.opacity < 1 {
            // Composite the glyph fill and outline once at the chosen opacity.
            context.setAlpha(watermark.opacity)
            context.beginTransparencyLayer(in: ink, auxiliaryInfo: nil)
        }
        layout.draw(in: context)
        if watermark.opacity < 1 { context.endTransparencyLayer() }
    }

    private static func drawBackground(_ background: Presentation.Background, in rect: CGRect, _ context: CGContext) {
        switch background {
        case .none:
            context.clear(rect)
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case .linearGradient(let from, let to, let angleDegrees):
            // The locations array is valid for the call and has one entry per color.
            guard let space = RenderRaster.colorSpace,
                let gradient = unsafe CGGradient(
                    colorsSpace: space,
                    colors: [from.cgColor, to.cgColor] as CFArray,
                    locations: [0, 1])
            else { return }
            let radians = angleDegrees * .pi / 180
            let dx = cos(radians), dy = sin(radians)
            let half = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.drawLinearGradient(
                gradient, start: CGPoint(x: center.x - dx * half, y: center.y - dy * half),
                end: CGPoint(x: center.x + dx * half, y: center.y + dy * half),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radialGradient(let center, let edge):
            // The locations array is valid for the call and has one entry per color.
            guard let space = RenderRaster.colorSpace,
                let gradient = unsafe CGGradient(
                    colorsSpace: space,
                    colors: [center.cgColor, edge.cgColor] as CFArray,
                    locations: [0, 1])
            else { return }
            let middle = CGPoint(x: rect.midX, y: rect.midY)
            context.drawRadialGradient(
                gradient, startCenter: middle, startRadius: 0, endCenter: middle,
                endRadius: hypot(rect.width, rect.height) / 2, options: [.drawsAfterEndLocation])
        }
    }
}

extension AffineMap {
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}
