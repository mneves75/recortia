import AppKit
import Domain
import Features
import MacPlatform
import SwiftUI

/// Presents the scrolling-capture UI for the model's state: region overlay while choosing the
/// area, the HUD while armed/collecting/paused, and the review window.
final class ScrollUIController: NSObject, NSWindowDelegate {
    private let model: ScrollSessionModel
    private let displays: () -> [DisplayInfo]
    private let overlay = RegionOverlayController()
    private var hud: HostingPanel?
    private var review: NSWindow?
    private var lastState: ScrollState = .idle
    private var loop: ObservationLoop?
    /// Injected so the E2E runner can prove the discard gate without presenting a modal alert.
    var confirmDiscard: @MainActor () -> Bool = MessagePresenter.confirmDiscardScrollingCapture

    init(model: ScrollSessionModel, displays: @escaping () -> [DisplayInfo]) {
        self.model = model
        self.displays = displays
        overlay.onCommit = { [weak model] rect, display in
            model?.chooseTarget(.region(rect, display: display))
        }
        overlay.onCancel = { [weak model] in model?.cancel() }
        super.init()
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let state = model.state
        switch state {
        case .selecting:
            if !overlay.isPresented {
                overlay.present(
                    displays: displays(),
                    notice: String(localized: "Select the area that scrolls. Leave out fixed headers if you can."),
                    allowsWindowSwitch: false)
            }
            closeHUD()
            closeReview()
        case .armed, .collecting, .paused:
            overlay.dismiss()
            closeReview()
            showHUD()
        case .reviewing:
            overlay.dismiss()
            closeHUD()
            showReview()
        default:
            overlay.dismiss()
            closeHUD()
            closeReview()
        }
        if state != lastState, case .failed(let failure) = state {
            Task { MessagePresenter.present(.scroll(failure)) }
        }
        lastState = state
    }

    private func showHUD() {
        guard hud == nil else { return }
        // Shown without taking focus from the page being scrolled; a click makes it key so
        // Escape cancels (FR-10) without a global key monitor.
        let panel = HostingPanel(title: String(localized: "Scrolling Capture"), activating: false, keyOnClick: true)
        panel.setContent(LiveScrollHUD(model: model))
        hud = panel
        panel.present(activate: false)
    }

    private func closeHUD() {
        hud?.orderOut(nil)
        hud = nil
    }

    private func showReview() {
        guard review == nil else { return }
        let window = Self.makeReviewWindow(model: model, onDiscard: { [weak self] in self?.requestDiscard() })
        // On the display that was scrolled, not the key window's (FR-01).
        let displayID: CGDirectDisplayID? =
            switch model.target {
            case .region(_, let display)?, .display(let display)?: display.id
            case .window(let info)?: info.displayID
            case nil: nil
            }
        window.center(on: ScreenChoice.screen(displayID: displayID))
        review = window
        window.delegate = self
        AppPresence.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The one destructive path out of the review: close, Escape, and Discard all ask here first.
    func requestDiscard() {
        guard confirmDiscard() else { return }
        model.discard()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The delegate is only ever assigned to the review window, so asking here is the whole
        // contract. An identity guard on top of that only made the gate untestable.
        let discarded = confirmDiscard()
        if discarded { model.discard() }
        return discarded
    }

    static func makeReviewWindow(model: ScrollSessionModel, onDiscard: (() -> Void)? = nil) -> NSWindow {
        // Titled windows keep a close button; the controller asks before a close discards.
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: LiveScrollReview(model: model, onDiscard: onDiscard ?? { model.discard() })))
        window.title = String(localized: "Review Scrolling Capture")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        SpacePolicy.follow(window)
        return window
    }

    private func closeReview() {
        review?.orderOut(nil)
        AppPresence.shared.setNeedsRefresh()
        review = nil
    }
}

private struct LiveScrollHUD: View {
    let model: ScrollSessionModel

    var body: some View {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: sourceDescription, state: model.state, mode: model.mode, notice: model.notice,
                pageEndLikely: model.pageEndLikely, acceptedFrames: model.acceptedFrames,
                outputHeight: model.outputSize.height),
            onStart: { model.start() }, onPause: { model.pause() }, onResume: { model.resume() },
            onStop: { model.stop() }, onCancel: { model.cancel() })
    }

    private var sourceDescription: String {
        switch model.target {
        case .region(let rect, let display):
            String(localized: "Area of \(Int(rect.width)) × \(Int(rect.height)) points on \(display.localizedName)")
        case .display(let display):
            display.localizedName
        case .window(let window):
            window.ownerName
        case nil:
            ""
        }
    }
}

private struct LiveScrollReview: View {
    let model: ScrollSessionModel
    let onDiscard: () -> Void

    var body: some View {
        ScrollReviewView(
            preview: model.preview, outputSize: model.outputSize, seams: model.seams,
            partialReason: model.partialReason, assemblyFailed: model.notice == .assemblyFailed,
            onAccept: { Task { await model.accept() } }, onDiscard: onDiscard)
    }
}
