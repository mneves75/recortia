import CoreGraphics
import Domain
import Foundation
import Testing

@testable import Features

// Failure modes (FR-09, PIN-01): exceeding the pin budget; pinning a document whose revision or
// privacy epoch changed while rendering; a render failure; a later redaction leaving a stale raw
// view on screen; closed pins retaining their pixels; out-of-range opacity/zoom.
@MainActor
final class PinsHarness {
    let renderer = FakeRenderService()
    let settings = SettingsStore(storage: MemoryPreferenceStorage())
    let model: PinsModel

    init() {
        model = PinsModel(renderer: renderer, settings: settings)
    }
}

@Suite("PinsModel (FR-09, PIN-01)")
@MainActor
struct PinsModelTests {
    @Test("At most five pins; the sixth is refused")
    func pinLimit() async throws {
        let h = PinsHarness()
        let session = TestFixtures.session()
        for _ in 0..<PinLimits.maxPins {
            _ = try await h.model.pin(session, currentSession: { session })
        }
        #expect(h.model.pins.count == 5)
        #expect(h.model.canAddPin == false)
        await #expect(throws: PinError.limitReached) {
            _ = try await h.model.pin(session, currentSession: { session })
        }
        #expect(h.renderer.renderCount == 5)  // the refused pin never rendered
    }

    @Test("Pins share a pixel budget; a pin that would exceed it is refused and nothing is added")
    func pinPixelBudget() throws {
        let h = PinsHarness()
        let side = Int(Double(PinLimits.maxTotalPixels / 2).squareRoot())
        let big = try #require(makeImage(width: side, height: side))
        try h.model.add(big, source: nil, displayScale: 1)
        #expect(throws: PinError.memoryBudgetExceeded) {
            try h.model.add(big, source: nil, displayScale: 1)
            try h.model.add(big, source: nil, displayScale: 1)
        }
        #expect(h.model.pins.count == 2, "the pin that would cross the budget is not added")
        #expect(h.model.retainedPixelCount <= PinLimits.maxTotalPixels)
        h.model.close(h.model.pins[0].id)
        try h.model.add(big, source: nil, displayScale: 1)
        #expect(h.model.pins.count == 2, "closing a pin releases its share of the budget")
    }

    @Test("A pin records the source document and privacy epoch and uses the default opacity")
    func pinRecordsIdentity() async throws {
        let h = PinsHarness()
        h.settings.update { $0.pinDefaultOpacity = 0.6 }
        let session = TestFixtures.session()
        let id = try await h.model.pin(session, currentSession: { session })
        let pin = try #require(h.model.pins.first { $0.id == id })
        #expect(pin.sourceDocumentID == session.document.id)
        #expect(pin.privacyEpoch == session.privacyEpoch)
        #expect(pin.opacity == 0.6)
        #expect(pin.zoom == 1)
    }

    @Test("A render whose document changed meanwhile is discarded")
    func staleRenderDiscarded() async throws {
        let h = PinsHarness()
        let pending = Pending<Result<CGImage, ExportServiceError>>()
        h.renderer.pending = pending
        let box = SessionBox(TestFixtures.session())
        let original = box.session

        let task = Task { try await h.model.pin(original, currentSession: { box.session }) }
        await waitFor("rendering") { pending.waiterCount == 1 }
        try box.session.addSecureMask(covering: Rect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(makeImage())
        pending.resolve(.success(image))
        await #expect(throws: PinError.staleDocument) { try await task.value }
        #expect(h.model.pins.isEmpty)
    }

    @Test("A render failure is reported and creates no pin")
    func renderFailure() async {
        let h = PinsHarness()
        h.renderer.shouldFail = true
        let session = TestFixtures.session()
        await #expect(throws: PinError.renderFailed) {
            _ = try await h.model.pin(session, currentSession: { session })
        }
        #expect(h.model.pins.isEmpty)
    }

    @Test("A privacy-epoch change removes stale pins of that document only")
    func epochInvalidation() async throws {
        let h = PinsHarness()
        var session = TestFixtures.session()
        let other = TestFixtures.session()
        _ = try await h.model.pin(session, currentSession: { session })
        _ = try await h.model.pin(other, currentSession: { other })

        try session.addSecureMask(covering: Rect(x: 0, y: 0, width: 2, height: 2))
        h.model.invalidate(documentID: session.document.id, epoch: session.privacyEpoch)
        #expect(h.model.pins.count == 1)
        #expect(h.model.pins.first?.sourceDocumentID == other.document.id)
        #expect(h.model.lastInvalidatedCount == 1)

        // The current epoch does not invalidate pins made at that epoch.
        let current = try await h.model.pin(session, currentSession: { session })
        h.model.invalidate(documentID: session.document.id, epoch: session.privacyEpoch)
        #expect(h.model.pins.contains { $0.id == current })
    }

    @Test("Closing a pin releases its image")
    func closeReleasesImage() async throws {
        let h = PinsHarness()
        weak var weakImage: CGImage?
        let id: PinID = try autoreleasepool {
            guard let image = makeImage(width: 64, height: 64) else { throw TestError() }
            weakImage = image
            return try h.model.add(image, source: nil, displayScale: 1)
        }
        #expect(weakImage != nil)
        h.model.close(id)
        #expect(h.model.pins.isEmpty)
        #expect(weakImage == nil)
    }

    @Test("Close all empties the list; bring forward is observable")
    func closeAllAndBringForward() async throws {
        let h = PinsHarness()
        let session = TestFixtures.session()
        _ = try await h.model.pin(session, currentSession: { session })
        _ = try await h.model.pin(session, currentSession: { session })
        let before = h.model.bringForwardRequest
        h.model.bringForward()
        #expect(h.model.bringForwardRequest == before + 1)
        h.model.closeAll()
        #expect(h.model.pins.isEmpty)
        #expect(h.model.canAddPin)
    }

    @Test("Opacity and zoom are clamped to their ranges")
    func clamping() async throws {
        let h = PinsHarness()
        let session = TestFixtures.session()
        let id = try await h.model.pin(session, currentSession: { session })
        h.model.setOpacity(0, for: id)
        h.model.setZoom(100, for: id)
        let pin = try #require(h.model.pins.first)
        #expect(pin.opacity == PinsModel.opacityRange.lowerBound)
        #expect(pin.zoom == PinsModel.zoomRange.upperBound)
        h.model.setOpacity(.nan, for: id)
        #expect(h.model.pins.first?.opacity == PinsModel.opacityRange.lowerBound)
    }
}
