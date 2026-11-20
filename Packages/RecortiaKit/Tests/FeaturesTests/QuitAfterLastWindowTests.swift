import Testing

@testable import Features

// Failure mode (data loss): quitting after the last window closes while an automatic save or
// another export has not finished cuts its write off; quitting while an Open With request is
// still opening files drops the rest of them and their refusal report (T1 security 4A). A window the person still has, a capture
// in progress, or the default preference must keep Recortia running.
@Suite("Quit after the last window (FR-01)")
struct QuitAfterLastWindowTests {
    @Test("Quits only when the preference is off, nothing is exporting, and no window or capture remains")
    func decision() {
        func decide(
            keeps: Bool = false, exporting: Bool = false, opening: Bool = false, window: Bool = false,
            capturing: Bool = false
        ) -> QuitAfterLastWindow {
            QuitAfterLastWindow.decide(
                keepsRunningInMenuBar: keeps, isExporting: exporting, isOpeningFiles: opening, hasUserWindow: window,
                isCapturing: capturing)
        }
        #expect(decide() == .quit)
        #expect(decide(keeps: true) == .stay)
        #expect(decide(keeps: true, exporting: true) == .stay)
        #expect(decide(exporting: true) == .wait, "an unfinished export is waited for, never cut off")
        #expect(
            decide(exporting: true, capturing: true) == .stay,
            "a new capture cancels pending autoquit even while the previous export is unfinished")
        #expect(
            decide(exporting: true, window: true) == .wait,
            "a failure alert during the export is not a reason to give up")
        #expect(
            decide(opening: true) == .wait,
            "files still opening from one Open With request are waited for, with their refusals reported")
        #expect(decide(keeps: true, opening: true) == .stay)
        #expect(decide(opening: true, capturing: true) == .stay)
        #expect(decide(window: true) == .stay)
        #expect(decide(capturing: true) == .stay)
    }
}
