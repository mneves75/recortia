import AppKit
import Features
import SwiftUI

/// First-launch window (FR-01): local processing, optional shortcut assignment, done.
/// It requests no permission; Screen Recording is asked for on the first capture.
struct OnboardingView: View {
    let onboarding: OnboardingModel
    let shortcutStatus: ShortcutStatusModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch onboarding.step {
            case .localProcessing:
                LocalProcessingStep()
            case .shortcuts, .done:
                ShortcutsStep(shortcutStatus: shortcutStatus)
            }
            Spacer(minLength: 0)
            HStack {
                if onboarding.step == .localProcessing {
                    Button("Skip") {
                        onboarding.finish()
                        onClose()
                    }
                }
                Spacer()
                if onboarding.canGoBack {
                    Button("Back") { onboarding.back() }
                }
                if onboarding.step == .localProcessing {
                    Button("Continue") { onboarding.next() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        onboarding.finish()
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 460)
    }
}

private struct LocalProcessingStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Framepin")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Capture, mark up, redact, and share screenshots from the menu bar.")
                .font(.title3)
            Label {
                Text(
                    "Everything happens on this Mac. Screenshots and recognized text stay in memory and are never uploaded."
                )
            } icon: {
                Image(systemName: "lock.laptopcomputer").frame(width: 24).accessibilityHidden(true)
            }
            Label {
                Text("Nothing is saved or copied until you choose Copy, Save, or drag an image out.")
            } icon: {
                Image(systemName: "hand.raised").frame(width: 24).accessibilityHidden(true)
            }
            Label {
                Text(
                    "Framepin asks for Screen Recording permission the first time you capture, not now. Opening and editing images never needs it."
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
                "Optional. Framepin sets no shortcuts for you and never replaces the macOS screenshot shortcuts. You can change them later in Settings."
            )
            .fixedSize(horizontal: false, vertical: true)
            Form {
                ForEach(ShortcutBinding.all.prefix(4)) { binding in
                    ShortcutRecorderRow(binding: binding, status: shortcutStatus)
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

    func show(onboarding: OnboardingModel, shortcutStatus: ShortcutStatusModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = OnboardingView(onboarding: onboarding, shortcutStatus: shortcutStatus) { [weak self] in
            self?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "Welcome to Framepin")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
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
        onboarding.next()
        return OnboardingView(onboarding: onboarding, shortcutStatus: PreviewSupport.shortcutStatus(), onClose: {})
    }
#endif
