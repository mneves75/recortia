import Domain
import Foundation

// Rotate, flip and crop presets (A-10). Every change goes through `edit`, the editor's single edit
// path: a layer turn or mirror is a layer edit, so each mask first binds the pixels under its box
// and keeps its box where it is (decisions 2026-11-20). A whole-image turn moves every box with
// the content under it, so geometry stays aligned; bindings are in source pixels and need no change.
extension EditorModel {
    /// Whether the image can be turned or mirrored now: never during text input, automatic masking
    /// or Output Preview, which is read-only.
    public var canTransformImage: Bool { !isClosed && textEditing == nil && admitsAction() && !showsOutputPreview }

    /// Whether a selected image layer can be turned or mirrored now.
    public var canTransformLayers: Bool { canTransformImage && !selectedLayerIDs.isEmpty }

    private var selectedLayerIDs: [LayerID] {
        document.layers.map(\.id).filter { selection.contains(.layer($0)) }
    }

    /// Turns or mirrors the whole image, as one undo step: the canvas and everything on it.
    public func transformImage(_ transform: ImageTransform) {
        guard canTransformImage else { return }
        endContinuousChange()
        edit(Self.undoName(transform)) { try Self.transform(&$0, transform) }
    }

    /// Turns or mirrors each selected image layer in place (its top-left corner stays), as one undo step.
    public func transformSelectedLayers(_ transform: ImageTransform) {
        let ids = Set(selectedLayerIDs)
        guard canTransformImage, !ids.isEmpty else { return }
        endContinuousChange()
        edit(Self.undoName(transform)) { document in
            for index in document.layers.indices where ids.contains(document.layers[index].id) {
                let layer = document.layers[index]
                guard let asset = document.assets[layer.assetID] else { throw DocumentError.unknownAsset }
                let map = transform.map(keepingOriginOf: layer.documentBounds(assetSize: asset.pixelSize))
                document.layers[index] = transform.applied(to: layer, by: map, assetSize: asset.pixelSize)
            }
        }
    }

    public func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
    }

    private static func undoName(_ transform: ImageTransform) -> String {
        switch transform {
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate Right"
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
    }

    /// The whole document through `transform`; the canvas keeps its top-left corner at zero.
    static func transform(_ document: inout Document, _ transform: ImageTransform) throws {
        let canvas = document.canvasRect
        let map = transform.map(keepingOriginOf: canvas)
        for index in document.layers.indices {
            guard let asset = document.assets[document.layers[index].assetID] else { throw DocumentError.unknownAsset }
            document.layers[index] = transform.applied(to: document.layers[index], by: map, assetSize: asset.pixelSize)
        }
        for index in document.annotations.indices {
            let moved = try mapped(document.annotations[index], by: map)
            try validateArrow(moved)
            document.annotations[index] = moved
        }
        for index in document.masks.indices {
            document.masks[index].outputRect = map.apply(document.masks[index].outputRect)
        }
        for index in document.obfuscations.indices {
            document.obfuscations[index].rect = map.apply(document.obfuscations[index].rect)
        }
        for index in document.callouts.indices {
            switch document.callouts[index].kind {
            case .spotlight(let rect, let dim):
                document.callouts[index].kind = .spotlight(map.apply(rect), dimOpacity: dim)
            case .magnifier(let source, let destination):
                document.callouts[index].kind = .magnifier(
                    source: map.apply(source), destination: map.apply(destination))
            }
        }
        document.crop = document.crop.map(map.apply)
        if transform.swapsSides { document.canvasSize = Size(width: canvas.height, height: canvas.width) }
    }

    /// `annotation` with every point through `map`. Text stays upright: its frame's centre moves to
    /// where `map` sends it.
    private static func mapped(_ annotation: Annotation, by map: AffineMap<DocumentSpace, DocumentSpace>) throws
        -> Annotation
    {
        var copy = annotation
        switch annotation.kind {
        case .text:
            guard let frame = EditorGeometry.frame(of: annotation) else { throw DocumentError.invalidGeometry }
            let centre = map.apply(Point(x: frame.midX, y: frame.midY))
            return annotation.translated(dx: centre.x - frame.midX, dy: centre.y - frame.midY)
        case .arrow(let start, let end, let control, let head):
            copy.kind = .arrow(
                start: map.apply(start), end: map.apply(end), control: control.map(map.apply), head: head)
        case .line(let start, let end):
            copy.kind = .line(start: map.apply(start), end: map.apply(end))
        case .rectangle(let rect):
            copy.kind = .rectangle(map.apply(rect))
        case .ellipse(let rect):
            copy.kind = .ellipse(map.apply(rect))
        // Quarter turns and mirrors keep distances, so a smoothed stroke's curve maps exactly.
        case .freehand(let points, let smoothed):
            copy.kind = .freehand(points.map(map.apply), smoothed: smoothed)
        case .highlighter(let points, let smoothed):
            copy.kind = .highlighter(points.map(map.apply), smoothed: smoothed)
        case .step(let center, let number):
            copy.kind = .step(center: map.apply(center), number: number)
        }
        return copy
    }

    /// The crop rectangle a drag from `start` to `end` draws. A preset holds its ratio from any
    /// corner, inside the canvas and on whole pixels: the width is whole and the height follows it,
    /// so the ratio is exact to half a pixel. Without one, Shift draws a square as before.
    func cropRect(from start: Point<DocumentSpace>, to end: Point<DocumentSpace>, modifiers: EditorModifiers)
        -> Rect<DocumentSpace>
    {
        let canvas = document.canvasRect
        guard let ratio = cropAspect.ratio(canvas: canvas.size) else {
            return EditorGeometry.constrainedRect(from: start, to: end, square: modifiers.contains(.shift))
        }
        let anchor = Point<DocumentSpace>(
            x: min(max(start.x.rounded(), canvas.minX), canvas.maxX),
            y: min(max(start.y.rounded(), canvas.minY), canvas.maxY))
        let corner = RegionPrecision.drag(
            anchor: anchor, pointer: end, ratio: ratio, keys: SelectionKeys(), guides: [], within: canvas
        ).corner
        let width = abs(corner.x - anchor.x).rounded(.down)
        let height = (width * ratio.height / ratio.width).rounded()
        return Rect(
            x: corner.x < anchor.x ? anchor.x - width : anchor.x, y: corner.y < anchor.y ? anchor.y - height : anchor.y,
            width: width, height: height)
    }
}
