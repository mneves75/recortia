import AppKit

/// Presents `NSOpenPanel` and `NSSavePanel` dialogs with Recortia's Space policy and Dock presence
/// rules (FR-01, ADR-007).
///
/// Every file panel applies `SpacePolicy.follow(panel)` before activating the app, so activation
/// cannot switch Spaces, and refreshes `AppPresence` on dismissal because AppKit orders finished
/// file panels out rather than closing them. `present(_:)` runs modelessly through
/// `panel.begin(completionHandler:)`; only `runModal(_:)` runs app-modal.
@MainActor
enum FilePanelPresenter {
    /// Runs `panel` asynchronously without blocking the main run loop; cancelling the calling task
    /// dismisses the panel and returns nil.
    static func present(_ panel: NSSavePanel) async -> URL? {
        guard !Task.isCancelled else { return nil }
        SpacePolicy.follow(panel)
        AppPresence.shared.activate()
        defer {
            panel.orderOut(nil)
            AppPresence.shared.setNeedsRefresh()
        }
        let response = await CancellableModalPrompt().run(
            begin: { panel.begin(completionHandler: $0) }, dismiss: { panel.cancel(nil) })
        return response == .OK ? panel.url : nil
    }

    /// Runs `panel` synchronously for callers whose API requires a synchronous choice (such as
    /// `SettingsStore`'s automatic-save folder picker).
    static func runModal(_ panel: NSSavePanel) -> URL? {
        SpacePolicy.follow(panel)
        AppPresence.shared.activate()
        defer {
            panel.orderOut(nil)
            AppPresence.shared.setNeedsRefresh()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Bridges an AppKit completion-handler modal prompt to structured concurrency so cancelling the
/// enclosing task dismisses the prompt and resumes with `.abort`.
@MainActor
final class CancellableModalPrompt {
    private var completion: CheckedContinuation<NSApplication.ModalResponse, Never>?

    func run(
        begin: (@escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) async -> NSApplication.ModalResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .abort)
                    return
                }
                completion = continuation
                begin { [weak self] in self?.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.completion != nil else { return }
                dismiss()
                self.finish(.abort)
            }
        }
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        let continuation = completion
        completion = nil
        continuation?.resume(returning: response)
    }
}
