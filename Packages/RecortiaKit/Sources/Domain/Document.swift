import Foundation

/// Where a capture came from. Identifiers are ScreenCaptureKit/Core Graphics display and window IDs.
public enum CaptureSource: Hashable, Sendable, Codable {
    case display(id: UInt32)
    case window(id: UInt32, displayID: UInt32)
    case region(displayID: UInt32)
}

/// The geometry record every capture carries (SPEC.md §7).
public struct CaptureGeometry: Hashable, Sendable, Codable {
    public var source: CaptureSource
    public var desktopBounds: Rect<DesktopSpace>
    /// Pixels per point reported for the source display; never assumed to be 2.
    public var pointPixelScale: Double
    public var pixelSize: PixelSize
    public var capturedAt: Date

    public init(
        source: CaptureSource, desktopBounds: Rect<DesktopSpace>, pointPixelScale: Double, pixelSize: PixelSize,
        capturedAt: Date
    ) {
        self.source = source
        self.desktopBounds = desktopBounds
        self.pointPixelScale = pointPixelScale
        self.pixelSize = pixelSize
        self.capturedAt = capturedAt
    }
}

public enum AssetOrigin: Hashable, Sendable, Codable {
    case captured(CaptureGeometry)
    case imported
    case pasted
    /// A stitched scrolling capture; `partialReason` is non-nil when the user accepted a partial result.
    /// `pointPixelScale` is the stitched image's pixels per point of its target.
    case scrollCapture(partialReason: ScrollPartialReason?, pointPixelScale: Double)
}

/// Metadata for an immutable raster asset. The pixels themselves live in Imaging's asset store,
/// which only the render pipeline can read.
public struct ImageAssetInfo: Identifiable, Hashable, Sendable, Codable {
    public var id: AssetID
    public var pixelSize: PixelSize
    public var origin: AssetOrigin

    public init(id: AssetID, pixelSize: PixelSize, origin: AssetOrigin) {
        self.id = id
        self.pixelSize = pixelSize
        self.origin = origin
    }

    /// Screen scale when the asset came from a capture; imported images have pixels, not points (FR-11).
    public var pointPixelScale: Double? {
        if case .captured(let geometry) = origin { return geometry.pointPixelScale }
        return nil
    }

}

/// Uniform scale only: the model cannot express a silently stretched aspect ratio (FR-12).
public struct LayerPlacement: Hashable, Sendable, Codable {
    public var translation: Point<DocumentSpace>
    public var scale: Double
    /// Radians, about the layer's top-left corner.
    public var rotation: Double
    /// The asset is mirrored left to right before it is rotated (A-10). A mirror is not a
    /// stretch: the scale stays uniform.
    public var mirrored: Bool

    public init(
        translation: Point<DocumentSpace> = .zero, scale: Double = 1, rotation: Double = 0, mirrored: Bool = false
    ) {
        self.translation = translation
        self.scale = scale
        self.rotation = rotation
        self.mirrored = mirrored
    }

    private enum CodingKeys: String, CodingKey { case translation, scale, rotation, mirrored }

    /// A placement written before mirroring existed has no `mirrored` key and is not mirrored;
    /// an unmirrored placement is written without the key, so old documents keep their bytes.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        translation = try c.decode(Point<DocumentSpace>.self, forKey: .translation)
        scale = try c.decode(Double.self, forKey: .scale)
        rotation = try c.decode(Double.self, forKey: .rotation)
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(translation, forKey: .translation)
        try c.encode(scale, forKey: .scale)
        try c.encode(rotation, forKey: .rotation)
        if mirrored { try c.encode(true, forKey: .mirrored) }
    }

    /// Whether the rotation is a whole number of quarter turns, so the layer's edges stay
    /// horizontal and vertical.
    public var isAxisAligned: Bool {
        (0..<4).contains { rotation == Double($0) * (.pi / 2) }
    }
}

public struct ImageLayer: Identifiable, Hashable, Sendable, Codable {
    public var id: LayerID
    public var assetID: AssetID
    public var placement: LayerPlacement
    public var opacity: Double
    /// Visible part of the asset in source pixels; nil shows the whole asset.
    public var sourceCrop: PixelRect?

    public init(
        id: LayerID = LayerID(), assetID: AssetID, placement: LayerPlacement = LayerPlacement(), opacity: Double = 1,
        sourceCrop: PixelRect? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.placement = placement
        self.opacity = opacity
        self.sourceCrop = sourceCrop
    }

    /// Source rectangle actually shown, in asset pixels.
    public func visibleSourceRect(assetSize: PixelSize) -> PixelRect {
        sourceCrop ?? PixelRect(x: 0, y: 0, width: assetSize.width, height: assetSize.height)
    }

    /// Maps asset pixels into document space: crop offset, mirror, rotation, scale, then
    /// translation. A mirror keeps the visible pixels where they were before it, so `translation`
    /// is still the unrotated top-left corner.
    public func sourceToDocument(assetSize: PixelSize) -> AffineMap<SourcePixelSpace, DocumentSpace> {
        let visible = visibleSourceRect(assetSize: assetSize)
        var local = AffineMap<SourcePixelSpace, SourcePixelSpace>.translation(
            dx: -Double(visible.x), dy: -Double(visible.y))
        if placement.mirrored {
            local = local.then(AffineMap(a: -1, b: 0, c: 0, d: 1, tx: Double(visible.width), ty: 0))
        }
        return
            local
            .then(AffineMap<SourcePixelSpace, DocumentSpace>.rotation(placement.rotation))
            .then(.scale(placement.scale))
            .then(.translation(dx: placement.translation.x, dy: placement.translation.y))
    }

    /// The layer's footprint in document space (bounding box when rotated).
    public func documentBounds(assetSize: PixelSize) -> Rect<DocumentSpace> {
        sourceToDocument(assetSize: assetSize).apply(visibleSourceRect(assetSize: assetSize).asRect)
    }
}

/// An opaque, secure redaction (FR-06). It is bound to source pixels of every asset it touched
/// when created, and it also keeps document-space coverage for vectors and text above the layers.
public struct SecureMask: Identifiable, Hashable, Sendable, Codable {
    public var id: MaskID
    public var outputRect: Rect<DocumentSpace>
    public var sourceRegions: [AssetID: [PixelRect]]
    public var fill: RGBA

    public init(
        id: MaskID = MaskID(), outputRect: Rect<DocumentSpace>, sourceRegions: [AssetID: [PixelRect]], fill: RGBA
    ) {
        self.id = id
        self.outputRect = outputRect
        self.sourceRegions = sourceRegions
        self.fill = fill
    }
}

/// Blur or pixelation. Cosmetic only: never presented or treated as secure (FR-06, RED-04).
public struct CosmeticObfuscation: Identifiable, Hashable, Sendable, Codable {
    public enum Style: Hashable, Sendable, Codable {
        case blur(radius: Double)
        case pixelate(blockSize: Double)
    }

    public var id: MaskID
    public var rect: Rect<DocumentSpace>
    public var style: Style

    public init(id: MaskID = MaskID(), rect: Rect<DocumentSpace>, style: Style) {
        self.id = id
        self.rect = rect
        self.style = style
    }
}

/// Presentation framing (FR-13). Padding surrounds the (cropped) content; an aspect preset grows
/// the background around it to a fixed output ratio, never reducing the padding.
public struct Presentation: Hashable, Sendable, Codable {
    public enum Background: Hashable, Sendable, Codable {
        case none
        case solid(RGBA)
        case linearGradient(from: RGBA, to: RGBA, angleDegrees: Double)
        /// `center` at the middle of the output, `edge` at its corners.
        case radialGradient(center: RGBA, edge: RGBA)
    }

    public struct Shadow: Hashable, Sendable, Codable {
        public var radius: Double
        public var offsetY: Double
        public var opacity: Double

        public init(radius: Double = 24, offsetY: Double = 12, opacity: Double = 0.35) {
            self.radius = radius
            self.offsetY = offsetY
            self.opacity = opacity
        }
    }

    public var background: Background
    public var padding: Double
    public var cornerRadius: Double
    public var shadow: Shadow?
    public var aspect: FramingAspect
    /// With an aspect preset, centre the content's opaque pixels rather than its box, so a window
    /// capture's transparent shadow margin does not push the window off centre.
    public var balancesContent: Bool

    public init(
        background: Background = .none, padding: Double = 0, cornerRadius: Double = 0, shadow: Shadow? = nil,
        aspect: FramingAspect = .free, balancesContent: Bool = true
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspect = aspect
        self.balancesContent = balancesContent
    }

    public static let plain = Presentation()

    public var isPlain: Bool { self == .plain }

    /// Whether the renderer centres the opaque content bounds instead of the content box.
    public var centresOpaqueContent: Bool { aspect != .free && balancesContent }

    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, aspect, balancesContent
    }

    /// Documents and preferences written before aspect presets have no `aspect` or
    /// `balancesContent` key; they decode as Free with balance on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        background = try container.decode(Background.self, forKey: .background)
        padding = try container.decode(Double.self, forKey: .padding)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        shadow = try container.decodeIfPresent(Shadow.self, forKey: .shadow)
        aspect = try container.decodeIfPresent(FramingAspect.self, forKey: .aspect) ?? .free
        balancesContent = try container.decodeIfPresent(Bool.self, forKey: .balancesContent) ?? true
    }
}

/// Spotlight and magnifier callouts (FR-13). A magnifier samples the sanitized raster layers,
/// never the final composite, so it cannot form a render cycle.
public struct Callout: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case spotlight(Rect<DocumentSpace>, dimOpacity: Double)
        case magnifier(source: Rect<DocumentSpace>, destination: Rect<DocumentSpace>)
    }

    public var id: CalloutID
    public var kind: Kind

    public init(id: CalloutID = CalloutID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public enum DocumentError: Error, Equatable, Sendable {
    case translucentSecureMask
    case emptyMask
    case unmappableTransform
    case invalidGeometry
    case unknownAsset
    case invalidScale
}

/// The editable document. Pure values: no pixels, so copies for undo are cheap.
public struct Document: Identifiable, Hashable, Sendable, Codable {
    public var id: DocumentID
    public var assets: [AssetID: ImageAssetInfo]
    public var canvasSize: Size<DocumentSpace>
    public var layers: [ImageLayer]
    public var annotations: [Annotation]
    public var masks: [SecureMask]
    public var obfuscations: [CosmeticObfuscation]
    /// Reversible crop of the canvas; nil exports the whole canvas.
    public var crop: Rect<DocumentSpace>?
    /// Reversible resize applied to the output (FR-04), on top of export scale.
    public var resizeScale: Double
    public var presentation: Presentation
    public var callouts: [Callout]

    public init(
        id: DocumentID = DocumentID(), assets: [AssetID: ImageAssetInfo], canvasSize: Size<DocumentSpace>,
        layers: [ImageLayer], annotations: [Annotation] = [], masks: [SecureMask] = [],
        obfuscations: [CosmeticObfuscation] = [], crop: Rect<DocumentSpace>? = nil, resizeScale: Double = 1,
        presentation: Presentation = .plain, callouts: [Callout] = []
    ) {
        self.id = id
        self.assets = assets
        self.canvasSize = canvasSize
        self.layers = layers
        self.annotations = annotations
        self.masks = masks
        self.obfuscations = obfuscations
        self.crop = crop
        self.resizeScale = resizeScale
        self.presentation = presentation
        self.callouts = callouts
    }

    /// A single-image document sized to the asset.
    public init(id: DocumentID = DocumentID(), asset: ImageAssetInfo) {
        self.init(
            id: id, assets: [asset.id: asset],
            canvasSize: Size(width: Double(asset.pixelSize.width), height: Double(asset.pixelSize.height)),
            layers: [ImageLayer(assetID: asset.id)])
    }

    /// A new capture's document. A window capture is framed over a solid `windowBackground`
    /// (FR-02); the colour is a presentation step, so the source pixels, and any secure mask
    /// filled into them, stay as captured. A saved default framing applies to every capture; its
    /// background wins unless it is None, which keeps the window background.
    public init(
        capture asset: ImageAssetInfo, windowBackground: WindowCaptureBackground, defaultFraming: Presentation? = nil
    ) {
        self.init(asset: asset)
        presentation = defaultFraming ?? .plain
        if presentation.background == .none, case .captured(let geometry) = asset.origin,
            case .window = geometry.source, case .solid(let color) = windowBackground
        {
            presentation.background = .solid(color)
        }
    }

    public var canvasRect: Rect<DocumentSpace> { Rect(origin: .zero, size: canvasSize) }

    /// Region of the canvas that is exported: the crop clipped to the canvas, or the whole canvas
    /// when there is no crop. An explicit crop that is empty or lies wholly off the canvas has no
    /// content: the result is empty (never the whole canvas) so the renderer refuses it.
    public var contentRect: Rect<DocumentSpace> {
        guard let crop else { return canvasRect }
        return crop.intersection(canvasRect) ?? Rect(x: 0, y: 0, width: 0, height: 0)
    }

    /// Output pixel size at `exportScale`, including presentation padding and aspect expansion.
    public func outputPixelSize(exportScale: Double) -> PixelSize { outputFrame(exportScale: exportScale).pixelSize }

    /// The framed output at `exportScale`: its pixel size and where the content's top-left corner
    /// sits in it, in output pixels. Free keeps the padding on every side; an aspect preset takes
    /// the smallest whole multiple of its ratio that holds the padded content and centres the
    /// content box on whole pixels, so the ratio is exact and the padding is a minimum.
    public func outputFrame(exportScale: Double) -> OutputFrame {
        let empty = OutputFrame(pixelSize: PixelSize(width: 0, height: 0), contentOriginX: 0, contentOriginY: 0)
        let scale = exportScale * resizeScale
        let padding = presentation.padding
        let width = ((contentRect.width + padding * 2) * scale).rounded()
        let height = ((contentRect.height + padding * 2) * scale).rounded()
        guard width.isFinite, height.isFinite, width < Double(Int32.max), height < Double(Int32.max) else {
            return empty
        }
        let framed = PixelSize(width: max(1, Int(width)), height: max(1, Int(height)))
        guard let ratio = presentation.aspect.ratio else {
            return OutputFrame(pixelSize: framed, contentOriginX: padding * scale, contentOriginY: padding * scale)
        }
        let multiple = max(
            (framed.width + ratio.width - 1) / ratio.width, (framed.height + ratio.height - 1) / ratio.height)
        let size = PixelSize(width: multiple * ratio.width, height: multiple * ratio.height)
        guard size.width < Int(Int32.max), size.height < Int(Int32.max) else { return empty }
        return OutputFrame(
            pixelSize: size,
            contentOriginX: ((Double(size.width) - contentRect.width * scale) / 2).rounded(.down),
            contentOriginY: ((Double(size.height) - contentRect.height * scale) / 2).rounded(.down))
    }

    /// The whole output at `exportScale` in document units, before any balance shift: the
    /// rectangle the rendered output covers when it is drawn over the document.
    public func framedRect(exportScale: Double) -> Rect<DocumentSpace> {
        let scale = exportScale * resizeScale
        let frame = outputFrame(exportScale: exportScale)
        guard scale.isFinite, scale > 0, !frame.pixelSize.isEmpty else { return contentRect }
        return Rect(
            x: contentRect.minX - frame.contentOriginX / scale, y: contentRect.minY - frame.contentOriginY / scale,
            width: Double(frame.pixelSize.width) / scale, height: Double(frame.pixelSize.height) / scale)
    }

    /// Computes the source-pixel regions a document-space mask covers in every intersecting layer.
    /// Mapping uses the inverse layer transform and outward rounding, so coverage is conservative.
    public func sourceRegions(for rect: Rect<DocumentSpace>) throws -> [AssetID: [PixelRect]] {
        var regions: [AssetID: [PixelRect]] = [:]
        for layer in layers {
            guard let covered = try coveredSourceRect(of: layer, by: rect) else { continue }
            if !(regions[layer.assetID]?.contains(covered) ?? false) {
                regions[layer.assetID, default: []].append(covered)
            }
        }
        return regions
    }

    /// The visible source pixels of `layer` that the document-space `rect` covers, rounded
    /// outward; nil when it covers none.
    public func coveredSourceRect(of layer: ImageLayer, by rect: Rect<DocumentSpace>) throws -> PixelRect? {
        guard let asset = assets[layer.assetID] else { throw DocumentError.unknownAsset }
        let toDocument = layer.sourceToDocument(assetSize: asset.pixelSize)
        // Invert before the intersection test: a degenerate layer has empty bounds and would
        // otherwise be skipped silently instead of refusing the mask (FR-06).
        let toSource: AffineMap<DocumentSpace, SourcePixelSpace>
        do { toSource = try toDocument.inverted() } catch { throw DocumentError.unmappableTransform }
        guard layer.documentBounds(assetSize: asset.pixelSize).intersects(rect) else { return nil }
        // Validate before clipping: clipping can hide overflowing corners or spans.
        let corners = rect.corners.map(toSource.apply)
        guard corners.allSatisfy(\.isFinite), let sourceRect = Rect<SourcePixelSpace>.bounding(corners),
            sourceRect.width.isFinite, sourceRect.height.isFinite, sourceRect.corners.allSatisfy(\.isFinite)
        else { throw DocumentError.unmappableTransform }
        let visible = layer.visibleSourceRect(assetSize: asset.pixelSize)
        guard let clipped = sourceRect.intersection(visible.asRect) else { return nil }
        return try PixelRect.covering(clipped, within: asset.pixelSize)
    }

    /// Approximate bytes of unique data held by the document model (no pixels). Used with
    /// `structuralByteCost` to budget undo memory (FR-04).
    var estimatedByteCost: Int {
        annotations.reduce(0) { $0 + $1.estimatedByteCost }
            + masks.reduce(0) { $0 + 64 + $1.sourceRegions.values.reduce(0) { $0 + $1.count * 32 } }
            + (obfuscations.count + layers.count + callouts.count + assets.count) * 128
    }

    /// Bytes copied per undo snapshot for the document's element arrays. Element payloads such as
    /// stroke points are shared between snapshots (copy-on-write) and are not counted here.
    var structuralByteCost: Int {
        (annotations.count + masks.count + obfuscations.count + layers.count + callouts.count + assets.count) * 64
    }
}
