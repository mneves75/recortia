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
    private let overlay: RegionOverlayController
    private var chooser: HostingPanel?
    private var chooserKind: SelectionKind?
    private var countdown: HostingPanel?
    private var escape: EscapeHotKey?
    private var lastState: CaptureState = .idle
    private var loop: ObservationLoop?

    private enum SelectionKind: Equatable {
        case loadingWindows
        case windows([WindowInfo])
        case displays([DisplayInfo])
    }

    init(coordinator: CaptureCoordinator, overlay: RegionOverlayController = RegionOverlayController()) {
        self.coordinator = coordinator
        self.overlay = overlay
        overlay.onCommit = { [weak coordinator, weak overlay] rect, display in
            guard let coordinator else { return }
            let visibleFrozenFrame =
                overlay?.presentedWindows.first { $0.display.id == display.id }?
                .selectionView.showsFrozenFrame == true
            let readyFrozenFrame = if case .frozen = coordinator.regionFreeze { true } else { false }
            guard visibleFrozenFrame == readyFrozenFrame else { return }
            if coordinator.commitRegion(rect, on: display), readyFrozenFrame {
                overlay?.dismiss()
            }
        }
        overlay.onCancel = { [weak coordinator] in coordinator?.cancel() }
        overlay.onSwitchToWindow = { [weak coordinator] in coordinator?.switchToWindowSelection() }
        overlay.onAspectChange = { [weak coordinator] in coordinator?.setRegionAspect($0) }
        overlay.onFreezeToggle = { [weak coordinator] display in coordinator?.toggleRegionFreeze(on: display) }
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    /// Pre-builds the region overlays for `displays` (at launch and after a display change).
    func prepareOverlays(_ displays: [DisplayInfo]) {
        overlay.prepare(displays: displays)
    }

    private func render() {
        let state = coordinator.state
        let context = coordinator.selectionContext
        let notice = coordinator.notice

        switch (state, context) {
        case (.selecting, .region(let displays)?):
            closeChooser()
            closeCountdown()
            let freeze = coordinator.regionFreeze
            overlay.present(
                displays: freeze.map { [$0.display] } ?? displays, notice: noticeText(notice),
                allowsWindowSwitch: coordinator.mode == .region && coordinator.purpose == .edit,
                aspect: coordinator.regionAspect, snapFrames: coordinator.snapFrames,
                allowsFreeze: coordinator.canFreezeRegion, freeze: freeze)
            if overlay.isPresented { coordinator.selectionDidAppear() }
        case (.selecting, .loadingWindows?):
            overlay.dismiss()
            showChooser(.loadingWindows)
        case (.selecting, .window(let windows)?):
            overlay.dismiss()
            showChooser(.windows(windows))
        case (.selecting, .display(let displays)?):
            overlay.dismiss()
            showChooser(.displays(displays))
        case (.countdown, _):
            overlay.dismiss()
            closeChooser()
            showCountdown()
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
        case .freezeUnavailable:
            String(localized: "Could not freeze this display. You can still select an area.")
        case .freezeBusy:
            String(localized: "The previous freeze was still finishing. Press F to try again.")
        case .freezeExpired:
            String(localized: "The frozen frame expired. Select a live area or press F to freeze again.")
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
        coordinator.selectionDidAppear()
    }

    private func closeChooser() {
        chooser?.orderOut(nil)
        chooser = nil
        chooserKind = nil
    }

    private func showCountdown() {
        guard countdown == nil else { return }  // the hosted view follows the coordinator itself
        let panel = Self.makeCountdownPanel()
        countdown = panel
        panel.setContent(LiveCountdownView(coordinator: coordinator), fixedToFittingSize: true)
        panel.present(activate: false)
        // The panel does not take focus from the app being captured, so Escape is a temporary
        // system-wide hot key for as long as the countdown shows.
        escape = EscapeHotKey { [coordinator] in coordinator.cancel() }
        // Without the hot key (another app owns Escape), give the countdown the keyboard so a
        // keyboard-only user can still cancel; a nonactivating panel takes it without activation.
        if escape == nil { panel.makeKey() }
    }

    /// Shown without taking focus from the app being captured. It becomes key on a click, or at
    /// once when the temporary Escape hot key could not be registered, so Escape still cancels.
    static func makeCountdownPanel() -> HostingPanel {
        HostingPanel(title: String(localized: "Delayed Capture"), activating: false, keyOnClick: true)
    }

    private func closeCountdown() {
        escape?.unregister()
        escape = nil
        countdown?.orderOut(nil)
        countdown = nil
    }
}

private struct LiveCountdownView: View {
    let coordinator: CaptureCoordinator

    var body: some View {
        if case .countdown(let remaining) = coordinator.state {
            CountdownView(remaining: remaining, onCancel: { coordinator.cancel() })
        }
    }
}
