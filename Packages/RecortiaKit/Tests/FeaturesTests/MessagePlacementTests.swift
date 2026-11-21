import Testing

@testable import Features

// Failure mode (lost failure report): an automatic-export failure about an editor shown as a sheet
// on a window that is closed, minimized, hidden or on another Space is never seen, so a save that
// left a partial file or wrote nothing goes unreported. Only an editor the person can see takes it.
@Suite("Message placement (design direction: Alerts)")
struct MessagePlacementTests {
    @Test("A message about an editor is a sheet only on an open editor the person can see")
    func placement() {
        #expect(MessagePlacement(editorIsOpen: true, windowIsOnScreen: true) == .editorSheet)
        #expect(
            MessagePlacement(editorIsOpen: false, windowIsOnScreen: true) == .appAlert,
            "a closed editor's report is an app alert, never dropped")
        #expect(
            MessagePlacement(editorIsOpen: true, windowIsOnScreen: false) == .appAlert,
            "a minimized, hidden or other-Space editor's report is an app alert on the current Space")
        #expect(MessagePlacement(editorIsOpen: false, windowIsOnScreen: false) == .appAlert)
    }
}
