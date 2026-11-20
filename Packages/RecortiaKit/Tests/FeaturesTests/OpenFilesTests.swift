import Domain
import Foundation
import Imaging
import RecortiaFixtures
import Testing

@testable import Features

// Failure modes (FR-03, IO-01): files handed over by Open With, a drop on the Dock icon or
// `open -a` bypass admission, read bytes while another import holds the slot, stop the batch at
// the first bad file, or open an unbounded number of editors.
@Suite("Opening files from the system (FR-03, IO-01)")
@MainActor
struct OpenFilesTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/recortia-tests/\(name)") }

    private func realDecodeHarness() throws -> ImportHarness {
        let h = ImportHarness()
        h.assets.store = ImageStore()
        return h
    }

    @Test("Each file opens its own editor, in order, through the shared slot")
    func severalFiles() async throws {
        let h = try realDecodeHarness()
        let png = try ContainerCrafting.pngData(ChartFixture.geometryChart(width: 32, height: 24))
        let files = [url("a.png"), url("b.png"), url("c.png")]
        for file in files { h.input.files[file] = .success(png) }
        let failures = await h.coordinator.openFiles(files)
        #expect(failures.isEmpty)
        #expect(h.fileNames == ["a.png", "b.png", "c.png"])
        #expect(h.input.fileReads == files)
        #expect(!h.coordinator.isImporting)
    }

    @Test("An oversized file and a non-image are refused; the files around them still open")
    func refusalsDoNotStopTheBatch() async throws {
        let h = try realDecodeHarness()
        let png = try ContainerCrafting.pngData(ChartFixture.geometryChart(width: 32, height: 24))
        h.input.files[url("first.png")] = .success(png)
        h.input.files[url("huge.png")] = .failure(.tooManyBytes)
        h.input.files[url("notes.png")] = .success(Data("not an image".utf8))
        h.input.files[url("last.jpg")] = .success(png)
        let failures = await h.coordinator.openFiles([
            url("first.png"), url("huge.png"), url("notes.png"), url("last.jpg"),
        ])
        #expect(failures == [.tooLarge, .unsupportedFormat])
        #expect(h.fileNames == ["first.png", "last.jpg"])
    }

    @Test("Eleven files in one request: the first ten are read and opened, the eleventh is refused unread")
    func batchLimit() async {
        let h = ImportHarness()
        let files = (0..<11).map { url("\($0).png") }
        for file in files { h.input.files[file] = .success(Data([1])) }
        let failures = await h.coordinator.openFiles(files)
        #expect(h.imported.count == 10)
        #expect(h.input.fileReads == Array(files.prefix(10)))
        #expect(failures == [.tooManyFiles])
    }

    @Test("Requests queued before launch keep their own limit and open one after another")
    func queuedRequestsKeepTheirBoundaries() async {
        let h = ImportHarness()
        let first = (0..<6).map { url("first-\($0).png") }
        let second = (0..<6).map { url("second-\($0).png") }
        for file in first + second { h.input.files[file] = .success(Data([1])) }
        let failures = await h.coordinator.openRequests([first, second])
        #expect(failures == [[], []])
        #expect(h.imported.count == 12)
        #expect(h.input.fileReads == first + second)
    }

    @Test("While another import holds the slot, opened files are refused as busy before any read")
    func busySlot() async throws {
        let h = ImportHarness()
        let pending = Pending<Void>()
        h.assets.pendingImport = pending
        let first = Task { await h.coordinator.importImage(from: .droppedData(Data([1]))) }
        await waitFor("first import decoding") { pending.waiterCount == 1 }
        h.input.files[url("a.png")] = .success(Data([2]))
        let failures = await h.coordinator.openFiles([url("a.png")])
        #expect(failures == [.busy])
        #expect(h.input.fileReads.isEmpty)
        pending.resolve(())
        _ = try await first.value.get()
        #expect(h.imported.count == 1)
    }
}
