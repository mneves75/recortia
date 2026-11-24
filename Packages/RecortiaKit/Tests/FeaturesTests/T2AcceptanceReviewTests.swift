import Domain
import Foundation
import Testing

@testable import Features

// Independent acceptance review of train T2 (capture friction, export and privacy). Each test
// carries a planted control: the same steps without the stale event must write or keep, so a test
// that passes also shows it can see the write it forbids.
@Suite("T2 acceptance review")
@MainActor
struct T2AcceptanceReviewTests {

    // MARK: Quick-action thumbnail: stale consent and lifetime (B-1, ADR-009, FR-07)

    // Failure mode: a Replace answer given after the thumbnail ended overwrites a file for a
    // capture whose pixels were already released (consent outliving its capture).
    @Test(
        "A Replace answer after the thumbnail was dismissed overwrites nothing",
        arguments: [true, false])
    func replaceAfterDismiss(dismisses: Bool) async {
        let h = QuickActionsHarness()
        await h.shown()
        let url = URL(filePath: "/tmp/recortia-t2-review/capture.png")
        h.files.existing = [url]
        let question = Pending<Bool>()
        let save = Task {
            await h.model.save(choosing: { (url, .fixed(.png)) }, confirmReplacement: { _ in await question.wait() })
        }
        await waitFor("the Replace question is open") { question.waiterCount == 1 }
        if dismisses { h.model.dismiss() }
        question.resolve(true)
        let outcome = await save.value
        if dismisses {
            #expect(outcome == .canceled)
            #expect(h.files.saves.isEmpty, "consent for a dismissed capture must not overwrite")
        } else {
            // Control: the same answer on a live thumbnail does replace that file.
            #expect(outcome == .saved(url))
            #expect(h.files.saves.map(\.overwrite) == [true])
        }
        #expect(h.assets.released == h.assetIDs)
        #expect(!h.model.isShown)
    }

    // Failure mode: the next capture replaces the thumbnail while the previous one's Replace
    // question is open; answering it then overwrites with the old capture or disturbs the new one.
    @Test(
        "A Replace answer for a replaced thumbnail overwrites nothing and leaves the new one alone",
        arguments: [true, false])
    func replaceAfterNextCapture(replaced: Bool) async {
        let h = QuickActionsHarness()
        await h.shown()
        let first = h.assetIDs
        let url = URL(filePath: "/tmp/recortia-t2-review/capture.png")
        h.files.existing = [url]
        let question = Pending<Bool>()
        let save = Task {
            await h.model.save(choosing: { (url, .fixed(.png)) }, confirmReplacement: { _ in await question.wait() })
        }
        await waitFor("the Replace question is open") { question.waiterCount == 1 }
        let next = TestFixtures.session()
        if replaced { await h.shown(next) }
        question.resolve(true)
        let outcome = await save.value
        if replaced {
            #expect(outcome == .canceled)
            #expect(h.files.saves.isEmpty, "the old capture's consent must not write")
            #expect(h.model.capture?.session.document.id == next.document.id)
            #expect(h.model.isShown && !h.model.isActing, "the new thumbnail stays usable")
            #expect(h.assets.released == first, "only the replaced capture is released")
            await waitFor("the new thumbnail's timer runs") { h.clock.pendingSleepCount == 1 }
        } else {
            #expect(outcome == .saved(url))
            #expect(h.files.saves.count == 1)
        }
    }

    // Failure mode: the 8 s timeout fires while the person is in the save panel, releasing the
    // capture they are saving.
    @Test("The timeout cannot discard a capture while its save panel is open", arguments: [true, false])
    func timeoutDuringSavePanel(panelOpen: Bool) async {
        let h = QuickActionsHarness()
        await h.shown()
        await waitFor("the timer starts") { h.clock.pendingSleepCount == 1 }
        let url = URL(filePath: "/tmp/recortia-t2-review/new.png")
        let panel = Pending<URL?>()
        var save: Task<ExportOutcome, Never>?
        if panelOpen {
            save = Task {
                await h.model.save(
                    choosing: { await panel.wait().map { ($0, .fixed(.png)) } }, confirmReplacement: { _ in false })
            }
            await waitFor("the panel is open") { panel.waiterCount == 1 }
        }
        h.clock.advance(bySeconds: 60)
        await drain()
        if panelOpen {
            #expect(h.model.capture != nil && h.assets.released.isEmpty)
            panel.resolve(url)
            #expect(await save?.value == .saved(url))
            #expect(h.files.saves.map(\.url) == [url])
        } else {
            // Control: with no action the same minute ends the thumbnail.
            await waitFor("the timeout discards the capture") { h.model.capture == nil }
        }
        #expect(h.assets.released == h.assetIDs)
    }

    // MARK: Preferences compatibility (SPEC §7)

    /// Every key T2 added to the preferences blob.
    static let t2Keys = [
        "windowCaptureBackgroundChoice", "zoomsWithScrollWheelChoice", "reversesScrollWheelZoomChoice",
        "showsMenuBarIconChoice", "hasExplainedHiddenMenuBarIcon", "afterCaptureChoice",
        "automaticExportFormatChoice", "primaryRecognitionLanguage",
    ]

    // Failure modes: a T2 key written at its default changes every blob a rollback reads; a key
    // that older blobs lack but decoding requires resets every setting and the sealed consent.
    @Test("T2 keys are omitted at their defaults, and a blob without all of them loads unchanged")
    func t2KeysOptional() throws {
        let defaults = try Self.object(Preferences())
        #expect(Self.t2Keys.filter { defaults[$0] != nil } == [])

        // Control: each key is written once the person picks a value, so the names above are real.
        var chosen = Preferences()
        chosen.windowCaptureBackground = .solid(RGBA(r: 10, g: 20, b: 30))
        chosen.zoomsWithScrollWheel = true
        chosen.reversesScrollWheelZoom = true
        chosen.showsMenuBarIcon = false
        chosen.hasExplainedHiddenMenuBarIcon = true
        chosen.afterCapture = .showQuickActions
        chosen.exportFormat = .automatic
        chosen.primaryRecognitionLanguage = "pt-Latn-BR"
        chosen.captureDelaySeconds = 3
        let storage = MemoryPreferenceStorage()
        SettingsStore(storage: storage).update { $0 = chosen }
        let written = try #require(storage.values[SettingsStore.storageKey])
        var object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(Self.t2Keys.filter { object[$0] == nil } == [])
        #expect(SettingsStore(storage: storage).preferences == SettingsStore.sanitized(chosen))

        // A 0.15 blob: the same settings without any T2 key.
        for key in Self.t2Keys { object.removeValue(forKey: key) }
        let legacy = MemoryPreferenceStorage()
        legacy.setPreferenceData(try JSONSerialization.data(withJSONObject: object), forKey: SettingsStore.storageKey)
        let loaded = SettingsStore(storage: legacy)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.captureDelaySeconds == 3)
        var expected = SettingsStore.sanitized(chosen)
        expected.windowCaptureBackgroundChoice = nil
        expected.zoomsWithScrollWheelChoice = nil
        expected.reversesScrollWheelZoomChoice = nil
        expected.showsMenuBarIconChoice = nil
        expected.hasExplainedHiddenMenuBarIcon = nil
        expected.afterCaptureChoice = nil
        expected.automaticExportFormatChoice = nil
        expected.primaryRecognitionLanguage = nil
        #expect(loaded.preferences == expected)
    }

    // Failure mode: a sanitizer that is not idempotent makes every load differ from what was
    // stored, so each launch rewrites (and reseals) the blob, and `update` never settles.
    @Test("Sanitizing T2 fields twice changes nothing more than once")
    func sanitizedIsIdempotent() {
        var input = Preferences()
        input.primaryRecognitionLanguage = "pt-BR"
        input.windowCaptureBackground = .solid(RGBA(r: 1, g: 2, b: 3, a: 9))
        input.defaultExportFormat = .automatic
        input.afterCapture = .showQuickActions
        let once = SettingsStore.sanitized(input)
        #expect(SettingsStore.sanitized(once) == once)
        #expect(once.primaryRecognitionLanguage == "pt-Latn-BR")
        #expect(once.windowCaptureBackground == .solid(RGBA(r: 1, g: 2, b: 3)))
        #expect(once.defaultExportFormat == .png && once.exportFormat == .automatic)
        // Control: the input itself is not yet sanitized, so the comparison above can fail.
        #expect(once != input)
    }

    // MARK: Helpers

    private static func object(_ preferences: Preferences) throws -> [String: Any] {
        let data = try JSONEncoder().encode(preferences)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
