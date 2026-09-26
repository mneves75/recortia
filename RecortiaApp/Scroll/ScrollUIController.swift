import AppKit
import Domain
import Features
import MacPlatform
import SwiftUI

/// Presents the scrolling-capture UI for the model's state: region overlay while choosing the
/// area, the HUD while armed/collecting/paused, and the review window.
final class ScrollUIController {
    private let model: ScrollSessionModel
    private let displays: () -> [DisplayInfo]
    private let overlay = RegionOverlayController()
    private var hud: HostingPanel?
    private var review: NSWindow?
    private var lastState: ScrollState = .idle
    private var loop: ObservationLoop?

    init(model: ScrollSessionModel, displays: @escaping () -> [DisplayInfo]) {
        self.model = model
        self.displays = displays
        overlay.onCommit = { [weak model] rect, display in
            model?.chooseTarget(.region(rect, display: display))
        }
        overlay.onCancel = { [weak model] in model?.cancel() }
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let state = model.state
        switch state {
        case .selecting:
            if !overlay.isPresented {
                overlay.present(
                    displays: displays(),
                    notice: String(localized: "Select the area that scrolls. Leave out fixed headers if you can."))
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
        let window = NSWindow(contentViewController: NSHostingController(rootView: LiveScrollReview(model: model)))
        window.title = String(localized: "Review Scrolling Capture")
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        review = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeReview() {
        review?.orderOut(nil)
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

    var body: some View {
        ScrollReviewView(
            preview: model.preview, outputSize: model.outputSize, seams: model.seams,
            partialReason: model.partialReason, assemblyFailed: model.notice == .assemblyFailed,
            onAccept: { Task { await model.accept() } }, onDiscard: { model.discard() })
    }
}
