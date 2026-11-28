import Domain
import Foundation
import MacPlatform
import RecortiaFixtures
import Testing

@testable import Features
@testable import Imaging

@MainActor
struct QuickActionsOptimizedSaveTests {
    private let nominal = URL(filePath: "/tmp/recortia-optimized/../recortia-optimized/report.heic")
    private let destination = URL(filePath: "/tmp/recortia-optimized/report.png")

    @Test("Optimized Save always prompts, reuses its bytes and asks before replacing the exact output")
    func singleSnapshotAcrossReplace() async throws {
        let h = QuickActionsHarness()
        let folder = destination.deletingLastPathComponent()
        h.settings.update {
            $0.preferredSaveFolderBookmark = Data([1])
            $0.exportFormat = .heic
        }
        h.folders.folder = folder
        h.files.existing = [destination]
        await h.shown()

        var offered: OptimizedSaveDetails?
        var replacements: [URL] = []
        let declined = await h.model.saveOptimized(
            using: OptimizedSaveDialogs(
                chooseDestination: {
                    offered = $0
                    return nominal
                },
                confirmReplacement: {
                    replacements.append($0)
                    return false
                }))
        #expect(declined == .canceled)
        #expect(h.model.isShown && !h.model.isActing && !h.export.isBusy)
        #expect(h.files.saves.isEmpty && h.files.uniqueSaves.isEmpty)
        #expect(h.exporter.snapshotCount == 1)

        let saved = await h.model.saveOptimized(
            using: OptimizedSaveDialogs(
                chooseDestination: {
                    offered = $0
                    return nominal
                },
                confirmReplacement: {
                    replacements.append($0)
                    return true
                }))
        let details = try #require(offered)
        let written = try #require(h.files.saves.first)
        #expect(replacements == [destination, destination])
        #expect(saved == .saved(destination))
        #expect(details.preferredFolder == folder)
        #expect(details.format == .png && details.suggestedFilename.hasSuffix(".png"))
        #expect(details.pixelSize == written.snapshot.pixelSize && details.byteCount == written.snapshot.bytes.count)
        #expect(written.url == destination && written.overwrite)
        #expect(h.exporter.snapshotCount == 2 && h.files.saves.count == 1)
        #expect(h.settings.preferences.exportFormat == .heic)
        #expect(h.model.capture == nil && h.assets.released == h.assetIDs)
    }

    @Test(
        "The optimized file is the exact advertised, sanitized JPEG or alpha-preserving PNG",
        arguments: [false, true])
    func realOptimizedBytes(transparent: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "recortia-optimized-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1600 × 1200 keeps Automatic's JPEG well inside the size rule with any system encoder.
        let source = try ContainerCrafting.metadataRichJPEG(
            ChartFixture.photographic(width: 1600, height: 1200))
        try #require(ContainerCrafting.metadataCanaries.allSatisfy { ContainerInspector.contains($0, in: source) })
        let store = ImageStore()
        let asset = await store.insert(try ImageDecoder.decode(source), origin: .imported)
        var session = DocumentSession(
            document: Document(
                assets: [asset.id: asset], canvasSize: Size(width: transparent ? 1601 : 1600, height: 1200),
                layers: [ImageLayer(assetID: asset.id)]))
        try session.addSecureMask(covering: Rect(x: 400, y: 300, width: 200, height: 200))
        let sink = RecordingFileSink()
        let h = QuickActionsHarness(fileSink: sink)
        h.exporter.pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        h.settings.update { $0.exportFormat = .heic }
        await h.shown(session)

        var offered: OptimizedSaveDetails?
        let outcome = await h.model.saveOptimized(
            using: OptimizedSaveDialogs(
                chooseDestination: {
                    offered = $0
                    return directory.appending(path: "report.heic")
                }, confirmReplacement: { _ in false }))
        let details = try #require(offered)
        let snapshot = try #require(sink.writtenSnapshot)
        let name = transparent ? "report.png" : "report.jpg"
        let outputURL = directory.standardizedFileURL.appending(path: name)
        let written = try Data(contentsOf: outputURL)
        guard case .saved(let reported) = outcome else {
            Issue.record("expected saved, got \(outcome)")
            return
        }
        #expect(reported.resolvingSymlinksInPath().path == outputURL.resolvingSymlinksInPath().path)
        #expect(written == snapshot.bytes && h.exporter.snapshotCount == 1)
        #expect(details.format == snapshot.format && details.suggestedFilename.hasSuffix(transparent ? ".png" : ".jpg"))
        #expect(details.byteCount == written.count && details.pixelSize == snapshot.pixelSize)
        let decoded = try ContainerInspector.decodePixels(written)
        #expect(decoded.width == details.pixelSize.width && decoded.height == details.pixelSize.height)
        #expect(ContainerCrafting.metadataCanaries.allSatisfy { !ContainerInspector.contains($0, in: written) })
        let masked = decoded.pixel(x: 500, y: 400)
        #expect(masked.r <= 4 && masked.g <= 4 && masked.b <= 4 && masked.a == 255)
        if transparent {
            #expect(details.format == .png)
            #expect(try ContainerInspector.pngChunkTypes(written).contains("IEND"))
            #expect(decoded.pixel(x: 1600, y: 450).a == 0)
        } else {
            #expect(details.format == .jpeg(quality: AutomaticFormatRule.jpegQuality))
            #expect(try ContainerInspector.jpegSegments(written).endsWithEOI)
            #expect(decoded.pixel(x: 1599, y: 450).a == 255)
        }
    }

    @Test(
        "Replacing the capture cancels the unanswered dialog and lets the next batch export", arguments: [false, true])
    func replacedWhileAwaitingDialog(atReplacement: Bool) async {
        let h = QuickActionsHarness()
        await h.shown()
        if atReplacement { h.files.existing.insert(destination) }
        let pending = Pending<Void>()
        let saving = Task {
            await h.model.saveOptimized(
                using: OptimizedSaveDialogs(
                    chooseDestination: { _ in
                        if !atReplacement { await awaitDialog(pending) }
                        return destination
                    },
                    confirmReplacement: { _ in
                        await awaitDialog(pending)
                        return true
                    }))
        }
        await waitFor("the optimized dialog holds the operation") { pending.waiterCount == 1 }
        #expect(h.model.isActing && h.export.isBusy)
        #expect(await h.model.copy() == .rejectedBusy)

        h.settings.update { $0.autoCopy = true }
        let next = TestFixtures.session()
        let replacing = Task { await h.model.present(next, after: h.export.automaticExportPlan()) }
        await waitFor("the next capture is copied without responding to the old dialog") {
            h.clipboard.writes.map(\.documentID) == [next.document.id]
        }
        pending.resolve(())  // Releases the control if a broken implementation forgot to cancel.
        #expect(await saving.value == .canceled)
        #expect(await replacing.value == [.copied])
        #expect(h.files.saves.isEmpty)
        #expect(h.model.capture?.session.document.id == next.document.id && !h.export.isBusy)
    }

    @Test("A late cancel preserves the committed optimized write or its typed failure", arguments: [false, true])
    func lateCancellation(fails: Bool) async {
        let h = QuickActionsHarness()
        await h.shown()
        let pending = Pending<Void>()
        h.files.pending = pending
        if fails { h.files.error = .leftover(name: "report.png") }
        let saving = Task {
            await h.model.saveOptimized(
                using: OptimizedSaveDialogs(
                    chooseDestination: { _ in destination }, confirmReplacement: { _ in false }))
        }
        await waitFor("the sink admitted the prepared file") { pending.waiterCount == 1 }
        h.model.dismiss()
        pending.resolve(())
        if fails {
            #expect(await saving.value == .failed(.leftover(name: "report.png")))
            #expect(h.files.saves.isEmpty)
        } else {
            #expect(await saving.value == .alreadyCompleted(.saved(destination)))
            #expect(h.files.saves.map(\.url) == [destination])
        }
        #expect(h.exporter.snapshotCount == 1 && !h.export.isBusy)
    }

    private func awaitDialog(_ pending: Pending<Void>) async {
        await withTaskCancellationHandler {
            await pending.wait()
        } onCancel: {
            Task { @MainActor in pending.resolve(()) }
        }
    }
}

@MainActor
private final class RecordingFileSink: FileSinkService {
    private let sink = FileSink()
    private(set) var writtenSnapshot: ShareSnapshot?

    func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) async throws(SinkError) -> URL {
        let saved = try sink.save(snapshot, to: url, overwrite: overwrite)
        writtenSnapshot = snapshot
        return saved
    }

    func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) async throws(SinkError) -> URL {
        try sink.saveUnique(snapshot, in: folder)
    }
}
