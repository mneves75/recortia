import Synchronization

/// Permission for one pending export to still commit. A drag-out waits for the user for an
/// unbounded time and its real commit (the receiver's file-promise write) happens later, on
/// another thread; the lease lets the document revoke it the moment the document changes, the
/// user cancels, or the editor closes, so a snapshot older than a new redaction is never written.
public final class ExportLease: Sendable {
    private enum State: Equatable {
        case active
        /// A commit is writing; a revoke now takes effect only if that commit fails.
        case committing(revokeRequested: Bool)
        case committed
        case revoked
    }

    private let state = Mutex(State.active)

    public init() {}

    public var isRevoked: Bool { state.withLock { $0 == .revoked } }

    /// The commit happened: the receiver has the file. Only a revocation before it can stop it.
    public var isCommitted: Bool { state.withLock { $0 == .committed } }

    /// Revokes a lease that has not started committing. A commit already writing was decided
    /// before the revoke, so it stands; the revoke applies only if that commit fails.
    public func revoke() {
        state.withLock { current in
            switch current {
            case .active: current = .revoked
            case .committing: current = .committing(revokeRequested: true)
            case .committed, .revoked: break
            }
        }
    }

    /// Runs `commit` once, only if the lease is still active, and marks the lease committed when
    /// it returns. The lock is held only to claim and settle the commit, never during it, so a
    /// revoke from the main actor never waits for disk I/O. Returns nil when the lease was
    /// revoked or already used; a throwing commit leaves the lease active (or revoked, if a
    /// revoke arrived meanwhile).
    public func whileValid<T>(_ commit: () throws -> T) rethrows -> T? {
        let claimed = state.withLock { current -> Bool in
            guard current == .active else { return false }
            current = .committing(revokeRequested: false)
            return true
        }
        guard claimed else { return nil }
        do {
            let result = try commit()
            state.withLock { $0 = .committed }
            return result
        } catch {
            state.withLock { current in
                if case .committing(let revokeRequested) = current { current = revokeRequested ? .revoked : .active }
            }
            throw error
        }
    }
}
