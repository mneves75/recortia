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
        let panel = Self.makeHUDPanel()
        panel.setContent(LiveScrollHUD(model: model))
        hud = panel
        panel.present(activate: false)
    }

    /// Shown without taking focus from the page being scrolled; a click makes it key.
    static func makeHUDPanel() -> HostingPanel {
        let panel = HostingPanel(title: String(localized: "Scrolling Capture"), activating: false, keyOnClick: true)
        panel.reservesTitleBarArea = false
        return panel
    }

    private func closeHUD() {
        hud?.orderOut(nil)
        hud = nil
    }

    private func showReview() {
        guard review == nil else { return }
        let window = makeReviewWindow()
        // On the display that was scrolled, not the key window's (FR-01).
        let displayID: CGDirectDisplayID? =
            switch model.target {
            case .region(_, let display)?, .display(let display)?: display.id
            case .window(let info)?: info.displayID
            case nil: nil
            }
        window.center(on: ScreenChoice.screen(displayID: displayID))
        AppPresence.shared.present(window)
    }

    /// The one destructive path out of the review: close, Escape, and Discard all ask here first,
    /// in a sheet on the review window, without a modal loop. Refused while an Accept assembles
    /// or a question is already open; checked again at the answer, since main-actor work runs
    /// while the sheet is up. Quit asks about the review itself (`AppModel.shouldTerminate`).
    func requestDiscard() {
        guard let window = review, model.canDiscard, window.attachedSheet == nil else { return }
        MessagePresenter.makeDiscardScrollingCapture().beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.review === window, self.model.canDiscard
            else { return }
            self.model.discard()
            // A discard is the person closing the review, as the close button does: `close()` (not
            // the order-out that Accept's replacement uses) lets `AppPresence` see a real close.
            // `close()` does not ask `windowShouldClose` again.
            window.close()
            self.review = nil
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Nothing left to discard (accepted or ended): close without asking.
        guard sender === review, model.state == .reviewing else { return true }
        requestDiscard()
        return false
    }

    /// Builds the review window, takes its delegate, and becomes the one place a discard can be
    /// requested. The discard closure is not a parameter: a caller that forgot it would wire the
    /// Discard and Escape buttons straight to destruction without asking.
    func makeReviewWindow() -> NSWindow {
        let window = NSWindow(
            contentViewController: NSHostingController(
                rootView: LiveScrollReview(model: model, onDiscard: { [weak self] in self?.requestDiscard() })))
        window.title = String(localized: "Scrolling Capture")
        // Titled windows keep a close button; `windowShouldClose` asks before a close discards.
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        SpacePolicy.follow(window)
        if review == nil { review = window }
        return window
    }

    private func closeReview() {
        // The review ended another way (Accept, cancel): an open discard question has no answer.
        if let review {
            for sheet in review.sheets { review.endSheet(sheet, returnCode: .abort) }
        }
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
            isPreparingPreview: model.isPreparingPreview, canAccept: model.canAccept, canDiscard: model.canDiscard,
            onAccept: { Task { await model.accept() } }, onDiscard: onDiscard)
    }
}
