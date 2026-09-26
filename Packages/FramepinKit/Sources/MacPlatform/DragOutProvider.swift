import AppKit
import Domain

/// Drag-out of a sanitized snapshot as a file promise (FR-07, EXP-02).
///
/// Use `makeFilePromiseProvider()` as the dragging item. The returned provider holds this object in
/// its `userInfo`, so the snapshot bytes live exactly as long as AppKit keeps the promise for the
/// transfer, and are released when the drag ends or is canceled. Only the snapshot's encoded bytes
/// are written; nothing is deleted after the write.
@MainActor
public final class DragOutProvider: NSObject, NSFilePromiseProviderDelegate {
    public nonisolated let snapshot: ShareSnapshot
    private let writeQueue: OperationQueue

    public init(snapshot: ShareSnapshot) {
        self.snapshot = snapshot
        writeQueue = OperationQueue()
        writeQueue.name = "framepin.drag-out"
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
        do {
            try snapshot.bytes.write(to: url, options: [.atomic])
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }
}
