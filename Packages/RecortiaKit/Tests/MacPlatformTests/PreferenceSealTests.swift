import Foundation
import Testing

@testable import MacPlatform

// Failure modes (Codex review): (1) a same-user process restores an older, validly sealed
// preferences blob after the user turned automatic export off (replay); (2) the secret is
// replaced or missing. Each seal advances a generation kept with the secret, so only the latest
// blob verifies; a missing or different secret fails closed. Keeping another process from
// replacing the secret is the data-protection keychain's job (DataProtectionSealStore).
@MainActor
@Suite("Preference seal: latest generation only, fail closed")
struct PreferenceSealTests {
    final class MemoryStore: SealSecretStore {
        var secret: SealSecret?
        var failSaves = false
        func load() -> SealSecret? { secret }
        func save(_ secret: SealSecret) -> Bool {
            guard !failSaves else { return false }
            self.secret = secret
            return true
        }
    }

    let consentOn = Data(#"{"autoCopy":true}"#.utf8)
    let consentOff = Data(#"{"autoCopy":false}"#.utf8)

    @Test("The latest sealed blob verifies")
    func roundTrip() throws {
        let seal = PreferenceSeal(store: MemoryStore())
        let tag = try #require(seal.seal(consentOn))
        #expect(seal.verify(consentOn, seal: tag))
        #expect(!seal.verify(consentOff, seal: tag))
    }

    @Test("An older sealed blob replayed after a newer save does not verify")
    func replayFails() throws {
        let seal = PreferenceSeal(store: MemoryStore())
        let old = try #require(seal.seal(consentOn))
        let new = try #require(seal.seal(consentOff))
        #expect(!seal.verify(consentOn, seal: old), "replayed consent must not verify")
        #expect(seal.verify(consentOff, seal: new))
    }

    @Test("Replay fails across a relaunch that reads the same store")
    func replayFailsAcrossRelaunch() throws {
        let store = MemoryStore()
        let old = try #require(PreferenceSeal(store: store).seal(consentOn))
        _ = PreferenceSeal(store: store).seal(consentOff)
        #expect(!PreferenceSeal(store: store).verify(consentOn, seal: old))
    }

    @Test("A missing or replaced secret fails closed")
    func missingOrReplacedSecretFails() throws {
        let store = MemoryStore()
        let tag = try #require(PreferenceSeal(store: store).seal(consentOn))
        let kept = store.secret
        store.secret = nil
        #expect(!PreferenceSeal(store: store).verify(consentOn, seal: tag))
        store.secret = SealSecret(key: Data(repeating: 9, count: 32), generation: kept?.generation ?? 0)
        #expect(!PreferenceSeal(store: store).verify(consentOn, seal: tag))
    }

    @Test("When the secret cannot be saved nothing is sealed")
    func saveFailureSealsNothing() {
        let store = MemoryStore()
        store.failSaves = true
        #expect(PreferenceSeal(store: store).seal(consentOn) == nil)
    }

    @Test("prepare() creates a secret once and keeps it")
    func prepareCreatesOnce() throws {
        let store = MemoryStore()
        let seal = PreferenceSeal(store: store)
        seal.prepare()
        let first = try #require(store.secret)
        #expect(first.key.count == 32)
        seal.prepare()
        #expect(store.secret == first)
    }
}
