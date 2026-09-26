import AppKit
import Domain
import Foundation
import Testing

@testable import MacPlatform

@MainActor
@Suite("Drag-out file promises carry only the sanitized snapshot bytes (FR-07, EXP-02)")
struct DragOutProviderTests {
    private func write(_ provider: DragOutProvider, to url: URL) async -> (any Error)? {
        let promise = provider.makeFilePromiseProvider()
        return await withCheckedContinuation { continuation in
            provider.filePromiseProvider(promise, writePromiseTo: url) { error in
                continuation.resume(returning: error)
            }
        }
    }

    @Test("The receiver's file gets bytes identical to the snapshot")
    func writesIdenticalBytes() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let snapshot = TestSupport.snapshot()
        let provider = DragOutProvider(snapshot: snapshot)
        let url = folder.appendingPathComponent("dropped.png")
        let error = await write(provider, to: url)
        #expect(error == nil)
        #expect(try Data(contentsOf: url) == snapshot.bytes)
        #expect(TestSupport.directoryEntries(folder) == ["dropped.png"])
    }

    @Test("A write the receiver cannot accept reports an error and leaves no file")
    func reportsWriteFailure() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let provider = DragOutProvider(snapshot: TestSupport.snapshot())
        let url = folder.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("x.png")
        let error = await write(provider, to: url)
        #expect(error != nil)
        #expect(TestSupport.directoryEntries(folder).isEmpty)
    }

    @Test("A revoked lease writes nothing, even when the receiver asks for the file later")
    func revokedLeaseWritesNothing() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let lease = ExportLease()
        let provider = DragOutProvider(snapshot: TestSupport.snapshot(), lease: lease)
        lease.revoke()
        let error = await write(provider, to: folder.appendingPathComponent("stale.png"))
        #expect(error as? DragOutProvider.WriteError == .revoked)
        #expect(TestSupport.directoryEntries(folder).isEmpty)
    }

    @Test("An existing file at the receiver's URL is never replaced")
    func neverReplacesExistingFile() async throws {
        let folder = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.removeDirectory(folder) }
        let url = folder.appendingPathComponent("taken.png")
        let original = Data("keep me".utf8)
        try original.write(to: url)
        let error = await write(DragOutProvider(snapshot: TestSupport.snapshot()), to: url)
        #expect(error != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("The promised name and type come from the snapshot, sanitized")
    func nameAndType() throws {
        let snapshot = TestSupport.snapshot(suggestedFilename: "../evil/shot:1.png")
        let provider = DragOutProvider(snapshot: snapshot)
        let promise = provider.makeFilePromiseProvider()
        #expect(promise.fileType == "public.png")
        #expect(provider.filePromiseProvider(promise, fileNameForType: promise.fileType) == "shot-1.png")
        let jpeg = DragOutProvider(
            snapshot: TestSupport.snapshot(format: .jpeg(quality: 0.8), suggestedFilename: "a.jpg"))
        #expect(jpeg.makeFilePromiseProvider().fileType == "public.jpeg")
    }

    @Test("The file promise keeps its delegate and the snapshot bytes alive for the transfer")
    func promiseRetainsProvider() throws {
        weak var weakProvider: DragOutProvider?
        let promise: NSFilePromiseProvider
        do {
            let provider = DragOutProvider(snapshot: TestSupport.snapshot())
            weakProvider = provider
            promise = provider.makeFilePromiseProvider()
        }
        #expect(weakProvider != nil)
        #expect(promise.delegate === weakProvider)
    }

    @Test("Promised files are written off the main queue")
    func writesOffMain() {
        let provider = DragOutProvider(snapshot: TestSupport.snapshot())
        let queue = provider.operationQueue(for: provider.makeFilePromiseProvider())
        #expect(queue !== OperationQueue.main)
        #expect(queue.maxConcurrentOperationCount == 1)
    }
}
