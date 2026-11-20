import SwiftUI

/// The chrome's one set of shape, spacing and notice values (program 2026-11 design direction).
/// Window corners stay the system's; nothing here hard-codes them.
enum DesignTokens {
    enum Radius {
        /// Swatches, tiles and small wells.
        static let control: CGFloat = 6
        /// Grouped boxes, notices and panels.
        static let container: CGFloat = 10
    }

    /// The only paddings and spacings.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
    }

    /// One selection idiom everywhere: list rows, tiles and swatches.
    static let selection = Color.accentColor
}

extension View {
    /// The one inline-notice style: a symbol and text on a quaternary fill.
    func noticeStyle() -> some View {
        padding(.horizontal, DesignTokens.Space.s)
            .padding(.vertical, DesignTokens.Space.xs)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.container))
    }
}
