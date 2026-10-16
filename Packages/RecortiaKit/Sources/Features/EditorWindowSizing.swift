import Domain

/// Editor window content size (FR-04). Every editor opens at the same size, whatever it shows:
/// the size the user last resized an editor to, or the default, limited to the target screen.
/// The canvas fits the image inside that size.
public enum EditorWindowSizing {
    public static let minimumContentSize = Size<DesktopSpace>(width: 980, height: 560)
    public static let defaultContentSize = Size<DesktopSpace>(width: 1100, height: 720)
    /// Leaves room around the window on the target screen.
    static let screenFraction = 0.92
    static let maximumSide = 32_768.0

    public static func initialContentSize(
        remembered: Size<DesktopSpace>?, visibleFrame: Size<DesktopSpace>
    ) -> Size<DesktopSpace> {
        let base = remembered.flatMap(rememberable) ?? defaultContentSize
        return Size(
            width: min(base.width, visibleFrame.width * screenFraction),
            height: min(base.height, visibleFrame.height * screenFraction))
    }

    /// A size worth remembering: finite, at least the editor minimum and at most `maximumSide`.
    public static func rememberable(_ size: Size<DesktopSpace>) -> Size<DesktopSpace>? {
        let sides = [size.width, size.height]
        guard sides.allSatisfy({ $0.isFinite && $0 <= maximumSide }),
            size.width >= minimumContentSize.width, size.height >= minimumContentSize.height
        else { return nil }
        return size
    }
}
