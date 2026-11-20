import CoreGraphics
import Domain
import Foundation
import Imaging
import Testing

@testable import Features

// Failure modes (FR-06, FR-08, RED-03): a base rendered before a redaction installed after it;
// a render for a moved layer shown after the move; annotation edits re-rendering the whole base;
// OCR text recognized before a redaction reaching the result list or the clipboard; recognized
// text or QR payloads staying on screen after a redaction; pins of the old epoch staying open;
// a magnifier enlarging a base that predates a redaction; late results after the editor closed.
@Suite("Editor preview and stale results (RED-03)")
@MainActor
struct EditorPreviewTests {

    @Test("A base rendered before a redaction is dropped; the follow-up render is installed")
    func staleBaseAfterRedactionIsDropped() async throws {
        let pending = Pending<Result<CGImage, TestError>>()
        let h = EditorHarness { $0.renderer.pending = pending }
        await waitFor("first render") { pending.waiterCount == 1 }
        h.model.selectTool(.redact)
        h.drag((10, 10), (50, 50))
        #expect(h.model.session.privacyEpoch == 1)

        let stale = try #require(makeImage(width: 400, height: 300))
        pending.resolve(.success(stale))
        await waitFor("follow-up render") { pending.waiterCount == 1 }
        #expect(h.model.baseImage == nil)
        #expect(h.model.droppedResultCount == 1)
        #expect(h.renderer.baseRenders.last?.masks.count == 1)

        let fresh = try #require(makeImage(width: 400, height: 300))
        pending.resolve(.success(fresh))
        await h.settle()
        #expect(h.model.baseImage === fresh)
        #expect(h.model.isBaseCurrent)
    }

    @Test("A base rendered before a layer move is dropped")
    func staleBaseAfterLayerMoveIsDropped() async throws {
        let pending = Pending<Result<CGImage, TestError>>()
        let h = EditorHarness { $0.renderer.pending = pending }
        await waitFor("first render") { pending.waiterCount == 1 }
        h.model.select(.layer(try #require(h.model.document.layers.first?.id)))
        h.model.nudgeSelection(dx: 0, dy: 3)
        pending.resolve(.success(try #require(makeImage(width: 400, height: 300))))
        await waitFor("follow-up render") { pending.waiterCount == 1 }
        #expect(h.model.baseImage == nil)
        #expect(h.model.droppedResultCount == 1)
        pending.resolve(.success(try #require(makeImage(width: 400, height: 300))))
        await h.settle()
        #expect(h.model.isBaseCurrent)
    }

    @Test("A base whose inputs did not change is accepted across annotation-only edits")
    func baseAcceptedAcrossAnnotationEdits() async throws {
        let pending = Pending<Result<CGImage, TestError>>()
        let h = EditorHarness { $0.renderer.pending = pending }
        await waitFor("first render") { pending.waiterCount == 1 }
        h.model.selectTool(.rectangle)
        h.drag((10, 10), (60, 60))
        #expect(h.model.session.revision == 1)
        let image = try #require(makeImage(width: 400, height: 300))
        pending.resolve(.success(image))
        await h.settle()
        #expect(h.model.baseImage === image)
        #expect(h.model.droppedResultCount == 0)
        #expect(h.renderer.baseRenders.count == 1)
    }

    @Test("A render failure is reported once and not retried for the same inputs")
    func renderFailure() async {
        let h = EditorHarness { $0.renderer.fails = true }
        await h.settle()
        #expect(h.model.baseImage == nil)
        #expect(h.model.notice == .previewFailed)
        h.model.selectTool(.arrow)
        h.drag((10, 10), (90, 90))
        await h.settle()
        #expect(h.renderer.baseRenders.count == 1)
    }

    /// A rendered editor whose layer then moved and whose re-render failed: the canvas still shows
    /// the old base, which no export would produce.
    private func failedRerender() async throws -> EditorHarness {
        let h = EditorHarness()
        await h.settle()
        #expect(h.model.isPreviewReady)
        h.renderer.fails = true
        h.model.select(.layer(try #require(h.model.document.layers.first?.id)))
        h.model.nudgeSelection(dx: 0, dy: 3)
        await h.settle()
        #expect(h.model.notice == .previewFailed)
        #expect(!h.model.isPreviewReady && h.model.baseImage != nil, "the stale base stays, marked as failed")
        return h
    }

    @Test("A failed re-render blocks every export and pin until a render succeeds (R2-D12)")
    func failedRerenderBlocksExports() async throws {
        let h = try await failedRerender()
        // Rendering would work again, but nothing re-rendered: the canvas is still stale.
        h.renderer.fails = false
        h.settings.update { $0.preferredSaveFolderBookmark = Data([1]) }
        h.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/synthetic-folder", isDirectory: true)
        let save = EditorExportRequest.save(
            URL(fileURLWithPath: "/tmp/recortia-tests/never-written.png"), format: .png, overwriteConfirmed: false)
        for request in [EditorExportRequest.copy, .drag, save, .saveToPreferredFolder] {
            #expect(await h.model.export(request) == .failed(.renderFailed), "\(request)")
        }
        let fullRenders = h.renderer.fullRenders.count
        await h.model.pin()
        #expect(h.renderer.fullRenders.count == fullRenders, "a refused pin renders nothing")
        #expect(h.pins.pins.isEmpty)
        #expect(h.exporter.snapshotCount == 0, "no export reached the pipeline")
        #expect(h.clipboard.writes.isEmpty && h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(h.drag.leases.isEmpty)

        h.model.nudgeSelection(dx: 0, dy: 3)
        await h.settle()
        #expect(h.model.isPreviewReady)
        #expect(await h.model.export(.copy) == .copied)
    }

    @Test("Undo back to the rendered base unlocks exports without a new render (R2-D12c)")
    func undoToRenderedBaseUnlocks() async throws {
        let h = try await failedRerender()
        let renders = h.renderer.baseRenders.count
        h.model.undo()
        await h.settle()
        #expect(h.model.isPreviewReady, "the canvas shows a successful render of the current base")
        #expect(h.renderer.baseRenders.count == renders)
        #expect(await h.model.export(.copy) == .copied)
    }

    @Test("Turning a failed Output Preview off unlocks exports over a rendered base (R2-D12d)")
    func outputPreviewOffUnlocksOverRenderedBase() async {
        let h = EditorHarness()
        await h.settle()
        h.renderer.fails = true
        h.model.setShowsOutputPreview(true)
        await h.settle()
        #expect(!h.model.isPreviewReady)
        #expect(await h.model.export(.copy) == .failed(.renderFailed))
        h.model.setShowsOutputPreview(false)
        #expect(h.model.isPreviewReady, "the editing view shows its successful base render")
        #expect(await h.model.export(.copy) == .copied)
    }

    @Test("A preview failure revokes the document's offered drag (R2-D12a)")
    func previewFailureRevokesPendingDrag() async {
        let h = EditorHarness()
        await h.settle()
        h.drag.pending = Pending<DragDeliveryOutcome>()
        let task = Task { await h.model.export(.drag) }
        await waitFor("drag offered") { h.drag.leases.count == 1 }
        h.renderer.fails = true
        h.model.setShowsOutputPreview(true)
        await h.settle()
        #expect(h.drag.leases.first?.isRevoked == true)
        h.drag.pending?.resolve(.delivered)  // a receiver that arrives anyway, if the chip survived
        _ = await task.value
        #expect(h.drag.writtenSnapshots.isEmpty)
    }

    @Test("A preview that fails while a copy renders stops the copy before it commits (R2-D12b)")
    func previewFailureDuringCopyStopsCommit() async {
        let h = EditorHarness()
        await h.settle()
        let gate = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = gate
        let task = Task { await h.model.export(.copy) }
        await waitFor("snapshot suspended") { gate.waiterCount == 1 }
        h.renderer.fails = true
        h.model.setShowsOutputPreview(true)
        await h.settle()
        #expect(!h.model.isPreviewReady)
        h.exporter.pending = nil
        gate.resolve(.success(()))
        #expect(await task.value == .failed(.renderFailed))
        #expect(h.clipboard.writes.isEmpty)
        #expect(h.model.notice == .previewFailed)
    }

    @Test("A preview that fails while a pin renders keeps the pin out (R2-D12b)")
    func previewFailureDuringPinRenderKeepsPinOut() async throws {
        let h = EditorHarness()
        await h.settle()
        let gate = Pending<Result<CGImage, TestError>>()
        h.renderer.pending = gate
        h.model.setShowsOutputPreview(true)
        await waitFor("output render suspended") { gate.waiterCount == 1 }
        let pin = Task { await h.model.pin() }
        await waitFor("pin render suspended") { gate.waiterCount == 2 }
        gate.resolve(.failure(TestError()))  // the output preview, requested first
        await waitFor("preview failed") { !h.model.isPreviewReady }
        gate.resolve(.success(try #require(makeImage(width: 400, height: 300))))
        await pin.value
        #expect(h.pins.pins.isEmpty)
        #expect(h.model.notice == .previewFailed)
    }

    @Test("OCR recognized before a redaction is discarded and cannot reach the clipboard")
    func staleOCRDiscarded() async throws {
        let h = EditorHarness()
        await h.settle()
        let gate = Pending<Void>()
        h.recognizer.pending = gate
        h.recognizer.lines = [
            OCRResult.Line(text: "secret", confidence: 1, box: Rect(x: 0, y: 0, width: 10, height: 10))
        ]
        let task = Task { await h.model.recognizeText() }
        await waitFor("recognizing") { gate.waiterCount == 1 }
        #expect(h.model.recognition == .running)
        h.model.selectTool(.redact)
        h.drag((0, 0), (40, 20))
        gate.resolve(())
        await task.value
        #expect(h.model.recognition == .idle)
        #expect(h.model.notice == .recognitionDiscarded)
        #expect(!h.model.copyRecognizedText(mode: .raw))
        #expect(h.textClipboard.writes.isEmpty)
    }

    @Test("OCR recognized before an annotation edit is also discarded (strict identity)")
    func ocrRequiresExactRevision() async {
        let h = EditorHarness()
        let gate = Pending<Void>()
        h.recognizer.pending = gate
        h.recognizer.lines = [OCRResult.Line(text: "text", confidence: 1, box: Rect(x: 0, y: 0, width: 4, height: 4))]
        let task = Task { await h.model.recognizeText() }
        await waitFor("recognizing") { gate.waiterCount == 1 }
        h.model.selectTool(.arrow)
        h.drag((10, 10), (90, 90))
        gate.resolve(())
        await task.value
        #expect(h.model.recognition == .idle)
        #expect(h.model.droppedResultCount >= 1)
    }

    @Test("A redaction after recognition clears the recognized text and QR payloads")
    func redactionClearsResults() async {
        let h = EditorHarness()
        h.recognizer.lines = [OCRResult.Line(text: "token", confidence: 1, box: Rect(x: 0, y: 0, width: 4, height: 4))]
        h.qr.payloads = [QRPayload(bytes: Data("hello".utf8), string: "hello", kind: .text)]
        await h.model.recognizeText()
        await h.model.decodeQR()
        #expect(h.model.recognizedText(mode: .raw) == "token")
        #expect(h.model.qrPayloads.count == 1)
        h.model.selectTool(.redact)
        h.drag((100, 100), (150, 150))
        #expect(h.model.recognition == .idle)
        #expect(h.model.qrPayloads.isEmpty)
        #expect(h.model.notice == .recognitionInvalidated)
        #expect(h.textClipboard.writes.isEmpty)
    }

    @Test("Magnifiers draw only from a base of the current privacy epoch")
    func magnifierBaseGatedByEpoch() async {
        let pending = Pending<Result<CGImage, TestError>>()
        let h = EditorHarness()
        await h.settle()
        #expect(h.model.calloutBaseImage != nil)
        h.renderer.pending = pending
        h.model.selectTool(.redact)
        h.drag((100, 100), (150, 150))
        #expect(h.model.baseImage == nil)
        #expect(h.model.calloutBaseImage == nil)
        await waitFor("re-render") { pending.waiterCount == 1 }
        if let image = makeImage(width: 400, height: 300) { pending.resolve(.success(image)) }
        await h.settle()
        #expect(h.model.calloutBaseImage != nil)
    }

    @Test("A privacy change clears duplicated source previews even when rendering fails")
    func privacyChangeDropsDuplicateBaseEvenWhenRenderingFails() async throws {
        let h = EditorHarness()
        let layer = try #require(h.model.document.layers.first)
        h.model.select(.layer(layer.id))
        h.model.duplicateSelection()
        await h.settle()
        #expect(h.model.baseImage != nil)
        let pending = Pending<Result<CGImage, TestError>>()
        h.renderer.pending = pending
        h.model.selectTool(.redact)
        h.drag((10, 10), (50, 50))
        #expect(h.model.baseImage == nil, "the old base exposes the duplicate's covered source pixels")
        await waitFor("masked base render") { pending.waiterCount == 1 }
        pending.resolve(.failure(TestError()))
        await h.settle()
        #expect(h.model.baseImage == nil, "a failed render must not restore an older privacy epoch")
        #expect(h.model.calloutBaseImage == nil)
    }

    @Test("The output preview renders the full document and drops stale results")
    func outputPreview() async throws {
        let pending = Pending<Result<CGImage, TestError>>()
        let h = EditorHarness()
        await h.settle()
        h.renderer.pending = pending
        h.model.setShowsOutputPreview(true)
        await waitFor("output render") { pending.waiterCount == 1 }
        h.model.setPadding(20)
        pending.resolve(.success(try #require(makeImage(width: 440, height: 340))))
        await waitFor("follow-up") { pending.waiterCount == 1 }
        #expect(h.model.outputPreview == nil)
        pending.resolve(.success(try #require(makeImage(width: 440, height: 340))))
        await h.settle()
        #expect(h.model.isOutputPreviewCurrent)
        #expect(h.renderer.fullRenders.last?.presentation.padding == 20)
    }

    @Test("Toggling output preview retains ownership until the canceled render finishes")
    func outputToggleWhileRendering() async throws {
        let pending = Pending<Result<CGImage, TestError>>()
        let h = EditorHarness()
        await h.settle()
        h.renderer.pending = pending
        h.model.setShowsOutputPreview(true)
        await waitFor("first output render") { pending.waiterCount == 1 }
        h.model.setShowsOutputPreview(false)
        h.model.setPadding(20)
        h.model.setShowsOutputPreview(true)
        await drain()
        #expect(h.renderer.fullRenders.count == 1, "one render remains in flight despite cancellation")
        pending.resolve(.failure(TestError()))
        await waitFor("latest output render") { pending.waiterCount == 1 }
        #expect(h.renderer.fullRenders.count == 2)
        #expect(h.model.notice != .previewFailed, "canceled render cannot report a failure")
        pending.resolve(.success(try #require(makeImage(width: 440, height: 340))))
        await h.settle()
        #expect(h.renderer.fullRenders.count == 2)
        #expect(h.model.isOutputPreviewCurrent)
    }

    @Test("Results arriving after close are ignored and asset pixels are released")
    func lateResultsAfterClose() async throws {
        let pending = Pending<Result<CGImage, TestError>>()
        let h = EditorHarness { $0.renderer.pending = pending }
        await waitFor("first render") { pending.waiterCount == 1 }
        let assetID = try #require(h.model.document.layers.first?.assetID)
        h.model.close()
        pending.resolve(.success(try #require(makeImage(width: 400, height: 300))))
        await drain()
        #expect(h.model.baseImage == nil)
        #expect(h.assets.released == [assetID])
        h.model.selectTool(.arrow)
        h.drag((10, 10), (90, 90))
        #expect(h.model.document.annotations.isEmpty)
        await h.model.recognizeText()
        #expect(h.recognizer.recognizedSizes.isEmpty)
    }
}
