import Foundation

/// Ordered `@MainActor` continuations that resume promptly on task cancellation, explicit
/// settlement, or owner teardown without leaking or double-resuming.
@MainActor
final class CancellableWaiters<Value: Sendable> {
    private struct Entry {
        let id: UUID
        let continuation: CheckedContinuation<Value, Never>
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }

    /// Suspends until `resumeAll(returning:)` runs or the calling task is cancelled (in which
    /// case `cancelledValue` is returned promptly). `onRegister` runs synchronously inside the
    /// continuation registration, before suspension, for observation setup.
    func wait(cancelledValue: Value, onRegister: () -> Void = {}) async -> Value {
        guard !Task.isCancelled else { return cancelledValue }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: cancelledValue)
                    return
                }
                entries.append(Entry(id: id, continuation: continuation))
                onRegister()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id, returning: cancelledValue)
            }
        }
    }

    /// Resumes every waiting continuation in registration (FIFO) order.
    func resumeAll(returning value: Value) {
        guard !entries.isEmpty else { return }
        let pending = entries
        entries = []
        for entry in pending {
            entry.continuation.resume(returning: value)
        }
    }

    private func cancel(_ id: UUID, returning value: Value) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index).continuation.resume(returning: value)
    }
}
