import CoreGraphics
import Testing

@testable import Features

// Failure modes (ADR-007 amendment, FR-09): a click-through pin that is not on top, which clicks
// would bury behind the window they reach; a click-through pin nothing can unlock; Unlock All
// offered with nothing to unlock, or missing while a pin ignores the mouse; a new pin that
// inherits a locked state and starts out unreachable.
@Suite("Pin Keep on Top and click-through (ADR-007 amendment)")
@MainActor
struct PinLayeringTests {
    private func addPin(_ h: PinsHarness) throws -> PinID {
        try h.model.add(try #require(makeImage()), source: nil, displayScale: 1)
    }

    @Test("Click-through needs Keep on Top, and turning Keep on Top off unlocks the pin")
    func clickThroughNeedsKeepOnTop() throws {
        let h = PinsHarness()
        let id = try addPin(h)
        h.model.setClickThrough(true, for: id)
        #expect(h.model.pin(for: id)?.isClickThrough == false, "a normal-level pin never ignores the mouse")

        h.model.setKeepsOnTop(true, for: id)
        h.model.setClickThrough(true, for: id)
        #expect(h.model.pin(for: id)?.keepsOnTop == true)
        #expect(h.model.pin(for: id)?.isClickThrough == true)

        h.model.setKeepsOnTop(false, for: id)
        #expect(h.model.pin(for: id)?.keepsOnTop == false)
        #expect(h.model.pin(for: id)?.isClickThrough == false, "leaving the top level also ends click-through")
    }

    @Test("Unlock All Pins ends click-through on every pin and keeps them on top")
    func unlockAllClearsEveryPin() throws {
        let h = PinsHarness()
        let ids = try (0..<3).map { _ in try addPin(h) }
        for id in ids {
            h.model.setKeepsOnTop(true, for: id)
            h.model.setClickThrough(true, for: id)
        }
        h.model.unlockAll()
        #expect(h.model.pins.allSatisfy { !$0.isClickThrough })
        #expect(h.model.pins.allSatisfy { $0.keepsOnTop }, "unlocking does not change the window level")
    }

    @Test("Unlock All Pins is available only while a pin is click-through")
    func unlockAvailability() throws {
        let h = PinsHarness()
        #expect(!h.model.hasClickThroughPin, "no pins")
        let first = try addPin(h)
        let second = try addPin(h)
        h.model.setKeepsOnTop(true, for: first)
        #expect(!h.model.hasClickThroughPin, "on top but still interactive")
        h.model.setClickThrough(true, for: first)
        #expect(h.model.hasClickThroughPin)
        h.model.setKeepsOnTop(true, for: second)
        h.model.setClickThrough(true, for: second)
        h.model.setClickThrough(false, for: first)
        #expect(h.model.hasClickThroughPin, "one locked pin is enough")
        h.model.close(second)
        #expect(!h.model.hasClickThroughPin, "closing the last locked pin leaves nothing to unlock")
    }

    @Test("A pin added after Unlock All starts normal-level and interactive")
    func newPinStartsUnlocked() throws {
        let h = PinsHarness()
        let locked = try addPin(h)
        h.model.setKeepsOnTop(true, for: locked)
        h.model.setClickThrough(true, for: locked)
        h.model.unlockAll()
        let added = try #require(h.model.pin(for: try addPin(h)))
        #expect(!added.keepsOnTop, "ADR-007: a new pin is a normal-level window")
        #expect(!added.isClickThrough)
        #expect(!h.model.hasClickThroughPin)
    }
}
