import AppKit
import Domain
import Features
import SwiftUI

// Rotate, flip and crop presets (A-10): titles, symbols and identifiers shared by the Image menu
// and the inspector, so both name a command the same way.
extension ImageTransform {
    /// The whole-image command.
    var imageTitle: String {
        switch self {
        case .rotateLeft: String(localized: "Rotate Left", table: "Editor")
        case .rotateRight: String(localized: "Rotate Right", table: "Editor")
        case .flipHorizontal: String(localized: "Flip Horizontal", table: "Editor")
        case .flipVertical: String(localized: "Flip Vertical", table: "Editor")
        }
    }

    /// The command for the selected image layers.
    var layerTitle: String {
        switch self {
        case .rotateLeft: String(localized: "Rotate Layer Left", table: "Editor")
        case .rotateRight: String(localized: "Rotate Layer Right", table: "Editor")
        case .flipHorizontal: String(localized: "Flip Layer Horizontal", table: "Editor")
        case .flipVertical: String(localized: "Flip Layer Vertical", table: "Editor")
        }
    }

    var systemImage: String {
        switch self {
        case .rotateLeft: "rotate.left"
        case .rotateRight: "rotate.right"
        case .flipHorizontal: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .flipVertical: "arrow.up.and.down.righttriangle.up.righttriangle.down"
        }
    }

    /// The control's accessibility identifier after `image.` or `layer.`.
    var identifier: String {
        switch self {
        case .rotateLeft: "rotateLeft"
        case .rotateRight: "rotateRight"
        case .flipHorizontal: "flipHorizontal"
        case .flipVertical: "flipVertical"
        }
    }
}

extension CropAspect {
    var title: String {
        switch self {
        case .free: String(localized: "Free", table: "Editor")
        case .original: String(localized: "Original", table: "Editor")
        case .square: "1:1"
        case .fourByThree: "4:3"
        case .threeByTwo: "3:2"
        case .sixteenByNine: "16:9"
        case .nineBySixteen: "9:16"
        }
    }
}

/// The Image menu: turn or mirror the whole image, or the selected image layers. Each command
/// rechecks its live target when chosen and beeps without one.
struct EditorImageMenuItems: View {
    let model: EditorModel?

    var body: some View {
        ForEach(ImageTransform.allCases, id: \.self) { transform in
            Button(transform.imageTitle) {
                guard let target = EditorCommands.targetEditor()?.model, target.canTransformImage else {
                    return NSSound.beep()
                }
                target.transformImage(transform)
            }
            .disabled(model?.canTransformImage != true)
        }
        Divider()
        ForEach(ImageTransform.allCases, id: \.self) { transform in
            Button(transform.layerTitle) {
                guard let target = EditorCommands.targetEditor()?.model, target.canTransformLayers else {
                    return NSSound.beep()
                }
                target.transformSelectedLayers(transform)
            }
            .disabled(model?.canTransformLayers != true)
        }
    }
}
