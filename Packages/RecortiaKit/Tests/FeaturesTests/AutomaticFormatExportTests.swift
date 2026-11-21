import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

// Failure modes (FR-07, Automatic format): JPEG bytes saved under the .png name a save panel
// offered; Copy Image publishing a JPEG; a fixed-format save renamed after the panel named it.
@Suite("Automatic format through the export coordinator (FR-07)")
@MainActor
struct AutomaticFormatExportTests {
    private func photographicHarness() async throws -> ExportHarness {
        let store = ImageStore()
        let info = await store.insert(
            try ImageDecoder.canonicalize(try ChartFixture.photographic(width: 1200, height: 900)),
            origin: .imported(pointPixelScale: 1))
        let h = ExportHarness()
        h.exporter.pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
        h.session = DocumentSession(document: Document(asset: info))
        h.settings.update { $0.exportFormat = .automatic }
        return h
    }

    @Test("A save panel's .png name takes the extension of the JPEG that Automatic chose")
    func savedNameMatchesBytes() async throws {
        let h = try await photographicHarness()
        let chosen = URL(fileURLWithPath: "/tmp/recortia-tests/Shot.png")
        let outcome = await h.export(.save(to: chosen, format: .automatic, overwriteConfirmed: false))
        #expect(outcome == .saved(URL(fileURLWithPath: "/tmp/recortia-tests/Shot.jpg")))
        let saved = try #require(h.files.saves.last)
        #expect(saved.snapshot.format == .jpeg(quality: 0.92))
        #expect(saved.snapshot.bytes.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(saved.url.lastPathComponent == "Shot.jpg")
    }

    @Test("A fixed-format save keeps the name its panel chose")
    func fixedSaveKeepsName() async throws {
        let h = try await photographicHarness()
        let chosen = URL(fileURLWithPath: "/tmp/recortia-tests/Shot.png")
        let outcome = await h.export(.save(to: chosen, format: .fixed(.png), overwriteConfirmed: false))
        #expect(outcome == .saved(chosen))
        #expect(h.files.saves.last?.snapshot.format == .png)
    }

    @Test("Automatic applies to saved files; Copy Image stays a PNG")
    func copyStaysPNG() async throws {
        let h = try await photographicHarness()
        #expect(h.coordinator.exportOptions(for: .copy).formatChoice == .fixed(.png))
        #expect(
            h.coordinator.exportOptions(for: .saveToFolder(URL(fileURLWithPath: "/tmp"))).formatChoice == .automatic)
        #expect(await h.export(.copy) == .copied)
        #expect(h.clipboard.writes.last?.format == .png)

        h.folders.folder = URL(fileURLWithPath: "/tmp/recortia-tests/folder", isDirectory: true)
        let folder = try #require(h.folders.folder)
        #expect(await h.export(.saveToFolder(folder)) != .rejectedBusy)
        #expect(h.files.uniqueSaves.last?.snapshot.suggestedFilename.hasSuffix(".jpg") == true)
    }
}
