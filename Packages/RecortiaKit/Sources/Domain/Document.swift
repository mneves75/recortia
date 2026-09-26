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
    case scrollCapture(partialReason: ScrollPartialReason?)
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

    public var isPartialScrollCapture: Bool {
        if case .scrollCapture(let reason) = origin { return reason != nil }
        return false
    }
}

/// Uniform scale only: the model cannot express a silently stretched aspect ratio (FR-12).
public struct LayerPlacement: Hashable, Sendable, Codable {
    public var translation: Point<DocumentSpace>
    public var scale: Double
    /// Radians, about the layer's top-left corner.
    public var rotation: Double

    public init(translation: Point<DocumentSpace> = .zero, scale: Double = 1, rotation: Double = 0) {
        self.translation = translation
        self.scale = scale
        self.rotation = rotation
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

    /// Maps asset pixels into document space: crop offset, rotation, scale, then translation.
    public func sourceToDocument(assetSize: PixelSize) -> AffineMap<SourcePixelSpace, DocumentSpace> {
        let visible = visibleSourceRect(assetSize: assetSize)
        return AffineMap<SourcePixelSpace, SourcePixelSpace>.translation(dx: -Double(visible.x), dy: -Double(visible.y))
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

    /// Source-bound masks apply to every render reference of the asset, including duplicates,
    /// magnifiers, and pins. This is a property of the model, not an option.
    public var appliesToEveryReference: Bool { true }
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

/// Presentation framing (FR-13). Padding surrounds the (cropped) content.
public struct Presentation: Hashable, Sendable, Codable {
    public enum Background: Hashable, Sendable, Codable {
        case none
        case solid(RGBA)
        case linearGradient(from: RGBA, to: RGBA, angleDegrees: Double)
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

    public init(background: Background = .none, padding: Double = 0, cornerRadius: Double = 0, shadow: Shadow? = nil) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    public static let plain = Presentation()

    public var isPlain: Bool { self == .plain }
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

    public var canvasRect: Rect<DocumentSpace> { Rect(origin: .zero, size: canvasSize) }

    /// Region of the canvas that is exported: the crop, or the whole canvas.
    public var contentRect: Rect<DocumentSpace> { crop.flatMap { $0.intersection(canvasRect) } ?? canvasRect }

    /// Output pixel size at `exportScale`, including presentation padding.
    public func outputPixelSize(exportScale: Double) -> PixelSize {
        let scale = exportScale * resizeScale
        let padding = presentation.padding * 2
        let width = ((contentRect.width + padding) * scale).rounded()
        let height = ((contentRect.height + padding) * scale).rounded()
        guard width.isFinite, height.isFinite, width < Double(Int32.max), height < Double(Int32.max) else {
            return PixelSize(width: 0, height: 0)
        }
        return PixelSize(width: max(1, Int(width)), height: max(1, Int(height)))
    }

    /// Computes the source-pixel regions a document-space mask covers in every intersecting layer.
    /// Mapping uses the inverse layer transform and outward rounding, so coverage is conservative.
    public func sourceRegions(for rect: Rect<DocumentSpace>) throws -> [AssetID: [PixelRect]] {
        var regions: [AssetID: [PixelRect]] = [:]
        for layer in layers {
            guard let asset = assets[layer.assetID] else { throw DocumentError.unknownAsset }
            let toDocument = layer.sourceToDocument(assetSize: asset.pixelSize)
            // Invert before the intersection test: a degenerate layer has empty bounds and would
            // otherwise be skipped silently instead of refusing the mask (FR-06).
            let toSource: AffineMap<DocumentSpace, SourcePixelSpace>
            do { toSource = try toDocument.inverted() } catch { throw DocumentError.unmappableTransform }
            guard layer.documentBounds(assetSize: asset.pixelSize).intersects(rect) else { continue }
            let sourceRect = toSource.apply(rect)
            let visible = layer.visibleSourceRect(assetSize: asset.pixelSize)
            guard let clipped = sourceRect.intersection(visible.asRect),
                let covered = try PixelRect.covering(clipped, within: asset.pixelSize)
            else { continue }
            if !(regions[layer.assetID]?.contains(covered) ?? false) {
                regions[layer.assetID, default: []].append(covered)
            }
        }
        return regions
    }

    /// Every source-pixel region masked for `assetID`, across all masks.
    public func maskedRegions(for assetID: AssetID) -> [PixelRect] {
        masks.flatMap { $0.sourceRegions[assetID] ?? [] }
    }
}
