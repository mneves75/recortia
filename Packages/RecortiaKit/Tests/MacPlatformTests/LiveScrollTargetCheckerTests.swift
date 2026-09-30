import CoreGraphics
import Testing

@testable import MacPlatform

// Failure modes: a foreign floating panel is skipped and its pixels enter the stream;
// an own-app HUD is mistaken for the target; a malformed or off-point entry masks a valid target.
@MainActor
struct LiveScrollTargetCheckerTests {
    private let point = CGPoint(x: 50, y: 50)
    private let ownPID: Int32 = 400

    private func entry(id: UInt32, pid: Int32, layer: Int, bounds: CGRect? = nil) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: (bounds ?? CGRect(x: 0, y: 0, width: 100, height: 100)).dictionaryRepresentation,
        ]
    }

    @Test("The frontmost foreign window wins at every window level")
    func floatingOccluderWins() {
        let target = entry(id: 1, pid: 100, layer: 0)
        let panel = entry(id: 2, pid: 200, layer: 3)
        let selected = LiveScrollTargetChecker.frontmostWindow(in: [panel, target], at: point, excluding: ownPID)
        #expect(selected?.id == 2)
        #expect(selected?.ownerPID == 200)
    }

    @Test("Recortia panels, malformed entries, and off-point windows do not change the target")
    func excludedAndOffPointWindows() {
        let own = entry(id: 3, pid: ownPID, layer: 5)
        let elsewhere = entry(id: 4, pid: 200, layer: 3, bounds: CGRect(x: 200, y: 200, width: 50, height: 50))
        let target = entry(id: 1, pid: 100, layer: 0)
        let selected = LiveScrollTargetChecker.frontmostWindow(
            in: [own, [:], elsewhere, target], at: point, excluding: ownPID)
        #expect(selected?.id == 1)
        #expect(
            LiveScrollTargetChecker.frontmostWindow(in: [own, [:], elsewhere], at: point, excluding: ownPID) == nil)
    }
}
