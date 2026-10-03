import AppKit
import Features
import SwiftUI

/// First-launch window (FR-01): local processing, the default shortcuts, done.
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
        .frame(width: 520, height: 600)
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
                Text("Nothing is saved or copied until you choose Copy, Save, or drag an image out.")
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

    func show(onboarding: OnboardingModel, shortcutStatus: ShortcutStatusModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = OnboardingView(onboarding: onboarding, shortcutStatus: shortcutStatus) { [weak self] in
            self?.close()
        }
        let window = Self.makeWindow(NSHostingController(rootView: view))
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }

    static func makeWindow(_ content: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: content)
        window.title = String(localized: "Welcome to Recortia")
        window.styleMask = [.titled, .closable]
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
        onboarding.next()
        return OnboardingView(onboarding: onboarding, shortcutStatus: PreviewSupport.shortcutStatus(), onClose: {})
    }
#endif
