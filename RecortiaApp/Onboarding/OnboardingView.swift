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
                    // Showing the shortcuts is attention to them; measuring that page is not.
                    .onAppear {
                        if onboarding.step == .shortcuts || onboarding.step == .done {
                            shortcutStatus.noteUserAttention()
                        }
                    }
            }
            .id(onboarding.step)
            Divider()
            OnboardingNavigation(onboarding: onboarding, onClose: onClose)
                .padding(20)
        }
        .frame(minWidth: 540, minHeight: 480)
    }

    /// The window content height at which the tallest page needs no scrolling at `width`, in the
    /// running language and current shortcut state: every page and the navigation, at their ideal
    /// heights, as the scroll view lays them out.
    static func fittingHeight(width: CGFloat, onboarding: OnboardingModel, shortcutStatus: ShortcutStatusModel)
        -> CGFloat
    {
        // One hosting view and one layout pass: a stack of every page is as tall as the tallest.
        let pages = ZStack(alignment: .top) {
            ForEach(OnboardingModel.Step.allCases.filter { $0 != .done }, id: \.self) { step in
                TourPage(step: step, shortcutStatus: shortcutStatus)
            }
        }
        let content = VStack(spacing: 0) {
            pages
            Divider()
            OnboardingNavigation(onboarding: onboarding, onClose: {}).padding(20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width)
        return NSHostingView(rootView: content).fittingSize.height
    }
}

/// One page's content, laid out as the tour's scroll view shows it.
private struct TourPage: View {
    let step: OnboardingModel.Step
    let shortcutStatus: ShortcutStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch step {
            case .localProcessing: LocalProcessingStep()
            case .capture: CaptureTourStep()
            case .editing: EditingTourStep()
            case .recognition: RecognitionTourStep()
            case .composition: CompositionTourStep()
            case .sharing: SharingTourStep()
            case .shortcuts, .done: ShortcutsStep(shortcutStatus: shortcutStatus)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tour.page")
    }
}

private struct OnboardingNavigation: View {
    let onboarding: OnboardingModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Step \(onboarding.pageNumber) of \(OnboardingModel.pageCount)",
                comment: "Tour progress: the first placeholder is the current page; the second is the total page count."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("tour.progress")
            HStack {
                Button("Skip") {
                    onboarding.finish()
                    onClose()
                }
                .accessibilityIdentifier("tour.skip")
                Spacer()
                if onboarding.canGoBack {
                    Button("Back") { onboarding.back() }
                        .accessibilityIdentifier("tour.back")
                }
                if onboarding.step == .shortcuts || onboarding.step == .done {
                    Button("Done") {
                        onboarding.finish()
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tour.done")
                } else {
                    Button("Continue") { onboarding.next() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("tour.next")
                }
            }
        }
    }
}

private struct TourFeature: View {
    let symbol: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TourHeading: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.largeTitle).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
    }
}

private struct CaptureTourStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TourHeading(
                title: "Start with a capture", subtitle: "Choose a capture mode from the Recortia menu-bar icon.")
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
}

private struct EditingTourStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TourHeading(
                title: "Make the point clear",
                subtitle: "Annotations stay editable; exports are flattened images.")
            TourFeature(
                symbol: "pencil.tip", title: "Annotate and adjust",
                detail:
                    "Add text, arrows, shapes, highlights and numbered steps. The inspector shows the options for what you selected."
            )
            TourFeature(
                symbol: "crop", title: "Crop, resize and navigate",
                detail:
                    "Crop to the relevant area and resize the output. Hold Space and drag to pan."
            )
            TourFeature(
                symbol: "lock.shield", title: "Redact with solid masks",
                detail:
                    "Redact replaces the covered pixels in every export. Blur and Pixelate are cosmetic, not secure."
            )
        }
    }
}

private struct RecognitionTourStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TourHeading(
                title: "Read text and inspect pixels", subtitle: "Recognition and pixel inspection run on this Mac.")
            TourFeature(
                symbol: "text.viewfinder", title: "Text recognition and QR codes",
                detail:
                    "Capture Text (OCR) recognizes text in a region, and the editor recognizes it in an open image. QR contents are untrusted; only http and https links open, after your click."
            )
            TourFeature(
                symbol: "eyedropper", title: "Loupe and color picker",
                detail:
                    "Inspect exact pixels and copy a color as HEX or RGB, from one pixel or an averaged area."
            )
            TourFeature(
                symbol: "ruler", title: "Measure without guessing",
                detail:
                    "The ruler measures in image pixels and, for captures, in points."
            )
        }
    }
}

private struct CompositionTourStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TourHeading(
                title: "Compose and keep references",
                subtitle: "Arrange images and add emphasis without leaving the editor.")
            TourFeature(
                symbol: "square.on.square", title: "Multiple images on one canvas",
                detail:
                    "Add images, then move, resize, reorder or place them side by side."
            )
            TourFeature(
                symbol: "photo.artframe", title: "Framing and emphasis",
                detail:
                    "Add a background, padding, rounded corners and a shadow. Spotlight and Magnifier draw attention to a detail."
            )
            TourFeature(
                symbol: "pin", title: "Reference pins",
                detail:
                    "Pin an image to keep it in its own window on every Space. Up to five pins."
            )
        }
    }
}

private struct SharingTourStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TourHeading(
                title: "Choose what leaves the editor", subtitle: "Sharing uses a flattened, freshly encoded image.")
            TourFeature(
                symbol: "square.and.arrow.up", title: "Copy, Save or Drag Out",
                detail:
                    "All three share the same sanitized image, without hidden layers or location and text metadata."
            )
            TourFeature(
                symbol: "gearshape", title: "Automatic exports are optional",
                detail:
                    "Automatic copy and save run right after a capture, before any redaction. Turn them off before capturing sensitive content."
            )
            TourFeature(
                symbol: "network", title: "Optional GitHub sharing",
                detail:
                    "Uploads leave this Mac and are off by default. Redacting or deleting later does not remove a remote copy."
            )
            Text("Reopen this tour from Feature Tour in the menu bar.")
                .font(.subheadline)
        }
    }
}

private struct LocalProcessingStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Recortia")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Capture, mark up, redact, and share screenshots from the menu bar.")
                .font(.title3)
            Label {
                Text(
                    "Capture, editing and recognition stay on this Mac. Optional GitHub upload runs only when you enable it."
                )
            } icon: {
                Image(systemName: "lock.laptopcomputer").frame(width: 24).accessibilityHidden(true)
            }
            Label {
                Text(
                    "Automatic copy, save and upload are off on a fresh install. You decide whether to enable them in Settings."
                )
            } icon: {
                Image(systemName: "hand.raised").frame(width: 24).accessibilityHidden(true)
            }
            Label {
                Text(
                    "Recortia asks for Screen Recording permission the first time you capture, not now. Opening and editing images never needs it."
                )
            } icon: {
                Image(systemName: "rectangle.dashed").frame(width: 24).accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutsStep: View {
    let shortcutStatus: ShortcutStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign shortcuts")
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Recortia's default shortcuts are the macOS screenshot ones: ⇧⌘3 for the display, ⇧⌘4 for a region and ⇧⌘5 for every capture mode. Change or clear them here, or later in Settings."
            )
            .fixedSize(horizontal: false, vertical: true)
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
}

/// Hosts the onboarding view in a standard titled window.
final class OnboardingWindowController {
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }

    func show(onboarding: OnboardingModel, shortcutStatus: ShortcutStatusModel) {
        if let window {
            AppPresence.shared.windowWillAppear()
            window.makeKeyAndOrderFront(nil)
            AppPresence.shared.activate()
            return
        }
        let window = Self.makeWindow(onboarding: onboarding, shortcutStatus: shortcutStatus) { [weak self] in
            self?.close()
        }
        window.center(on: ScreenChoice.screen())
        self.window = window
        AppPresence.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }

    /// Opens at the default width and at the height of the tallest page, so no page scrolls and
    /// none leaves most of the window empty; larger text or a smaller window scrolls.
    static func makeWindow(
        onboarding: OnboardingModel, shortcutStatus: ShortcutStatusModel, onClose: @escaping () -> Void
    ) -> NSWindow {
        let view = OnboardingView(onboarding: onboarding, shortcutStatus: shortcutStatus, onClose: onClose)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "Welcome to Recortia")
        window.identifier = NSUserInterfaceItemIdentifier("recortia.onboarding")
        window.styleMask = [.titled, .closable, .resizable]
        let width: CGFloat = 580
        let fitting = OnboardingView.fittingHeight(width: width, onboarding: onboarding, shortcutStatus: shortcutStatus)
        let screen = ScreenChoice.screen()?.visibleFrame.height ?? .infinity
        let titleBar = window.frame.height - window.contentLayoutRect.height
        window.setContentSize(NSSize(width: width, height: min(fitting.rounded(.up), screen - titleBar)))
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
        for _ in 0..<6 { onboarding.next() }
        return OnboardingView(onboarding: onboarding, shortcutStatus: PreviewSupport.shortcutStatus(), onClose: {})
    }
#endif
