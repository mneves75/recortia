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
                VStack(alignment: .leading, spacing: 24) {
                    switch onboarding.step {
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
            }
            .id(onboarding.step)
            Divider()
            OnboardingNavigation(onboarding: onboarding, onClose: onClose)
                .padding(20)
        }
        .frame(minWidth: 540, minHeight: 480)
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
                    "Capture Region lets you drag an area; press Space to choose a window, Return to confirm, or Escape to cancel. Capture Display and Capture Window select the source directly. Recortia hides its own windows during capture."
            )
            TourFeature(
                symbol: "timer", title: "Delay and repeat",
                detail:
                    "Use Capture with Delay for menus or temporary states, then Repeat Last Region for the same area. Settings › Capture controls the delay, cursor and window shadow."
            )
            TourFeature(
                symbol: "arrow.down.to.line", title: "Long pages and existing images",
                detail:
                    "Scrolling Capture joins vertical frames while you scroll manually. Uncertain matches pause for review; automatic scrolling is optional and requests Accessibility only when enabled. Open Image, Paste Image or drop a PNG/JPEG to edit without Screen Recording permission."
            )
        }
    }
}

private struct EditingTourStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TourHeading(
                title: "Make the point clear",
                subtitle: "Annotations stay editable in the editor. Export creates a flattened image.")
            TourFeature(
                symbol: "pencil.tip", title: "Annotate and adjust",
                detail:
                    "Choose text, arrows, rectangles, ellipses, freehand, highlighter or numbered steps in the editor. Select an annotation to move, resize, duplicate or reorder it; Undo and Redo recover changes."
            )
            TourFeature(
                symbol: "crop", title: "Crop, resize and navigate",
                detail:
                    "Use Crop to keep the relevant area and Resize to change output dimensions. Zoom in for details and hold Space while dragging to pan the canvas."
            )
            TourFeature(
                symbol: "lock.shield", title: "Redact with solid masks",
                detail:
                    "Choose solid redaction and cover sensitive content before sharing. It replaces source pixels in exports. Blur and pixelate are cosmetic effects, not secure redaction. Review the final output before Copy, Save or Drag Out."
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
                    "Use Capture Text (OCR) from the menu, or recognize text in an open image. Choose text formatting in Settings › Text Recognition and copy the result. QR content is untrusted; only http/https links can open, after your click."
            )
            TourFeature(
                symbol: "eyedropper", title: "Loupe and color picker",
                detail:
                    "Select the pixel tools in the editor for a nearest-neighbor loupe. In Color Picker, choose 1×1 for one pixel or 3×3/5×5 to average a neighborhood. Copy encoded sRGB as HEX or RGB; zoom does not change the sampled pixels."
            )
            TourFeature(
                symbol: "ruler", title: "Measure without guessing",
                detail:
                    "Use the ruler to place measurement anchors. Dimensions distinguish image pixels from capture points; imported files have no invented screen scale."
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
                    "Add an image layer in the editor, then position, resize, reorder or adjust its opacity. Arrange images side by side to explain a comparison; secure masks remain attached to their source images."
            )
            TourFeature(
                symbol: "photo.artframe", title: "Presentation and emphasis",
                detail:
                    "Use the presentation inspector for solid or gradient backgrounds, padding, rounded corners and shadows. Spotlight and magnifier effects emphasize details using sanitized image content."
            )
            TourFeature(
                symbol: "pin", title: "Reference pins",
                detail:
                    "Pin an image from the editor to keep a reference in its own window. Adjust zoom and opacity, Copy or Drag Out, and close it when finished. Up to five pins join all Spaces and appear in window switchers; they are ordinary windows, not always-on-top overlays."
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
                    "Copy puts a sanitized PNG on the clipboard. Save writes PNG or JPEG atomically; Drag Out shares the same sanitized output. Exported files omit hidden layers and location or text metadata."
            )
            TourFeature(
                symbol: "gearshape", title: "Automatic exports are optional",
                detail:
                    "Settings › Export can enable automatic copy or save after capture. Disable automatic copy, save and upload before capturing sensitive content: they run before redaction. Later edits cannot recall earlier clipboard, file or remote copies. Redact first, then export deliberately."
            )
            TourFeature(
                symbol: "network", title: "Optional GitHub sharing",
                detail:
                    "Settings › GitHub requires your destination, credentials and separate opt-in. Uploads leave this Mac; automatic upload is off by default and sends the capture before later edits. Disable it before sensitive captures. Local deletion or later redaction does not delete a remote copy."
            )
            Text(
                "Settings also controls Open at login, recognition, pins and scrolling. You can reopen this introduction from Feature Tour in the menu bar."
            )
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
                "Recortia's default shortcuts are the macOS Screenshot ones: ⇧⌘3 for the display, ⇧⌘4 for a region (press Space for a window), and ⇧⌘5 for every capture mode. If another screenshot app already uses them, clear them here; you can change them later in Settings."
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
            .onAppear { shortcutStatus.noteUserAttention() }
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
        let view = OnboardingView(onboarding: onboarding, shortcutStatus: shortcutStatus) { [weak self] in
            self?.close()
        }
        let window = Self.makeWindow(NSHostingController(rootView: view))
        window.center(on: ScreenChoice.screen())
        self.window = window
        AppPresence.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }

    static func makeWindow(_ content: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: content)
        window.title = String(localized: "Welcome to Recortia")
        window.identifier = NSUserInterfaceItemIdentifier("recortia.onboarding")
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 580, height: 640))
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
