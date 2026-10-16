import Foundation

/// One user-paced offer at a time (the drag-out chip). Each offer gets its own identifier, and a
/// completion resolves the offer only while it is still the current one: a late write completion
/// from a dismissed or replaced offer can never resolve the next offer.
@MainActor
public final class PendingOffer<Outcome: Sendable> {
    private var current: (id: UUID, continuation: CheckedContinuation<Outcome, Never>)?

    public init() {}

    public var currentID: UUID? { current?.id }

    /// Suspends until this offer is resolved. `start` receives the offer's identifier, which its
    /// completions must pass to `resolve(_:with:)`.
    public func wait(_ start: (UUID) -> Void) async -> Outcome {
        await withCheckedContinuation { continuation in
            let id = UUID()
            current = (id, continuation)
            start(id)
        }
    }

    /// Resolves the offer `id` if it is still current. Returns false for a stale identifier.
    @discardableResult
    public func resolve(_ id: UUID, with outcome: Outcome) -> Bool {
        guard let current, current.id == id else { return false }
        self.current = nil
        current.continuation.resume(returning: outcome)
        return true
    }

    /// Resolves whichever offer is current, if any (a new offer replaces it, or the user dismisses it).
    public func resolveCurrent(with outcome: Outcome) {
        guard let id = current?.id else { return }
        resolve(id, with: outcome)
    }
}
