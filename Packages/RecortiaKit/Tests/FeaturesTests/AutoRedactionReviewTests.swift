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

    /// Finding R-3 (P3): masking defers the batch by up to the deadline, and the batch still
    /// refuses to queue behind another editor's export, so the capture's automatic copy and save
    /// are dropped with a busy failure instead of running once the slot is free.
    @Test("An export in another editor when masking settles drops the capture's automatic copy and save")
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
        h.exporter.pending?.resolve(.success(()))
        await drain()
        h.exporter.pending = nil
        let outcomes = await batch.value
        #expect(await manual.value == .copied)
        #expect(model.autoRedaction == .done)
        withKnownIssue("R-3: the deferred automatic batch is refused as busy instead of waiting for the slot") {
            #expect(outcomes.count == 2 && outcomes.allSatisfy(\.didWrite), "\(outcomes)")
        }
        #expect(outcomes == [.failed(.busy)], "documents today's behaviour")
    }
}
