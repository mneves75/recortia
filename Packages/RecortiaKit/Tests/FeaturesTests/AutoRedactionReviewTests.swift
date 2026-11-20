import CoreGraphics
import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

/// Independent review of T1d (automatic masking): what a masked capture's automatic batch does at
/// the edges the implementation's own suite does not reach.
@Suite("Automatic masking: review edges (T1 review)")
@MainActor
struct AutoRedactionReviewTests {
    private static let secret = FixtureRect(x: 40, y: 30, width: 120, height: 24)
    private static let region = PixelRect(x: 36, y: 26, width: 128, height: 32)

    /// A fresh 400 x 300 capture at 2x, opened with automatic masking, whose detector waits for
    /// the test. The harness's own editor is a second, unmasked document on the same coordinator.
    private static func capture(
        regions: [PixelRect], configure: (EditorHarness) -> Void = { _ in }
    ) async throws -> (EditorHarness, EditorModel) {
        let store = ImageStore()
        let image = try SecretExport.image(width: 400, height: 300, secrets: [secret], green: 0)
        let info = await store.insert(
            try ImageDecoder.canonicalize(image),
            origin: .captured(EditorFixtures.captureGeometry(width: 400, height: 300, scale: 2)))
        let harness = EditorHarness()
        harness.assets.store = store
        harness.sensitiveText.regions = regions
        harness.sensitiveText.pending = Pending<Void>()
        harness.settings.update {
            $0.autoCopy = true
            $0.autoSave = true
            $0.preferredSaveFolderBookmark = Data([1])
        }
        harness.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/review-masking", isDirectory: true)
        configure(harness)
        let model = EditorModel(
            session: DocumentSession(document: Document(asset: info)), environment: harness.model.environment,
            autoRedacts: true)
        return (harness, model)
    }

    @Test(
        "A detected box that reaches past the capture fails all masking closed; one inside the edge lands",
        arguments: [false, true])
    func boxPastTheEdgeFailsClosed(pastTheEdge: Bool) async throws {
        // The positive control (false) touches the right and bottom edges exactly.
        let edge =
            pastTheEdge
            ? PixelRect(x: 380, y: 280, width: 40, height: 40) : PixelRect(x: 360, y: 270, width: 40, height: 30)
        let (h, model) = try await Self.capture(regions: [Self.region, edge])
        defer { model.close() }
        let plan = h.export.automaticExportPlan()
        let batch = Task { await model.runAutomaticExports(plan) }
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        h.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction != .pending }
        let outcomes = await batch.value
        if pastTheEdge {
            #expect(model.autoRedaction == .failed && model.notice == .maskingFailed)
            #expect(model.document.masks.isEmpty, "no partial set of masks is kept")
            #expect(outcomes == [.failed(.maskingUnfinished)])
            #expect(h.clipboard.writes.isEmpty && h.files.uniqueSaves.isEmpty)
        } else {
            #expect(model.autoRedaction == .done && model.document.masks.count == 2)
            #expect(outcomes.count == 2 && outcomes.allSatisfy(\.didWrite), "\(outcomes)")
        }
    }

    /// T1 security 3C: with masking on, the person always learns its outcome, none found included.
    @Test("Masking that finds nothing says so")
    func zeroMatchesSayNoneFound() async throws {
        let (h, model) = try await Self.capture(regions: [])
        defer { model.close() }
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        h.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction != .pending }
        #expect(model.autoRedaction == .done && model.document.masks.isEmpty)
        #expect(model.notice == .sensitiveTextMasked(0))
    }

    /// T1 security 3C: an automatic export's report never silently replaces the masking count and
    /// its review reminder; the editor refuses it so the app raises it as an alert instead.
    @Test(
        "An automatic export's report leaves the masking notice in place",
        arguments: [ExportOutcome.failed(.diskFull), .uploaded(URL(string: "https://example.com/image.png")!)])
    func exportReportKeepsMaskingNotice(outcome: ExportOutcome) async throws {
        let (h, model) = try await Self.capture(regions: [Self.region])
        defer { model.close() }
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        h.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction != .pending }
        #expect(model.notice == .sensitiveTextMasked(1))
        #expect(!model.reportAutomaticExport(outcome), "refused, so the app raises it as an alert")
        #expect(model.notice == .sensitiveTextMasked(1))
        // Once the person dismissed it, the slot is free again.
        model.dismissNotice()
        #expect(model.reportAutomaticExport(outcome))
        #expect(model.notice != nil && model.notice != .sensitiveTextMasked(1))
    }

    /// Finding R-2 (P3): masking defers the batch by up to the deadline, so another editor's
    /// export may hold the shared slot when it settles. The batch waits for the slot instead of
    /// dropping the capture's automatic copy and save with a busy failure.
    @Test("An export in another editor when masking settles delays the capture's automatic copy and save")
    func batchCollidesWithAnotherEditorsExport() async throws {
        let (h, model) = try await Self.capture(regions: [Self.region])
        defer { model.close() }
        await h.settle()
        let plan = h.export.automaticExportPlan()
        let batch = Task { await model.runAutomaticExports(plan) }
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        // The person copies from another editor while this capture is still being masked.
        h.exporter.pending = Pending()
        let manual = Task { await h.model.export(.copy) }
        await waitFor("manual export rendering") { h.exporter.pending?.waiterCount == 1 }
        h.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction != .pending }
        await drain()
        // Detached first: the waiting batch renders as soon as the slot frees.
        let rendering = h.exporter.pending
        h.exporter.pending = nil
        rendering?.resolve(.success(()))
        await drain()
        let outcomes = await batch.value
        #expect(await manual.value == .copied)
        #expect(model.autoRedaction == .done)
        #expect(outcomes.count == 2 && outcomes.allSatisfy(\.didWrite), "\(outcomes)")
    }

    enum WhileWaiting: CaseIterable { case close, edit }

    @MainActor final class BatchEnded { var value = false }

    /// R-2: a batch waiting for the slot still fails closed when its editor closes or its document
    /// changes before the slot frees.
    @Test(
        "A batch waiting for another editor's export writes nothing once its editor closes or changes",
        arguments: WhileWaiting.allCases)
    func waitingBatchFailsClosed(_ event: WhileWaiting) async throws {
        let (h, model) = try await Self.capture(regions: [Self.region])
        defer { model.close() }
        await h.settle()
        let plan = h.export.automaticExportPlan()
        let ended = BatchEnded()
        let batch = Task {
            let outcomes = await model.runAutomaticExports(plan)
            ended.value = true
            return outcomes
        }
        await waitFor("detection started") { h.sensitiveText.pending?.waiterCount == 1 }
        let rendering = Pending<Result<Void, ExportServiceError>>()
        h.exporter.pending = rendering
        let manual = Task { await h.model.export(.copy) }
        await waitFor("manual export rendering") { rendering.waiterCount == 1 }
        h.exporter.pending = nil
        h.sensitiveText.pending?.resolve(())
        await waitFor("masking settled") { model.autoRedaction == .done }
        await drain()
        #expect(!ended.value, "the batch waits for the slot")
        switch event {
        case .close:
            model.close()
            // Closing wakes the batch at once; it does not wait for the other editor's export.
            await waitFor("the closed editor's batch ended") { ended.value }
        case .edit: model.undo()
        }
        rendering.resolve(.success(()))
        #expect(await manual.value == .copied)
        let outcomes = await batch.value
        #expect(outcomes == [event == .close ? .canceled : .failed(.staleDocument)], "\(outcomes)")
        #expect(h.clipboard.writes.count == 1 && h.files.uniqueSaves.isEmpty, "only the manual copy was written")
    }
}
