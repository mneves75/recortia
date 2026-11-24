import Domain
import Foundation
import Testing

@testable import Features

/// IO-01: one import reads bytes at a time. A drop must be admitted and read while the drag
/// pasteboard is still valid, so admission is synchronous and separate from the async decode.
@MainActor
@Suite("Image import admission (IO-01)")
struct ImageImporterAdmissionTests {
    private let input = FakeImageInput()
    private let assets = FakeAssetService()

    private func importer() -> ImageImporter { ImageImporter(input: input, assets: assets) }

    @Test("A second admission while the slot is held is busy and never reads")
    func busyAdmissionNeverReads() throws {
        let importer = importer()
        _ = try importer.admit { .droppedData(Data([1])) }
        var reads = 0
        #expect(throws: ImportFailure.busy) {
            _ = try importer.admit {
                reads += 1
                return .droppedData(Data([2]))
            }
        }
        #expect(reads == 0)
    }

    @Test("Releasing an unused admission frees the slot without decoding")
    func releaseFreesWithoutDecoding() throws {
        let importer = importer()
        let admission = try importer.admit { .droppedData(Data([9])) }
        importer.release(admission)
        #expect(!importer.isImporting)
        #expect(assets.imported.isEmpty)
    }

    @Test("A reader that fails after admission frees the slot and reports its failure")
    func failingReaderFreesTheSlot() throws {
        let importer = importer()
        #expect(throws: ImportFailure.unsupportedFormat) {
            _ = try importer.admit { () throws(ImportFailure) -> ImportSource in throw .unsupportedFormat }
        }
        #expect(!importer.isImporting)
    }

    @Test("Stale or duplicate release cannot unlock a newer active admission or in-flight import")
    func staleOrDuplicateReleaseCannotUnlockActiveSlot() async throws {
        let importer = importer()
        let stale = try importer.admit { .droppedData(Data([1])) }
        importer.release(stale)
        #expect(!importer.isImporting)

        let active = try importer.admit { .droppedData(Data([2])) }
        importer.release(stale)
        #expect(importer.isImporting, "stale release must not unlock another admission")

        let pending = Pending<Void>()
        assets.pendingImport = pending
        let running = Task { try await importer.importImage(active) }
        await waitFor("import in flight") { pending.waiterCount == 1 }

        importer.release(active)
        importer.release(stale)
        #expect(importer.isImporting, "release must not unlock an admission already importing")

        pending.resolve(())
        _ = try await running.value
        #expect(!importer.isImporting)
    }

    @Test("Stale or reused admission fails closed in importImage without I/O or unlocking the slot")
    func staleOrReusedAdmissionFailsClosed() async throws {
        let importer = importer()
        let url = URL(fileURLWithPath: "/tmp/recortia-tests/stale-admission.png")
        input.files[url] = .success(Data([1, 2, 3]))

        let released = try importer.admit { .file(url) }
        importer.release(released)
        do {
            _ = try await importer.importImage(released)
            Issue.record("expected released admission to fail closed")
        } catch {
            #expect(error == .cancelled)
        }
        #expect(input.fileReads.isEmpty)
        #expect(assets.imported.isEmpty)
        #expect(!importer.isImporting)

        let active = try importer.admit { .droppedData(Data([9])) }
        let pending = Pending<Void>()
        assets.pendingImport = pending
        let running = Task { try await importer.importImage(active) }
        await waitFor("active import in flight") { pending.waiterCount == 1 }

        // Neither the stale admission nor a duplicate call with the active admission may run or unlock.
        for candidate in [released, active] {
            do {
                _ = try await importer.importImage(candidate)
                Issue.record("expected busy failure for stale/duplicate importImage")
            } catch {
                #expect(error == .busy)
            }
        }
        #expect(importer.isImporting)
        #expect(input.fileReads.isEmpty)

        pending.resolve(())
        _ = try await running.value
        #expect(!importer.isImporting)
        #expect(assets.imported.count == 1)
    }

}
