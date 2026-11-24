import AppKit
import Features
import SwiftUI

/// Skippable feature discovery, also available from the menu after first launch (FR-01).
/// It requests no permission; Screen Recording is asked for on the first capture.
struct OnboardingView: View {
    let onboarding: OnboardingModel
    let shortcutStatus: ShortcutStatusModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                TourPage(step: onboarding.step, shortcutStatus: shortcutStatus)
                    // Showing the shortcuts content (its page or the done state) is attention to them.
                    .onAppear {
                        if onboarding.step == .shortcuts || onboarding.step == .done {
                            shortcutStatus.noteUserAttention()
                        }
                    }
            }
            .id(onboarding.step)
            Divider()
            OnboardingNavigation(onboarding: onboarding, onClose: onClose)
                .padding(DesignTokens.Space.l)
        }
        .frame(minWidth: 540, minHeight: 480)
    }
}

private struct TourPage: View {
    let step: OnboardingModel.Step
    let shortcutStatus: ShortcutStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
            switch step {
            case .localProcessing: LocalProcessingStep()
            case .capture: CaptureTourStep()
            case .editing: EditingTourStep()
            case .sharing: SharingTourStep()
            case .shortcuts, .done: ShortcutsStep(shortcutStatus: shortcutStatus)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tour.page")
    }
}

private struct OnboardingNavigation: View {
    let onboarding: OnboardingModel
    let onClose: () -> Void

    private var isLastPage: Bool { onboarding.step == .shortcuts || onboarding.step == .done }

    var body: some View {
        HStack {
            if !isLastPage {
                Button("Skip") {
                    onboarding.finish()
                    onClose()
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tour.skip")
            }
            Spacer()
            if onboarding.canGoBack {
                Button("Back") { onboarding.back() }
                    .accessibilityIdentifier("tour.back")
            }
            if isLastPage {
                Button("Done") {
                    onboarding.finish()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("tour.done")
            } else {
                Button("Continue") { onboarding.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tour.next")
            }
        }
        .overlay {
            PageDots(current: onboarding.pageNumber, count: OnboardingModel.pageCount)
        }
    }
}

/// The tour's position: one dot per page, the current one in the selection colour.
private struct PageDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: DesignTokens.Space.s) {
            ForEach(1...count, id: \.self) { page in
                Circle()
                    .fill(page == current ? AnyShapeStyle(DesignTokens.selection) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "Page \(current) of \(count)",
                comment: "Tour progress: the first placeholder is the current page; the second is the total page count."
            )
        )
        .accessibilityIdentifier("tour.progress")
    }
}

/// One tour item: a title and one line.
private struct TourFeature: View {
    let symbol: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Space.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                Text(title).font(.headline)
                Text(detail).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TourHeading: View {
    let title: LocalizedStringResource

    var body: some View {
        Text(title).font(.largeTitle).accessibilityAddTraits(.isHeader)
    }
}

private struct LocalProcessingStep: View {
    var body: some View {
        TourHeading(title: "Welcome to Recortia")
        TourFeature(
            symbol: "lock.laptopcomputer", title: "Stays on this Mac",
            detail: "Capture, editing and recognition stay on this Mac."
        )
        TourFeature(
            symbol: "hand.raised", title: "Automatic exports start off",
            detail:
                "Automatic copy, save and upload are off on a fresh install. When on, they run right after a capture, before any redaction."
        )
        TourFeature(
            symbol: "network", title: "Optional GitHub sharing",
            detail:
                "Uploads leave this Mac and are off by default. Redacting or deleting later does not remove a remote copy."
        )
        TourFeature(
            symbol: "rectangle.dashed", title: "Permission on first capture",
            detail:
                "Recortia asks for Screen Recording permission the first time you capture, not now. Opening and editing images never needs it."
        )
    }
}

private struct CaptureTourStep: View {
    var body: some View {
        TourHeading(title: "Start with a capture")
        TourFeature(
            symbol: "viewfinder", title: "Region, display or window",
            detail:
                "Drag a region, or press Space to pick a window. Return captures the whole display; Escape cancels."
        )
        TourFeature(
            symbol: "timer", title: "Delay and repeat",
            detail:
                "Capture with Delay catches menus and temporary states. Repeat Last Region captures the same area again."
        )
        TourFeature(
            symbol: "arrow.down.to.line", title: "Long pages and existing images",
            detail:
                "Scrolling Capture joins frames while you scroll. Open, paste or drop a PNG or JPEG to edit it without Screen Recording permission."
        )
    }
}

private struct EditingTourStep: View {
    var body: some View {
        TourHeading(title: "Make the point clear")
        TourFeature(
            symbol: "pencil.tip", title: "Annotate and adjust",
            detail:
                "Add text, arrows, shapes, highlights and numbered steps. The inspector shows the options for what you selected."
        )
        TourFeature(
            symbol: "crop", title: "Crop, resize and navigate",
            detail: "Crop to the relevant area and resize the output. Hold Space and drag to pan."
        )
        TourFeature(
            symbol: "lock.shield", title: "Redact with solid masks",
            detail: "Redact replaces the covered pixels in every export. Blur and Pixelate are cosmetic, not secure."
        )
        TourFeature(
            symbol: "square.on.square", title: "Multiple images on one canvas",
            detail: "Add images, then move, resize, reorder or place them side by side."
        )
        TourFeature(
            symbol: "photo.artframe", title: "Framing and emphasis",
            detail:
                "Add a background, padding, rounded corners and a shadow. Spotlight and Magnifier draw attention to a detail."
        )
    }
}

private struct SharingTourStep: View {
    var body: some View {
        TourHeading(title: "Read, pin and share")
        TourFeature(
            symbol: "text.viewfinder", title: "Text recognition and QR codes",
            detail:
                "Capture Text (OCR) recognizes text in a region, and the editor recognizes it in an open image. QR contents are untrusted; only http and https links open, after your click."
        )
        TourFeature(
            symbol: "eyedropper", title: "Loupe and color picker",
            detail: "Inspect exact pixels and copy a color as HEX or RGB, from one pixel or an averaged area."
        )
        TourFeature(
            symbol: "ruler", title: "Measure without guessing",
            detail: "The ruler measures in image pixels and, for captures, in points."
        )
        TourFeature(
            symbol: "pin", title: "Reference pins",
            detail: "Pin an image to keep it in its own window on every Space. Up to five pins."
        )
        TourFeature(
            symbol: "square.and.arrow.up", title: "Copy, Save or Drag Out",
            detail:
                "All three share the same sanitized image, without hidden layers or location and text metadata."
        )
    }
}

private struct ShortcutsStep: View {
    let shortcutStatus: ShortcutStatusModel

    var body: some View {
        TourHeading(title: "Assign shortcuts")
        Form {
            if shortcutStatus.isHoldingAny {
                Section {
                    MacOSShortcutsNotice()
                }
            }
            Section {
                ForEach(ShortcutBinding.all.prefix(4)) { binding in
                    ShortcutRecorderRow(binding: binding, status: shortcutStatus)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

final class OnboardingWindowController {
    static let defaultContentSize = NSSize(width: 580, height: 615)
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }

    func show(onboarding: OnboardingModel, shortcutStatus: ShortcutStatusModel) {
        if let window { return AppPresence.shared.present(window) }
        let window = Self.makeWindow(onboarding: onboarding, shortcutStatus: shortcutStatus) { [weak self] in
            self?.close()
        }
        window.center(on: ScreenChoice.screen())
        self.window = window
        AppPresence.shared.present(window)
    }

    private func close() {
        window?.close()
        window = nil
    }

    /// Opens at a fixed default size at which no page scrolls in English or Portuguese, including
    /// the shortcuts page while macOS holds the defaults (`onboarding` checks every page). Nothing
    /// is measured at open, which kept the first frame over its budget; larger text or a smaller
    /// window scrolls.
    static func makeWindow(
        onboarding: OnboardingModel, shortcutStatus: ShortcutStatusModel, onClose: @escaping () -> Void
    ) -> NSWindow {
        let view = OnboardingView(onboarding: onboarding, shortcutStatus: shortcutStatus, onClose: onClose)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "Welcome to Recortia")
        window.identifier = NSUserInterfaceItemIdentifier("recortia.onboarding")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(defaultContentSize)
        window.contentMinSize = NSSize(width: 540, height: 480)
        window.isReleasedWhenClosed = false
        SpacePolicy.follow(window)
        return window
    }
}

#if DEBUG
    #Preview("Onboarding, local processing") {
        OnboardingView(
            onboarding: OnboardingModel(settings: PreviewSupport.settings()),
            shortcutStatus: PreviewSupport.shortcutStatus(), onClose: {})
    }

    #Preview("Onboarding, shortcuts") {
        let onboarding = OnboardingModel(settings: PreviewSupport.settings())
        for _ in 1..<OnboardingModel.pageCount { onboarding.next() }
        return OnboardingView(onboarding: onboarding, shortcutStatus: PreviewSupport.shortcutStatus(), onClose: {})
    }
#endif
