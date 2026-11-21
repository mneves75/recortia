import Domain
import Foundation
import Imaging
import Testing

@testable import Features

/// Independent review of trains T5 and T6 (B-6, FP-024, PREF-01): cases the slice's own tests do
/// not exercise.
@Suite("Review: Reopen Closed Capture and settings compatibility (T5, T6)")
@MainActor
struct T5T6ReviewTests {
    static func editor(_ h: EditorHarness, _ session: DocumentSession) -> EditorModel {
        EditorModel(session: session, environment: h.model.environment, autoRedacts: false)
    }

    // Failure mode: a text-only redaction whose line masks have not landed is masking in
    // progress (`isMaskingPending`); keeping it would reopen a document whose redaction never
    // settled, with no notice.
    @Test("A close while a text-only redaction is still recognizing lines keeps nothing")
    func pendingTextRedactionIsNotKept() async throws {
        let h = EditorHarness()
        h.sensitiveText.lines = [PixelRect(x: 24, y: 26, width: 150, height: 22)]
        h.sensitiveText.pending = Pending<Void>()
        h.model.setRedactsTextOnly(true)
        h.model.selectTool(.redact)
        h.drag((20, 20), (220, 120))
        await waitFor("recognition started") { h.sensitiveText.pending?.waiterCount == 1 }
        // Control: the redaction really is pending, and only it blocks keeping the document.
        try #require(h.model.isMaskingPending && h.model.autoRedaction == .off)
        #expect(!h.model.isKeptOnClose)

        let slot = ClosedCaptureSlot(assets: h.assets, clock: h.clock)
        let assets = Set(h.model.document.assets.keys)
        slot.close(h.model)
        #expect(h.model.isClosed)
        #expect(slot.isEmpty && slot.take() == nil)
        #expect(assets.isSubset(of: Set(h.assets.released)), "the close released its pixels")

        // Settling after the close changes nothing.
        h.sensitiveText.pending?.resolve(())
        await drain()
        #expect(slot.isEmpty)
    }

    // Failure mode (PREF-01): a sealed blob written before T5/T6 has none of their keys; if any
    // new field were required, the blob would fail to decode and every setting, sealed consent
    // included, would reset. A legacy `updateChecksEnabled` must not turn automatic checks on.
    @Test("A sealed blob without any T5/T6 key loads unchanged, consent kept, every new feature off")
    func preT5BlobLoads() throws {
        var stored = Preferences()
        stored.autoCopy = true
        stored.updateChecksEnabled = true
        stored.exportFormat = .jpeg
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        for key in [
            "heicExportFormatChoice", "writesDiagnosticsFileChoice", "scrollCaptureDirectionChoice",
            "checksForUpdatesAutomaticallyChoice",
        ] {
            object[key] = nil
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let storage = MemoryPreferenceStorage()
        let integrity = FixedKeyPreferenceIntegrity()
        storage.values[SettingsStore.storageKey] = data
        storage.values[SettingsStore.sealKey] = integrity.seal(data)

        let loaded = SettingsStore(storage: storage, integrity: integrity)
        #expect(loaded.loadIssue == nil)
        #expect(loaded.preferences.autoCopy, "the old seal still verifies")
        #expect(loaded.preferences.exportFormat == .jpeg)
        #expect(!loaded.preferences.checksForUpdatesAutomatically, "the legacy key is never read")
        #expect(!loaded.preferences.writesDiagnosticsFile)
        #expect(loaded.preferences.scrollCaptureDirection == .vertical)
        #expect(loaded.exportOptions.formatChoice == .fixed(.jpeg(quality: stored.jpegQuality)))
    }

    // Failure mode (PRIV-01): an unsealed blob may turn on automatic update checks only through
    // the side-effect consent path; with no other side effect, the flag alone must still be
    // treated as consent and dropped.
    @Test("An unsealed blob whose only side effect is automatic update checks loads with them off")
    func unsealedUpdateChecksAlone() throws {
        var stored = Preferences()
        stored.checksForUpdatesAutomatically = true
        try #require(stored.grantsSideEffects)
        let storage = MemoryPreferenceStorage()
        storage.values[SettingsStore.storageKey] = try JSONEncoder().encode(stored)
        let loaded = SettingsStore(storage: storage, integrity: FixedKeyPreferenceIntegrity())
        #expect(loaded.loadIssue == .unverifiedConsent)
        #expect(!loaded.preferences.checksForUpdatesAutomatically)

        let model = UpdaterModel(service: nil, settings: loaded)
        model.start()
        #expect(model.status == .unavailable && !model.isOffered && !model.canCheck)
    }
}
