import Features
import KeyboardShortcuts
import SwiftUI

/// A recorder for one global shortcut. KeyboardShortcuts reports detected menu and system
/// conflicts itself; this row adds Framepin's registration check.
struct ShortcutRecorderRow: View {
    let binding: ShortcutBinding
    let status: ShortcutStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            KeyboardShortcuts.Recorder(
                for: binding.name,
                onChange: { shortcut in
                    status.shortcutChanged(named: binding.name.rawValue, isAssigned: shortcut != nil)
                },
                label: { Text(binding.title) })
            if status.hasFailed(binding.name.rawValue) {
                Label {
                    Text("macOS did not accept this shortcut. Another app may be using it. Choose a different one.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
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
