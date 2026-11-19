import CoreGraphics

/// The editor chrome's few shared shape constants. Spacing uses the 4/8/12/16/24 scale inline.
enum EditorMetrics {
    /// Small fills and outlines: color swatches and chips, badges, boxed-text previews.
    static let chipRadius: CGFloat = 4
    /// Choice tiles and the selection ring around a swatch (a 4 pt chip inset by 4 pt).
    static let tileRadius: CGFloat = 8
}
