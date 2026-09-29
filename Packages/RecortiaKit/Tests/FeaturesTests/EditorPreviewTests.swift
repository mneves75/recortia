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
    @Test("The base renders once; annotation edits never re-render it")
    func annotationEditsDoNotRenderBase() async {
        let h = EditorHarness()
        await h.settle()
        #expect(h.renderer.baseRenders.count == 1)
        #expect(h.model.isBaseCurrent)
        h.model.selectTool(.arrow)
        h.drag((10, 10), (100, 100))
        h.model.selectTool(.text)
        h.click(50, 50)
        h.model.commitTextEditing("Hi")
        await h.settle()
        #expect(h.renderer.baseRenders.count == 1)
    }

    @Test("Moving an image layer re-renders the base")
    func layerMoveRendersBase() async throws {
        let h = EditorHarness()
        await h.settle()
        h.model.select(.layer(try #require(h.model.document.layers.first?.id)))
        h.model.nudgeSelection(dx: 5, dy: 0)
        await h.settle()
        #expect(h.renderer.baseRenders.count == 2)
        #expect(h.renderer.baseRenders.last?.layers.first?.placement.translation == Point(x: 5, y: 0))
        #expect(h.model.isBaseCurrent)
    }

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

    @Test("Pins made before a redaction are closed when the privacy epoch changes")
    func pinsInvalidatedOnRedaction() async {
        let h = EditorHarness()
        await h.model.pin()
        #expect(h.pins.pins.count == 1)
        h.model.selectTool(.redact)
        h.drag((100, 100), (150, 150))
        #expect(h.pins.pins.isEmpty)
        #expect(h.model.notice == .pinsInvalidated(1))
    }

    @Test("Undoing a redaction also advances the epoch and invalidates derivatives")
    func undoRedactionInvalidates() async {
        let h = EditorHarness()
        h.model.selectTool(.redact)
        h.drag((100, 100), (150, 150))
        await h.model.pin()
        #expect(h.pins.pins.count == 1)
        h.model.undo()
        #expect(h.model.session.privacyEpoch == 2)
        #expect(h.pins.pins.isEmpty)
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
