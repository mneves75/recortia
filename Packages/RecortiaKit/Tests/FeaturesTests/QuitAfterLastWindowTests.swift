import Testing

@testable import Features

// Failure mode (data loss): quitting after the last window closes while an automatic save or
// another export has not finished cuts its write off. A window the person still has, a capture
// in progress, or the default preference must keep Recortia running.
@Suite("Quit after the last window (FR-01)")
struct QuitAfterLastWindowTests {
    @Test("Quits only when the preference is off, nothing is exporting, and no window or capture remains")
    func decision() {
        func decide(keeps: Bool = false, exporting: Bool = false, window: Bool = false, capturing: Bool = false)
            -> QuitAfterLastWindow
        {
            QuitAfterLastWindow.decide(
                keepsRunningInMenuBar: keeps, isExporting: exporting, hasUserWindow: window, isCapturing: capturing)
        }
        #expect(decide() == .quit)
        #expect(decide(keeps: true) == .stay)
        #expect(decide(keeps: true, exporting: true) == .stay)
        #expect(decide(exporting: true) == .wait, "an unfinished export is waited for, never cut off")
        #expect(decide(exporting: true, window: true) == .wait, "a failure alert during the export is not a reason to give up")
        #expect(decide(window: true) == .stay)
        #expect(decide(capturing: true) == .stay)
    }
}
