import Observation

/// Re-runs `body` whenever an observable property it read changes, until canceled. AppKit
/// presenters use it to follow a feature model's state. `body` runs synchronously at init; the
/// macOS 26 `Observations` sequence delivers its first value asynchronously and coalesces
/// intermediate states, so replacing this loop is a measured change, not a floor cleanup.
final class ObservationLoop {
    private var isActive = true
    private let body: @MainActor @Sendable () -> Void

    init(_ body: @escaping @MainActor @Sendable () -> Void) {
        self.body = body
        observe()
    }

    func cancel() { isActive = false }

    private func observe() {
        guard isActive else { return }
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }
}
