import Domain
import Foundation
import MacPlatform
import Testing

@testable import Features

/// B-9a: Print is an export like Copy, and HEIC is a saved-file format that falls back to PNG
/// where this Mac cannot encode it.
@Suite("Print and HEIC exports (B-9a)")
@MainActor
struct PrintAndHEICExportTests {
    let folder = URL(fileURLWithPath: "/tmp/recortia-tests/never-written", isDirectory: true)

    @Test("Print hands the pipeline's PNG snapshot to the print panel, whatever format saves use")
    func printTakesPNGSnapshot() async {
        let h = ExportHarness()
        h.settings.update {
            $0.exportFormat = .heic
            $0.jpegQuality = 0.6
        }
        #expect(await h.export(.print) == .printed)
        #expect(h.exporter.snapshotCount == 1)
        let printed = h.printer.presented
        #expect(printed.count == 1 && printed.first?.format == .png)
        #expect(printed.first?.documentID == h.session.document.id)
        #expect(h.clipboard.writes.isEmpty && h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
    }

    @Test("A print whose snapshot went stale reaches no print panel")
    func stalePrintRefused() async throws {
        let h = ExportHarness()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let outcome = h.export(.print)
        await waitFor("snapshotting") { pending.waiterCount == 1 }
        try h.session.addSecureMask(covering: Rect(x: 0, y: 0, width: 4, height: 4))
        pending.resolve(.success(()))
        #expect(await outcome == .failed(.staleDocument))
        #expect(h.printer.presented.isEmpty)
    }

    @Test("Print waits for no slot: another running export rejects it, and a sink failure is reported")
    func printBusyAndFailure() async {
        let h = ExportHarness()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let copy = h.export(.copy)
        await waitFor("snapshotting") { pending.waiterCount == 1 }
        #expect(await h.export(.print) == .rejectedBusy)
        pending.resolve(.success(()))
        #expect(await copy == .copied)
        #expect(h.printer.presented.isEmpty)

        h.exporter.pending = nil
        h.printer.error = .printFailed
        #expect(await h.export(.print) == .failed(.printFailed))
        #expect(h.coordinator.state == .failed(.printFailed))
    }

    @Test("A printed document still asks before closing: the print panel may be canceled")
    func printDoesNotMarkSaved() async {
        let h = EditorHarness()
        await h.settle()
        h.model.selectTool(.rectangle)
        h.drag((10, 10), (60, 50))
        #expect(h.model.isDirty)
        #expect(await h.model.export(.print) == .printed)
        #expect(h.printer.presented.count == 1 && h.model.isDirty)
        #expect(h.model.notice == .exported(.printed))
    }

    @Test("Saved files use HEIC at the shared quality; Copy and Automatic stay PNG or JPEG")
    func heicOptions() async {
        let h = ExportHarness()
        h.settings.update {
            $0.exportFormat = .heic
            $0.jpegQuality = 0.7
        }
        _ = await h.export(.saveToFolder(folder))
        #expect(h.files.uniqueSaves.first?.snapshot.format == .heic(quality: 0.7))
        _ = await h.export(.copy)
        #expect(h.clipboard.writes.first?.format == .png)
        #expect(
            ExportCoordinator.named(URL(fileURLWithPath: "/tmp/a.png"), for: .heic(quality: 0.7)).lastPathComponent
                == "a.heic")
        h.settings.update { $0.exportFormat = .automatic }
        #expect(h.settings.exportOptions.formatChoice == .automatic)
    }

    @Test("Without a HEIC encoder a stored HEIC choice exports PNG and stays stored, unrewritten")
    func heicUnavailableFallsBack() throws {
        let storage = MemoryPreferenceStorage()
        SettingsStore(storage: storage).update {
            $0.exportFormat = .heic
            $0.jpegQuality = 0.7
        }
        let written = try #require(storage.values[SettingsStore.storageKey])
        let writes = storage.writeCount

        let store = SettingsStore(storage: storage, encodesHEIC: false)
        #expect(store.preferences.exportFormat == .heic)
        #expect(store.exportOptions.formatChoice == .fixed(.png))
        #expect(storage.values[SettingsStore.storageKey] == written && storage.writeCount == writes)
        // Control: where HEIC encodes, the same bytes export HEIC.
        #expect(SettingsStore(storage: storage, encodesHEIC: true).exportOptions.format == .heic(quality: 0.7))
    }
}
