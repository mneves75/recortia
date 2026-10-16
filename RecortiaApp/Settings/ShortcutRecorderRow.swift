import AppKit
import Features
import KeyboardShortcuts
import SwiftUI

/// A recorder for one global shortcut. KeyboardShortcuts reports detected menu and system
/// conflicts while recording; this row adds whether the shortcut works: held while macOS uses the
/// same keys (ADR-005), or refused by the system.
struct ShortcutRecorderRow: View {
    let binding: ShortcutBinding
    let status: ShortcutStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            KeyboardShortcuts.Recorder(
                shortcut: Binding(
                    get: { KeyboardShortcuts.getShortcut(for: binding.name) },
                    set: { shortcut in
                        status.reassign { KeyboardShortcuts.setShortcut(shortcut, for: binding.name) }
                    }),
                label: { Text(binding.title) }
            )
            .id(status.assignmentRevision)
            switch status.state(of: binding.name.rawValue) {
            case .heldBySystem:
                note(
                    Text("macOS is using this shortcut."),
                    icon: "info.circle")
            case .failed:
                note(
                    Text("macOS did not accept this shortcut. Another app may be using it. Choose a different one."),
                    icon: "exclamationmark.triangle")
            case .active, .unassigned:
                EmptyView()
            }
        }
    }

    private func note(_ text: Text, icon: String) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: icon)
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// For callers to show while macOS still uses some default shortcuts: Recortia never turns
/// Apple's shortcuts off itself, so it says where to do it and opens System Settings › Keyboard
/// (ADR-005).
struct MacOSShortcutsNotice: View {
    /// System Settings › Keyboard; the Keyboard Shortcuts sheet has no public URL of its own.
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "macOS is still using some of these shortcuts. Turn them off in System Settings › Keyboard › Keyboard Shortcuts › Screenshots, and Recortia starts using them. Recortia never changes them itself."
            )
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Keyboard Settings…") {
                if let url = Self.keyboardSettingsURL { NSWorkspace.shared.open(url) }
            }
        }
    }
}

#if DEBUG
    #Preview("Shortcut row, failed") {
        Form {
            ShortcutRecorderRow(
                binding: ShortcutBinding.all[0],
                status: PreviewSupport.shortcutStatus(failing: [ShortcutBinding.all[0].name.rawValue]))
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
#endif
