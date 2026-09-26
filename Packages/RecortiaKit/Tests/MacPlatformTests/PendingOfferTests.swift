import Foundation
import Testing

@testable import MacPlatform

// Failure mode (Codex rerun): a promise-write completion from a dismissed or replaced drag offer
// resolved the *next* offer, reporting it delivered without its file being written.
@MainActor
@Suite("PendingOffer resolves only the offer a completion belongs to")
struct PendingOfferTests {
    @Test("A late completion of a replaced offer is ignored; the current offer still resolves")
    func staleCompletionIgnored() async {
        let offers = PendingOffer<String>()
        var firstID: UUID?
        let first = Task { await offers.wait { firstID = $0 } }
        await waitUntil { firstID != nil }
        offers.resolveCurrent(with: "canceled")  // a new deliver dismisses the previous offer
        #expect(await first.value == "canceled")

        var secondID: UUID?
        let second = Task { await offers.wait { secondID = $0 } }
        await waitUntil { secondID != nil }
        #expect(offers.resolve(firstID!, with: "delivered") == false, "stale completion must not resolve")
        #expect(offers.currentID == secondID)
        #expect(offers.resolve(secondID!, with: "delivered"))
        #expect(await second.value == "delivered")
    }

    @Test("Resolving with no offer pending does nothing")
    func resolveWithoutOffer() {
        let offers = PendingOffer<String>()
        offers.resolveCurrent(with: "canceled")
        #expect(offers.resolve(UUID(), with: "delivered") == false)
        #expect(offers.currentID == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }
}
