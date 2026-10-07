import CoreGraphics
import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-09, PIN-02, ADR-007): exporting a pin that never went through the sanitizing
// renderer; a pin closed, invalidated by a redaction, or removed by Close All while its export is
// encoding or its drag offer waits; exporting at the user's 2x default instead of the pinned
// raster; a second export while one runs; an export that touches a sink before it is current.
@MainActor
final class PinsExportHarness {
    let renderer = FakeRenderService()
    let exporter = FakeExportService()
    let clipboard = FakeClipboard()
    let drag = FakeDragSink()
    let settings = SettingsStore(storage: MemoryPreferenceStorage())
    let export: ExportCoordinator
    let model: PinsModel

    init() {
        export = ExportCoordinator(
            exporter: exporter, clipboard: clipboard, files: FakeFileSink(), drag: drag, folders: FakeSaveFolders(),
            clock: ManualClock(), settings: settings)
        model = PinsModel(renderer: renderer, settings: settings, export: export)
    }

    func pinned(_ session: DocumentSession = TestFixtures.session()) async throws -> PinID {
        try await model.pin(session, currentSession: { session })
    }
}

@Suite("Pin copy and drag-out (FR-09, PIN-02)")
@MainActor
struct PinsExportTests {
    @Test("Copy encodes the pinned raster once and writes it under the pin's export identity")
    func copy() async throws {
        let h = PinsExportHarness()
        let id = try await h.pinned()
        let pin = try #require(h.model.pin(for: id))
        let exportID = try #require(pin.exportID)

        #expect(await h.model.export(.copy, id) == .copied)
        #expect(h.exporter.pinnedRequests.count == 1)
        #expect(h.exporter.pinnedRequests.first?.image === pin.image, "the pinned sanitized raster, not a new render")
        #expect(h.exporter.pinnedRequests.first?.options.format == .png)
        #expect(h.clipboard.writes.map(\.documentID) == [exportID])
        #expect(h.exporter.snapshotCount == 0, "no document export ran")
    }

    @Test("Drag-out uses the export format but always the pinned raster's own size")
    func dragOptions() async throws {
        let h = PinsExportHarness()
        h.settings.update {
            $0.defaultExportFormat = .jpeg
            $0.defaultExportScale = 2
        }
        let id = try await h.pinned()
        #expect(await h.model.export(.drag, id) == .dragged)
        let options = try #require(h.exporter.pinnedRequests.first?.options)
        #expect(options.scale == 1)
        if case .jpeg = options.format {} else { Issue.record("drag uses the default format, got \(options.format)") }
        #expect(h.drag.writtenSnapshots.count == 1)
    }

    @Test("A pin added from a raw image is not exportable and touches no sink")
    func rawPinRefused() async throws {
        let h = PinsExportHarness()
        let image = try #require(makeImage())
        let id = try h.model.add(image, source: nil, displayScale: 1)
        #expect(h.model.pin(for: id)?.exportID == nil)
        #expect(await h.model.export(.copy, id) == .failed(.staleDocument))
        #expect(await h.model.export(.drag, id) == .failed(.staleDocument))
        #expect(h.exporter.pinnedRequests.isEmpty)
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.drag.deliveries.isEmpty)
    }

    @Test("Closing the pin while its export encodes leaves the clipboard untouched")
    func closeDuringEncoding() async throws {
        let h = PinsExportHarness()
        let id = try await h.pinned()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let outcome = h.model.export(.copy, id)
        await waitFor("encoding") { pending.waiterCount == 1 }
        h.model.close(id)
        pending.resolve(.success(()))
        #expect(await outcome == .failed(.staleDocument))
        #expect(h.clipboard.writes.isEmpty)
    }

    @Test(
        "Closing, redacting, or Close All while a drag offer waits revokes it and writes nothing",
        arguments: ["close", "invalidate", "closeAll"])
    func removalRevokesDrag(removal: String) async throws {
        let h = PinsExportHarness()
        var session = TestFixtures.session()
        let id = try await h.pinned(session)
        h.drag.pending = Pending<DragDeliveryOutcome>()
        async let outcome = h.model.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        switch removal {
        case "close": h.model.close(id)
        case "invalidate":
            try session.addSecureMask(covering: Rect(x: 0, y: 0, width: 2, height: 2))
            h.model.invalidate(documentID: session.document.id, epoch: session.privacyEpoch)
        default: h.model.closeAll()
        }
        #expect(h.drag.leases.first?.isRevoked == true)
        #expect(h.drag.dismissCount == 1)
        #expect(await outcome == .failed(.staleDocument))
        #expect(h.drag.writtenSnapshots.isEmpty)
    }

    @Test("Removing another pin leaves this pin's drag offer alone")
    func otherPinUntouched() async throws {
        let h = PinsExportHarness()
        let id = try await h.pinned()
        let other = try await h.pinned()
        let pending = Pending<DragDeliveryOutcome>()
        h.drag.pending = pending
        async let outcome = h.model.export(.drag, id)
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.model.close(other)
        #expect(h.drag.leases.first?.isRevoked == false)
        pending.resolve(.delivered)
        #expect(await outcome == .dragged)
    }

    @Test("A second export while one runs is rejected as busy")
    func busy() async throws {
        let h = PinsExportHarness()
        let id = try await h.pinned()
        let pending = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = pending
        async let first = h.model.export(.copy, id)
        await waitFor("encoding") { pending.waiterCount == 1 }
        #expect(await h.model.export(.copy, id) == .rejectedBusy)
        pending.resolve(.success(()))
        #expect(await first == .copied)
    }
}
