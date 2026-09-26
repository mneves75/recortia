import AppKit
import Domain
import Features
import MacPlatform
import SwiftUI

/// Presents the capture UI that matches the coordinator's state: region overlays while selecting
/// a region, a chooser for windows or displays, the countdown HUD, and failure messages.
/// It holds no capture logic of its own.
final class CaptureUIController {
    private let coordinator: CaptureCoordinator
    private let overlay = RegionOverlayController()
    private var chooser: HostingPanel?
    private var chooserKind: SelectionKind?
    private var countdown: HostingPanel?
    private var lastState: CaptureState = .idle
    private var loop: ObservationLoop?

    private enum SelectionKind: Equatable {
        case loadingWindows
        case windows([WindowInfo])
        case displays([DisplayInfo])
    }

    init(coordinator: CaptureCoordinator) {
        self.coordinator = coordinator
        overlay.onCommit = { [weak coordinator] rect, display in
            coordinator?.commitRegion(rect, on: display)
        }
        overlay.onCancel = { [weak coordinator] in coordinator?.cancel() }
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let state = coordinator.state
        let context = coordinator.selectionContext
        let notice = coordinator.notice

        switch (state, context) {
        case (.selecting, .region(let displays)?):
            closeChooser()
            closeCountdown()
            overlay.present(displays: displays, notice: noticeText(notice))
        case (.selecting, .loadingWindows?):
            overlay.dismiss()
            showChooser(.loadingWindows)
        case (.selecting, .window(let windows)?):
            overlay.dismiss()
            showChooser(.windows(windows))
        case (.selecting, .display(let displays)?):
            overlay.dismiss()
            showChooser(.displays(displays))
        case (.countdown(let remaining), _):
            overlay.dismiss()
            closeChooser()
            showCountdown(remaining)
        default:
            overlay.dismiss()
            closeChooser()
            closeCountdown()
        }

        if state != lastState, case .failed(let failure) = state {
            Task { MessagePresenter.present(.capture(failure)) }
        }
        lastState = state
    }

    private func noticeText(_ notice: CaptureCoordinator.Notice?) -> String? {
        switch notice {
        case .repeatRegionUnavailable:
            String(localized: "The display of your last region changed. Select an area again.")
        case .captureInProgress, nil:
            nil
        }
    }

    private func showChooser(_ kind: SelectionKind) {
        guard kind != chooserKind else { return }
        chooserKind = kind
        let panel = chooser ?? HostingPanel(title: String(localized: "Capture"), activating: true)
        chooser = panel
        let cancel: () -> Void = { [weak coordinator] in coordinator?.cancel() }
        switch kind {
        case .loadingWindows:
            panel.setContent(WindowChooserView(windows: nil, onChoose: { _ in }, onCancel: cancel))
        case .windows(let windows):
            panel.setContent(
                WindowChooserView(
                    windows: windows, onChoose: { [weak coordinator] in coordinator?.commitSelection(.window($0)) },
                    onCancel: cancel))
        case .displays(let displays):
            panel.setContent(
                DisplayChooserView(
                    displays: displays,
                    onChoose: { [weak coordinator] in coordinator?.commitSelection(.display($0)) }, onCancel: cancel))
        }
        panel.present(activate: true)
    }

    private func closeChooser() {
        chooser?.orderOut(nil)
        chooser = nil
        chooserKind = nil
    }

    private func showCountdown(_ remaining: Int) {
        guard countdown == nil else { return }  // the hosted view follows the coordinator itself
        let panel = HostingPanel(title: String(localized: "Delayed Capture"), activating: false)
        countdown = panel
        panel.setContent(LiveCountdownView(coordinator: coordinator))
        panel.present(activate: false)
    }

    private func closeCountdown() {
        countdown?.orderOut(nil)
        countdown = nil
    }
}

/// Follows the coordinator so the number updates in place.
private struct LiveCountdownView: View {
    let coordinator: CaptureCoordinator

    var body: some View {
        if case .countdown(let remaining) = coordinator.state {
            CountdownView(remaining: remaining, onCancel: { coordinator.cancel() })
        }
    }
}
