import Synchronization

/// Permission for one pending export to still commit. A drag-out waits for the user for an
/// unbounded time and its real commit (the receiver's file-promise write) happens later, on
/// another thread; the lease lets the document revoke it the moment the document changes, the
/// user cancels, or the editor closes, so a snapshot older than a new redaction is never written.
public final class ExportLease: Sendable {
    private let revoked = Mutex(false)

    public init() {}

    public var isRevoked: Bool { revoked.withLock { $0 } }

    public func revoke() { revoked.withLock { $0 = true } }
}
