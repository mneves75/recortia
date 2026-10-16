import Domain
import Testing

@testable import Features

@Suite("Editor window size (FR-04)")
struct EditorWindowSizingTests {
    // The E2E scenario `editor-window-size` covers the same size per capture and reuse of the
    // resized size. These cases only matter on another screen or with a corrupted setting.
    @Test("A remembered size fits a smaller screen, and an unusable one falls back to the default")
    func screenAndCorruptedSize() {
        let laptop = Size<DesktopSpace>(width: 1440, height: 875)
        let fromExternalDisplay = EditorWindowSizing.initialContentSize(
            remembered: Size(width: 2400, height: 1300), visibleFrame: laptop)
        #expect(fromExternalDisplay.width <= laptop.width * 0.92 && fromExternalDisplay.height <= laptop.height * 0.92)
        let corrupted = EditorWindowSizing.initialContentSize(
            remembered: Size(width: .nan, height: 700), visibleFrame: laptop)
        #expect(corrupted == Size(width: 1100, height: 720))
    }
}
