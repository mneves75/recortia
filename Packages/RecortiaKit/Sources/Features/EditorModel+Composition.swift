import Domain
import Foundation
import Imaging

// Composition (FR-12) and presentation (FR-13). Layers scale uniformly only (the model has one
// scale per layer), so no operation here can stretch an aspect ratio. Every change is one undo step.
extension EditorModel {
    public static let comparisonOpacity = 0.5
    public static let sideBySideSpacing = 24.0

    /// Imports an image through the bounded import services and adds it as a layer, centered and
    /// scaled down uniformly to fit the canvas when it is larger. Needs no screen access.
    @discardableResult
    public func addImageLayer(from source: ImportSource) async -> Bool {
        guard !isClosed else { return false }
        let info: ImageAssetInfo
        do throws(ImportError) {
            let data: Data
            let origin: AssetOrigin
            switch source {
            case .file(let url), .droppedFile(let url):
                data = try await environment.input.readFile(at: url)
                origin = .imported
            case .pasteboard:
                guard let pasted = environment.input.readPasteboardImage() else {
                    post(.importFailed(.nothingToPaste))
                    return false
                }
                data = pasted
                origin = .pasted
            case .droppedData(let dropped):
                data = dropped
                origin = .imported
            }
            info = try await environment.assets.importImage(data, origin: origin)
        } catch {
            post(.importFailed(ImportFailure(error)))
            return false
        }
        guard !isClosed else {
            environment.assets.release(info.id)
            return false
        }
        knownAssets.insert(info.id)
        let canvas = document.canvasSize
        let width = Double(info.pixelSize.width), height = Double(info.pixelSize.height)
        guard width > 0, height > 0 else { return false }
        let scale = min(1, canvas.width / width, canvas.height / height)
        let layer = ImageLayer(
            assetID: info.id,
            placement: LayerPlacement(
                translation: Point(x: (canvas.width - width * scale) / 2, y: (canvas.height - height * scale) / 2),
                scale: scale))
        let ok = edit("Add Image") { document in
            document.assets[info.id] = info
            document.layers.append(layer)
        }
        if ok { selection = [.layer(layer.id)] }
        return ok
    }

    public func setLayerOpacity(_ opacity: Double, for id: LayerID) {
        guard opacity.isFinite else { return }
        let value = min(max(opacity, 0), 1)
        edit("Layer Opacity") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            document.layers[index].opacity = value
        }
    }

    /// Uniform scale about the layer's top-left corner.
    public func setLayerScale(_ scale: Double, for id: LayerID) {
        guard scale.isFinite, scale > 0 else { return }
        let value = min(max(scale, 0.01), 16)
        edit("Layer Scale") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            document.layers[index].placement.scale = value
        }
    }

    /// Whether the top image is shown half transparent over the one below it.
    public var isComparingTransparency: Bool {
        let layers = document.layers
        return layers.count >= 2 && layers.last?.opacity == Self.comparisonOpacity
    }

    /// Transparency comparison: the top image at 50 % over the others, or back to opaque.
    public func toggleTransparencyComparison() {
        guard document.layers.count >= 2 else { return }
        let comparing = isComparingTransparency
        edit("Compare") { document in
            guard let last = document.layers.indices.last else { return }
            document.layers[last].opacity = comparing ? 1 : Self.comparisonOpacity
        }
    }

    /// Side-by-side preset: every image scaled uniformly to the first image's height, laid out
    /// left to right with `spacing`, and the canvas resized to fit them exactly.
    public func arrangeSideBySide(spacing: Double = sideBySideSpacing) {
        guard document.layers.count >= 2, spacing.isFinite, spacing >= 0 else { return }
        edit("Side by Side") { document in
            guard let first = document.layers.first, let firstAsset = document.assets[first.assetID] else { return }
            let targetHeight = first.documentBounds(assetSize: firstAsset.pixelSize).height
            guard targetHeight > 0 else { return }
            var x = 0.0
            for index in document.layers.indices {
                guard let asset = document.assets[document.layers[index].assetID] else {
                    throw DocumentError.unknownAsset
                }
                document.layers[index].placement.rotation = 0
                let visible = document.layers[index].visibleSourceRect(assetSize: asset.pixelSize)
                guard visible.height > 0 else { throw DocumentError.invalidGeometry }
                document.layers[index].placement.scale = targetHeight / Double(visible.height)
                document.layers[index].placement.translation = Point(x: x, y: 0)
                x += document.layers[index].documentBounds(assetSize: asset.pixelSize).width + spacing
            }
            document.canvasSize = Size(width: (x - spacing).rounded(.up), height: targetHeight.rounded(.up))
            document.crop = nil
        }
    }

    /// Grows the canvas to contain every layer and object, shifting everything when content
    /// extends past the top or left edge. Never shrinks it.
    public func fitCanvasToContent() {
        edit("Fit Canvas") { document in
            var union = document.canvasRect
            for layer in document.layers {
                guard let asset = document.assets[layer.assetID] else { continue }
                union = union.union(layer.documentBounds(assetSize: asset.pixelSize))
            }
            for annotation in document.annotations { union = union.union(EditorGeometry.frame(of: annotation)) }
            for callout in document.callouts {
                if let frame = EditorGeometry.frame(of: .callout(callout.id), in: document) {
                    union = union.union(frame)
                }
            }
            let dx = max(0, -union.minX).rounded(.up), dy = max(0, -union.minY).rounded(.up)
            try Self.shiftContent(&document, dx: dx, dy: dy)
            document.canvasSize = Size(
                width: (max(union.maxX, document.canvasSize.width) + dx).rounded(.up),
                height: (max(union.maxY, document.canvasSize.height) + dy).rounded(.up))
        }
    }

    /// Adds empty canvas around the content; top/left margins shift the content.
    public func expandCanvas(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        let margins = [top, left, bottom, right]
        guard margins.allSatisfy({ $0.isFinite && $0 >= 0 }), margins.contains(where: { $0 > 0 }) else { return }
        let t = top.rounded(), l = left.rounded(), b = bottom.rounded(), r = right.rounded()
        edit("Expand Canvas") { document in
            try Self.shiftContent(&document, dx: l, dy: t)
            document.canvasSize = Size(
                width: document.canvasSize.width + l + r, height: document.canvasSize.height + t + b)
        }
    }

    /// Moves every object by whole pixels. Masks keep their source regions: the layers they are
    /// bound to move by the same amount.
    static func shiftContent(_ document: inout Document, dx: Double, dy: Double) throws {
        guard dx != 0 || dy != 0 else { return }
        for index in document.layers.indices {
            document.layers[index].placement.translation =
                document.layers[index].placement.translation.offset(dx: dx, dy: dy)
        }
        document.annotations = document.annotations.map { $0.translated(dx: dx, dy: dy) }
        for index in document.masks.indices {
            document.masks[index].outputRect = document.masks[index].outputRect.offsetBy(dx: dx, dy: dy)
        }
        for index in document.obfuscations.indices {
            document.obfuscations[index].rect = document.obfuscations[index].rect.offsetBy(dx: dx, dy: dy)
        }
        for index in document.callouts.indices {
            document.callouts[index].kind = translated(document.callouts[index].kind, dx: dx, dy: dy, movesSource: true)
        }
        document.crop = document.crop?.offsetBy(dx: dx, dy: dy)
    }

    /// Aligns the selection to the canvas (one item) or to the selection's bounds (several).
    public func align(_ alignment: EditorAlignment) {
        let items = orderedSelection
        let frames = items.compactMap { item in frame(of: item).map { (item, $0) } }
        guard let first = frames.first else { return }
        let reference =
            frames.count == 1 ? document.canvasRect : frames.dropFirst().reduce(first.1) { $0.union($1.1) }
        edit("Align") { document in
            for (item, frame) in frames {
                let dx: Double, dy: Double
                switch alignment {
                case .left: (dx, dy) = (reference.minX - frame.minX, 0)
                case .horizontalCenter: (dx, dy) = (reference.midX - frame.midX, 0)
                case .right: (dx, dy) = (reference.maxX - frame.maxX, 0)
                case .top: (dx, dy) = (0, reference.minY - frame.minY)
                case .verticalCenter: (dx, dy) = (0, reference.midY - frame.midY)
                case .bottom: (dx, dy) = (0, reference.maxY - frame.maxY)
                }
                try Self.translate(&document, items: [item], dx: dx, dy: dy)
            }
        }
    }

    // MARK: Presentation

    public static let presentationRange: ClosedRange<Double> = 0...512

    public func setBackground(_ background: Presentation.Background) {
        edit("Background") { $0.presentation.background = background }
    }

    public func setPadding(_ padding: Double) {
        guard padding.isFinite else { return }
        let value = min(max(padding, Self.presentationRange.lowerBound), Self.presentationRange.upperBound)
        edit("Padding") { $0.presentation.padding = value }
    }

    public func setCornerRadius(_ radius: Double) {
        guard radius.isFinite else { return }
        let value = min(max(radius, Self.presentationRange.lowerBound), Self.presentationRange.upperBound)
        edit("Corner Radius") { $0.presentation.cornerRadius = value }
    }

    public func setShadow(_ shadow: Presentation.Shadow?) {
        if let shadow {
            guard shadow.radius.isFinite, shadow.radius >= 0, shadow.offsetY.isFinite, shadow.opacity.isFinite else {
                return
            }
        }
        edit("Shadow") { $0.presentation.shadow = shadow }
    }

    public func setSpotlightDim(_ dim: Double, for id: CalloutID) {
        guard dim.isFinite else { return }
        let value = min(max(dim, 0), 1)
        edit("Spotlight") { document in
            guard let index = document.callouts.firstIndex(where: { $0.id == id }),
                case .spotlight(let rect, _) = document.callouts[index].kind
            else { return }
            document.callouts[index].kind = .spotlight(rect, dimOpacity: value)
        }
    }

    /// Blur radius or pixel block size of a cosmetic effect.
    public func setObfuscationAmount(_ amount: Double, for id: MaskID) {
        guard amount.isFinite else { return }
        let value = min(max(amount, 1), 128)
        edit("Effect Strength") { document in
            guard let index = document.obfuscations.firstIndex(where: { $0.id == id }) else { return }
            switch document.obfuscations[index].style {
            case .blur: document.obfuscations[index].style = .blur(radius: value)
            case .pixelate: document.obfuscations[index].style = .pixelate(blockSize: value)
            }
        }
    }
}
