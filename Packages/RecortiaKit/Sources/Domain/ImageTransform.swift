import Foundation

/// A quarter turn or a mirror of the whole image or of image layers (A-10).
///
/// It keeps the top-left corner of what it transforms, so content on whole document pixels stays
/// there: turning about the centre would put a layer whose sides differ by an odd number of pixels
/// on half pixels and resample it. Four turns, or two mirrors, give back the same placement.
public enum ImageTransform: CaseIterable, Hashable, Sendable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    /// A turn swaps a rectangle's width and height; a mirror keeps them.
    public var swapsSides: Bool { self == .rotateLeft || self == .rotateRight }

    /// The transform of `rect` that keeps its top-left corner.
    public func map(keepingOriginOf rect: Rect<DocumentSpace>) -> AffineMap<DocumentSpace, DocumentSpace> {
        let linear: AffineMap<DocumentSpace, DocumentSpace> =
            switch self {
            case .rotateRight: .rotation(.pi / 2)
            case .rotateLeft: .rotation(-.pi / 2)
            case .flipHorizontal: .scale(x: -1, y: 1)
            case .flipVertical: .scale(x: 1, y: -1)
            }
        let turned = AffineMap<DocumentSpace, DocumentSpace>.translation(dx: -rect.minX, dy: -rect.minY).then(linear)
        let bounds = turned.apply(rect)
        return turned.then(.translation(dx: rect.minX - bounds.minX, dy: rect.minY - bounds.minY))
    }

    /// `layer` after `map` (this transform in document space): its source pixels land exactly where
    /// `map` sends them. The scale stays uniform; a mirror toggles `mirrored` and negates the turn.
    public func applied(
        to layer: ImageLayer, by map: AffineMap<DocumentSpace, DocumentSpace>, assetSize: PixelSize
    ) -> ImageLayer {
        var moved = layer
        let rotation = layer.placement.rotation
        switch self {
        case .rotateRight: moved.placement.rotation = Self.normalized(rotation + .pi / 2)
        case .rotateLeft: moved.placement.rotation = Self.normalized(rotation - .pi / 2)
        case .flipHorizontal:
            moved.placement.rotation = Self.normalized(-rotation)
            moved.placement.mirrored.toggle()
        case .flipVertical:
            moved.placement.rotation = Self.normalized(.pi - rotation)
            moved.placement.mirrored.toggle()
        }
        // The linear parts already agree (a uniform scale commutes with turns, and a mirror
        // reverses them); one shared point then fixes the translation.
        let visible = layer.visibleSourceRect(assetSize: assetSize)
        let corner = Point<SourcePixelSpace>(x: Double(visible.x), y: Double(visible.y))
        let target = map.apply(layer.sourceToDocument(assetSize: assetSize).apply(corner))
        moved.placement.translation = .zero
        let placed = moved.sourceToDocument(assetSize: assetSize).apply(corner)
        moved.placement.translation = Point(x: target.x - placed.x, y: target.y - placed.y)
        return moved
    }

    /// `radians` in [0, 2π); a whole number of quarter turns becomes exactly `k · π/2`, which
    /// `AffineMap.rotation` evaluates without rounding error.
    static func normalized(_ radians: Double) -> Double {
        let quarter = Double.pi / 2
        let turns = (radians / quarter).rounded()
        if abs(turns) < 1e6, abs(radians - turns * quarter) <= 1e-9 {
            return Double((Int(turns) % 4 + 4) % 4) * quarter
        }
        let full = radians.truncatingRemainder(dividingBy: 2 * .pi)
        return full < 0 ? full + 2 * .pi : full
    }
}
