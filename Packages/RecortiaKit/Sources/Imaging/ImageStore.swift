import CoreGraphics
import Domain
import Foundation

/// The only holder of raw source pixels. Pixels leave the store only through `package` accessors
/// used by the privacy renderer, so the app target cannot reach an unsanitized asset.
public actor ImageStore {
    private var images: [AssetID: CGImage] = [:]

    public init() {}

    public func insert(_ image: DecodedImage, origin: AssetOrigin) -> ImageAssetInfo {
        let info = ImageAssetInfo(id: AssetID(), pixelSize: image.pixelSize, origin: origin)
        images[info.id] = image.image
        return info
    }

    public func remove(_ id: AssetID) {
        images[id] = nil
    }

    public var count: Int { images.count }

    package func image(for id: AssetID) -> CGImage? { images[id] }

    package func images(for ids: Set<AssetID>) -> [AssetID: CGImage] {
        images.filter { ids.contains($0.key) }
    }
}
