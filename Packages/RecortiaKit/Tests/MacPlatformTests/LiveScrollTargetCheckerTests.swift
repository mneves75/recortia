import CoreGraphics
import Domain
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

    @Test("Scrolling and capture select the same layered foreign window", arguments: [0, 3, 20])
    func sharedFrontmostSelection(layer: Int) {
        let own = entry(id: 10, pid: ownPID, layer: 99)
        let floating = entry(id: 2, pid: 200, layer: layer)
        let target = entry(id: 1, pid: 100, layer: 0)
        let elsewhere = entry(id: 3, pid: 300, layer: 30, bounds: CGRect(x: 200, y: 200, width: 10, height: 10))
        for entries in [[own, [:], elsewhere, floating, target], [own, target], [own, [:], elsewhere]] {
            let checked = LiveScrollTargetChecker.frontmostWindow(in: entries, at: point, excluding: ownPID)?.id
            let helper = ScrollFrameSource.frontmostWindowID(
                in: entries, at: Point(x: point.x, y: point.y), excluding: ownPID)
            #expect(helper == checked)
            if entries.count == 5 { #expect(helper == 2) }
        }
    }
}
