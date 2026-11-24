import Domain
import Foundation
import Testing

@testable import Features

/// Reopen Closed Capture (B-6): one slot in memory, holding the last closed editor's document and
/// its pixels until it is taken, replaced, expires or the app quits; never a masking-pending one.
@Suite("Reopen Closed Capture: one memory-only slot (B-6)")
@MainActor
struct ClosedCaptureSlotTests {
    /// An unexported document with a secure mask, so its privacy epoch is above zero.
    static func editedSession() throws -> DocumentSession {
        var session = EditorFixtures.session()
        try session.addSecureMask(covering: Rect(x: 10, y: 10, width: 40, height: 20))
        return session
    }

    static func editor(_ h: EditorHarness, _ session: DocumentSession, autoRedacts: Bool = false) -> EditorModel {
        EditorModel(session: session, environment: h.model.environment, autoRedacts: autoRedacts)
    }

    @Test("Closing keeps the document as it was, without history, still unexported, and writes nothing")
    func keepsLastClosedDocument() async throws {
        let storage = MemoryPreferenceStorage()
        let h = EditorHarness(settings: SettingsStore(storage: storage))
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let model = Self.editor(h, try Self.editedSession())
        await drain()
        let closed = model.session
        let writes = storage.writeCount
        #expect(model.isKeptOnClose)

        slot.close(model)
        #expect(model.isClosed)
        #expect(!slot.isEmpty)
        #expect(h.assets.released.isEmpty, "the kept document's pixels stay in the store")

        let reopened = try #require(slot.take())
        #expect(slot.isEmpty)
        #expect(slot.take() == nil, "taking empties the slot")
        #expect(reopened.document == closed.document)
        #expect(reopened.isDirty, "unexported edits stay unexported")
        #expect(!reopened.canUndo && !reopened.canRedo, "undo history is not restored")
        // The same document ID comes back, so pins rendered before a later mask must still be
        // invalidated by it (RED-03): the epoch never goes back.
        #expect(reopened.privacyEpoch == closed.privacyEpoch && reopened.privacyEpoch > 0)
        #expect(reopened.revision == closed.revision)

        // Memory only: no preference, file, clipboard or export write.
        #expect(storage.writeCount == writes)
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty && h.clipboard.writes.isEmpty)
        #expect(h.exporter.snapshotCount == 0)

        // The pixels now belong to whoever took the document; the expiry no longer runs.
        h.clock.advance(bySeconds: 3600)
        await drain()
        #expect(h.assets.released.isEmpty)
    }

    @Test("A newer close replaces the kept document and releases its pixels")
    func newerCloseReplaces() async throws {
        let h = EditorHarness()
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let first = Self.editor(h, try Self.editedSession())
        let second = Self.editor(h, EditorFixtures.session())
        let firstAssets = Set(first.document.assets.keys)

        slot.close(first)
        slot.close(second)
        #expect(Set(h.assets.released) == firstAssets)
        #expect(slot.take()?.document == second.document)
    }

    @Test("The document expires 10 minutes after its close; a newer close starts its own 10 minutes")
    func expiresAfterTenMinutes() async throws {
        let h = EditorHarness()
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let first = Self.editor(h, try Self.editedSession())
        let second = Self.editor(h, EditorFixtures.session())
        let firstAssets = Set(first.document.assets.keys)
        let secondAssets = Set(second.document.assets.keys)

        slot.close(first)
        await drain()
        h.clock.advance(bySeconds: 300)
        slot.close(second)
        await drain()
        h.clock.advance(bySeconds: 300)
        await drain()
        #expect(!slot.isEmpty, "the replaced document's expiry was cancelled")
        #expect(Set(h.assets.released) == firstAssets)

        h.clock.advance(bySeconds: 299)
        await drain()
        #expect(!slot.isEmpty)
        h.clock.advance(bySeconds: 1)
        await drain()
        #expect(slot.isEmpty)
        #expect(Set(h.assets.released) == firstAssets.union(secondAssets))
    }

    @Test("An expiry that comes due as a newer close replaces its document does not clear the newer one")
    func dueExpiryDoesNotClearNewerClose() async throws {
        let h = EditorHarness()
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let first = Self.editor(h, try Self.editedSession())
        let second = Self.editor(h, EditorFixtures.session())

        slot.close(first)
        await drain()
        // The first expiry's sleep ends here; its task has not run again yet.
        h.clock.advance(bySeconds: 600)
        slot.close(second)
        await drain()
        #expect(slot.take()?.document == second.document)
    }

    @Test("Quitting clears the slot and releases the pixels")
    func clearReleases() throws {
        let h = EditorHarness()
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let model = Self.editor(h, try Self.editedSession())
        let assets = Set(model.document.assets.keys)

        slot.close(model)
        slot.clear()
        #expect(slot.isEmpty)
        #expect(Set(h.assets.released) == assets)
        #expect(slot.take() == nil)
    }

    @Test("Masking still pending, or failed even once its notice is dismissed, is not kept: the close releases it")
    func maskingFailsClosed() async throws {
        let h = EditorHarness()
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let earlier = Self.editor(h, EditorFixtures.session())
        slot.close(earlier)

        h.sensitiveText.pending = Pending<Void>()
        let pending = Self.editor(h, EditorFixtures.session(), autoRedacts: true)
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        #expect(!pending.isKeptOnClose)
        slot.close(pending)
        #expect(pending.isClosed)
        #expect(slot.isEmpty, "the newest close decides; an older document does not come back in its place")
        #expect(
            Set(h.assets.released) == Set(earlier.document.assets.keys).union(pending.document.assets.keys))

        h.sensitiveText.pending = nil
        h.sensitiveText.error = TestError()
        let failed = Self.editor(h, EditorFixtures.session(), autoRedacts: true)
        await waitFor("masking failed") { failed.autoRedaction == .failed }
        #expect(failed.notice == .maskingFailed)
        failed.post(.colorCopied)
        #expect(!failed.isKeptOnClose, "a notice that replaced the failure is not the person's acknowledgement")
        slot.close(failed)
        #expect(slot.isEmpty)
        #expect(h.assets.released.contains { failed.document.assets[$0] != nil })

        // Dismissal is not completion, and a timeout dismisses the notice without the person:
        // a reopened editor would show the unmasked capture with no failure notice.
        let dismissed = Self.editor(h, EditorFixtures.session(), autoRedacts: true)
        await waitFor("masking failed") { dismissed.autoRedaction == .failed }
        dismissed.dismissNotice()
        #expect(!dismissed.isKeptOnClose)
        slot.close(dismissed)
        #expect(slot.take() == nil)
        #expect(h.assets.released.contains { dismissed.document.assets[$0] != nil })
    }
    @Test("A timer that fires late does not extend the 10 minutes: the slot checks its own deadline")
    func lateTimerDoesNotExtendLifetime() async {
        let h = EditorHarness()
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let editor = Self.editor(h, EditorFixtures.session())
        slot.close(editor)
        // App Nap or a wake from sleep: time passes but the expiry task has not run yet.
        h.clock.stall(bySeconds: 10 * 60 - 1)
        #expect(!slot.isEmpty, "still within its lifetime")
        h.clock.stall(bySeconds: 1)
        #expect(slot.isEmpty)
        #expect(slot.take() == nil)
        #expect(Set(h.assets.released) == Set(editor.document.assets.keys), "the expired pixels are released")
    }

    // An expiry task that starts late (the main actor was busy, App Nap) must still release the
    // pixels at the close's deadline, not a full lifetime after the task began; nothing needs to
    // call `take()` for that to happen.
    @Test("A late-starting expiry task releases the pixels at the original deadline")
    func lateStartReleasesAtDeadline() async {
        let h = EditorHarness()
        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let editor = Self.editor(h, EditorFixtures.session())
        slot.close(editor)
        h.clock.stall(bySeconds: 9 * 60)
        await drain()
        h.clock.advance(bySeconds: 60)
        await drain()
        #expect(Set(h.assets.released) == Set(editor.document.assets.keys), "pixels kept past the deadline")
    }
}
