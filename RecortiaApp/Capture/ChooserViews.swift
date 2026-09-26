import AppKit
import Domain
import MacPlatform
import SwiftUI

/// Keyboard-navigable window chooser (FR-02). Window titles appear here only; they never reach
/// filenames or logs.
struct WindowChooserView: View {
    let windows: [WindowInfo]?
    let onChoose: (WindowInfo) -> Void
    let onCancel: () -> Void
    @State private var selection: WindowInfo.ID?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a window to capture")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let windows {
                if windows.isEmpty {
                    Text("No windows are available to capture.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(windows, selection: $selection) { window in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.ownerName)
                            if let title = window.title, !title.isEmpty {
                                Text(title)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .focused($listFocused)
                    .onAppear {
                        selection = windows.first?.id
                        listFocused = true
                    }
                }
            } else {
                ProgressView("Finding windows…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Capture") {
                    if let window = windows?.first(where: { $0.id == selection }) { onChoose(window) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 420, height: 360)
    }
}

/// Chooser shown when several displays are connected.
struct DisplayChooserView: View {
    let displays: [DisplayInfo]
    let onChoose: (DisplayInfo) -> Void
    let onCancel: () -> Void
    @State private var selection: DisplayInfo.ID?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a display to capture")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            List(displays, selection: $selection) { display in
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.localizedName)
                    Text("\(Int(display.frame.width)) × \(Int(display.frame.height)) points")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .focused($listFocused)
            .onAppear {
                selection = displays.first?.id
                listFocused = true
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Capture") {
                    if let display = displays.first(where: { $0.id == selection }) { onChoose(display) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 380, height: 300)
    }
}

/// Countdown for delayed capture. Shown in a non-activating panel so the app being captured
/// keeps focus; Recortia's own windows are excluded from the capture.
struct CountdownView: View {
    let remaining: Int
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 16) {
            Text("Capturing in \(remaining) s")
                .font(.title2.monospacedDigit())
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .accessibilityAddTraits(.updatesFrequently)
            Button("Cancel", action: onCancel)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#if DEBUG
    #Preview("Window chooser") {
        WindowChooserView(
            windows: [
                WindowInfo(
                    id: 1, ownerName: "Preview App", ownerPID: 1, title: "Untitled document",
                    frame: Rect(x: 0, y: 0, width: 800, height: 600), displayID: 1),
                WindowInfo(
                    id: 2, ownerName: "Another App", ownerPID: 2, title: nil,
                    frame: Rect(x: 0, y: 0, width: 400, height: 300), displayID: 1),
            ], onChoose: { _ in }, onCancel: {})
    }

    #Preview("Window chooser, loading") {
        WindowChooserView(windows: nil, onChoose: { _ in }, onCancel: {})
    }

    #Preview("Display chooser") {
        DisplayChooserView(
            displays: [
                DisplayInfo(
                    id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), pointPixelScale: 2, fingerprint: "a"),
                DisplayInfo(
                    id: 2, frame: Rect(x: -1920, y: 0, width: 1920, height: 1080), pointPixelScale: 1, fingerprint: "b"),
            ], onChoose: { _ in }, onCancel: {})
    }

    #Preview("Countdown") {
        CountdownView(remaining: 3, onCancel: {})
    }
#endif
