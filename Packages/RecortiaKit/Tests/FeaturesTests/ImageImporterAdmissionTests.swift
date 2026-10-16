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

}
