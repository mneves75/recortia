import CoreGraphics
import Testing

@testable import MacPlatform

// Failure mode (Codex review): a Recortia panel that closes while shareable content is fetched
// disappears from the fresh window list; counting its ID as "foreign" switched capture to a
// static window list, so Recortia windows created later (pins, the drag chip) entered frames.
@Suite("Capture exclusion treats only present, non-Recortia windows as foreign")
struct CaptureExclusionTests {
    let own: pid_t = 100

    @Test("A requested Recortia window that vanished is not foreign")
    func vanishedOwnWindowIsNotForeign() {
        let present = [CaptureExclusion.Window(id: 7, ownerPID: own)]
        #expect(CaptureExclusion.foreignWindowIDs(requested: [5, 7], present: present, ownPID: own).isEmpty)
    }

    @Test("A requested window of another app that is present is foreign")
    func presentForeignWindowIsForeign() {
        let present = [CaptureExclusion.Window(id: 7, ownerPID: own), CaptureExclusion.Window(id: 9, ownerPID: 200)]
        #expect(CaptureExclusion.foreignWindowIDs(requested: [7, 9, 11], present: present, ownPID: own) == [9])
    }
}
