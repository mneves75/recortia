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
            try ImageDecoder.canonicalize(try ChartFixture.photographic(width: 1200, height: 900)), origin: .imported)
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
        let outcome = await h.export(.save(to: chosen, format: .automatic, replacing: nil))
        #expect(outcome == .saved(URL(fileURLWithPath: "/tmp/recortia-tests/Shot.jpg")))
        let saved = try #require(h.files.saves.last)
        #expect(saved.snapshot.format == .jpeg(quality: 0.92))
        #expect(saved.snapshot.bytes.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(saved.url.lastPathComponent == "Shot.jpg")
    }

    // Failure modes (data loss): the Replace question named no file, so with report.png and
    // report.jpg both present the person could confirm one and lose the other; and the retry
    // rendered again, so Automatic could name another file and overwrite it unasked, including
    // one whose collision another editor's save had just reported.
    private static let chosen = URL(fileURLWithPath: "/tmp/recortia-tests/Shot.png")
    private static let jpegName = URL(fileURLWithPath: "/tmp/recortia-tests/Shot.jpg")

    @Test("A collision names the file the save resolved to, so the question can name it")
    func collisionNamesTheResolvedFile() async throws {
        let h = try await photographicHarness()
        h.files.existing = [Self.chosen, Self.jpegName]
        #expect(
            await h.export(.save(to: Self.chosen, format: .automatic, replacing: nil))
                == .failed(.destinationExists(Self.jpegName)), "Automatic chose the JPEG")
        #expect(
            await h.export(.save(to: Self.chosen, format: .fixed(.png), replacing: nil))
                == .failed(.destinationExists(Self.chosen)))
        #expect(h.files.saves.isEmpty)
    }

    @Test("Consent to replace Shot.jpg never overwrites Shot.png")
    func consentForTheJPEGNeverReplacesThePNG() async throws {
        let h = try await photographicHarness()
        h.files.existing = [Self.chosen, Self.jpegName]
        // Automatic now keeps the PNG (a Settings change while the question was open); the fake
        // renderer's PNG stands in for that new choice.
        h.exporter.pipeline = nil
        let retry = await h.export(.save(to: Self.chosen, format: .automatic, replacing: Self.jpegName))
        #expect(retry == .failed(.destinationExists(Self.chosen)), "asks again, naming Shot.png")
        #expect(h.files.saves.isEmpty, "nothing is overwritten without consent that names it")
    }

    @Test("Consent replaces exactly the file it names")
    func consentReplacesTheNamedFile() async throws {
        let h = try await photographicHarness()
        h.files.existing = [Self.jpegName]
        let retry = await h.export(.save(to: Self.chosen, format: .automatic, replacing: Self.jpegName))
        #expect(retry == .saved(Self.jpegName))
        #expect(h.files.saves.map(\.url) == [Self.jpegName] && h.files.saves.last?.overwrite == true)
    }

    @Test("One editor's consent never uses another editor's collision at the same panel name")
    func consentIsPerSave() async throws {
        let a = try await photographicHarness()
        let sessionA = a.session
        a.files.existing = [Self.chosen, Self.jpegName]
        // A asks about Shot.jpg.
        guard
            case .failed(.destinationExists(let askedByA?)) = await a.export(
                .save(to: Self.chosen, format: .automatic, replacing: nil))
        else { Issue.record("A's save did not collide"); return }
        #expect(askedByA == Self.jpegName)
        // B, a PNG document on the same coordinator, collides at Shot.png before A answers.
        a.exporter.pipeline = nil
        a.session = TestFixtures.session()
        #expect(
            await a.export(.save(to: Self.chosen, format: .automatic, replacing: nil))
                == .failed(.destinationExists(Self.chosen)))
        // A confirms Shot.jpg, but its retry now resolves to Shot.png: B's question is unanswered.
        let retry = await a.coordinator.export(
            .save(to: Self.chosen, format: .automatic, replacing: askedByA), session: sessionA,
            currentSession: { sessionA })
        #expect(retry == .failed(.destinationExists(Self.chosen)))
        #expect(a.files.saves.isEmpty, "B's Shot.png is not overwritten by A's consent")
    }

    @Test("A fixed-format save keeps the name its panel chose")
    func fixedSaveKeepsName() async throws {
        let h = try await photographicHarness()
        let chosen = URL(fileURLWithPath: "/tmp/recortia-tests/Shot.png")
        let outcome = await h.export(.save(to: chosen, format: .fixed(.png), replacing: nil))
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
