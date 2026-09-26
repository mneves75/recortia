import AppKit
import Domain

/// Drag-out of a sanitized snapshot as a file promise (FR-07, EXP-02).
///
/// Use `makeFilePromiseProvider()` as the dragging item. The returned provider holds this object in
/// its `userInfo`, so the snapshot bytes live exactly as long as AppKit keeps the promise for the
/// transfer, and are released when the drag ends or is canceled. Only the snapshot's encoded bytes
/// are written; nothing is deleted after the write. The receiver asks for the file later, on a
/// background queue, so the write re-checks `lease`: a document change, cancel, or editor close
/// revokes it and the stale snapshot is never written.
@MainActor
public final class DragOutProvider: NSObject, NSFilePromiseProviderDelegate {
    public enum WriteError: Error, Equatable, Sendable {
        /// The export was invalidated before the receiver requested the file.
        case revoked
    }

    public nonisolated let snapshot: ShareSnapshot
    public nonisolated let lease: ExportLease
    private let writeQueue: OperationQueue

    public init(snapshot: ShareSnapshot, lease: ExportLease = ExportLease()) {
        self.snapshot = snapshot
        self.lease = lease
        writeQueue = OperationQueue()
        writeQueue.name = "recortia.drag-out"
        writeQueue.maxConcurrentOperationCount = 1
        writeQueue.qualityOfService = .userInitiated
        super.init()
    }

    public func makeFilePromiseProvider() -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: snapshot.format.utTypeIdentifier, delegate: self)
        // `delegate` is weak; the strong `userInfo` reference keeps this object and its bytes alive
        // for the lifetime of the promise.
        provider.userInfo = self
        return provider
    }

    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String)
        -> String
    {
        SafeFilename.sanitize(snapshot.suggestedFilename, fallbackExtension: snapshot.format.fileExtension)
    }

    public nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard !lease.isRevoked else {
            completionHandler(WriteError.revoked)
            return
        }
        do {
            // Never replace a file the receiver already has at this URL.
            try snapshot.bytes.write(to: url, options: [.withoutOverwriting])
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }
}
