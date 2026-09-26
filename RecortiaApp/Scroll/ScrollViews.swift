import AppKit
import Domain
import Features
import MacPlatform
import SwiftUI

/// Values the scrolling HUD shows; built from `ScrollSessionModel` so previews need no services.
struct ScrollHUDState: Equatable {
    var source: String
    var state: ScrollState
    var mode: ScrollMode
    var notice: ScrollSessionModel.Notice?
    /// Manual mode: the page stopped moving and may have ended.
    var pageEndLikely = false
    var acceptedFrames: Int
    var outputHeight: Int
}

/// Session HUD (FR-10): source, status, progress, and Start/Pause/Resume/Stop/Cancel.
struct ScrollHUDView: View {
    let hud: ScrollHUDState
    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scrolling Capture")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(hud.source)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(statusText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if hud.pageEndLikely, hud.state == .collecting {
                Label {
                    Text("The page stopped moving. If you reached the end, press Stop.")
                } icon: {
                    Image(systemName: "arrow.down.to.line").accessibilityHidden(true)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let noticeText {
                Label {
                    Text(noticeText)
                } icon: {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(hud.acceptedFrames) frames · \(hud.outputHeight) pixels tall")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                switch hud.state {
                case .armed:
                    Button("Start", action: onStart)
                        .keyboardShortcut(.defaultAction)
                case .collecting:
                    Button("Pause", action: onPause)
                    Button("Stop", action: onStop)
                        .keyboardShortcut(.defaultAction)
                case .paused:
                    Button("Resume", action: onResume)
                    Button("Stop", action: onStop)
                        .keyboardShortcut(.defaultAction)
                default:
                    EmptyView()
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var statusText: String {
        switch hud.state {
        case .armed:
            hud.mode == .automatic
                ? String(localized: "Ready. Press Start and Recortia scrolls the area for you.")
                : String(localized: "Ready. Press Start, then scroll the area slowly.")
        case .collecting:
            hud.mode == .automatic
                ? String(localized: "Capturing. Recortia is scrolling the area.")
                : String(localized: "Capturing. Scroll the area slowly.")
        case .paused(let reason):
            switch reason {
            case .userPaused: String(localized: "Paused.")
            case .ambiguousMatch:
                String(
                    localized:
                        "Paused: the new content could not be matched reliably. Scroll back a little, then resume, or stop to review."
                )
            case .reversedDirection:
                String(localized: "Paused: scrolling changed direction. Scroll down again, then resume.")
            case .lowConfidence:
                String(localized: "Paused: the match is uncertain. Resume to keep going or stop to review.")
            }
        default:
            ""
        }
    }

    private var noticeText: String? {
        switch hud.notice {
        case .automaticNeedsAccessibility:
            String(
                localized:
                    "Automatic scrolling needs Accessibility permission. Scroll manually, or allow it in Settings › Scrolling."
            )
        case .accessibilityRevoked:
            String(localized: "Accessibility permission was turned off. Continue scrolling manually.")
        case .screenPermissionDenied, .assemblyFailed, nil:
            nil
        }
    }
}

/// Review window: stitched preview with seam markers, then Accept or Discard (SCR-02).
struct ScrollReviewView: View {
    let preview: CGImage?
    let outputSize: PixelSize
    let seams: [Int]
    let partialReason: ScrollPartialReason?
    let assemblyFailed: Bool
    let onAccept: () -> Void
    let onDiscard: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private let previewWidth = 360.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Scrolling Capture")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let partialReason {
                Label {
                    Text("Partial result. \(Self.describe(partialReason))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Complete capture.")
            }
            Text("\(outputSize.width) × \(outputSize.height) pixels")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            ScrollView {
                if let preview {
                    let displayHeight = previewWidth * Double(preview.height) / Double(max(preview.width, 1))
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: previewWidth, height: displayHeight)
                        .overlay(alignment: .topLeading) {
                            seamMarkers(displayHeight: displayHeight)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(Text("Stitched preview with \(seams.count) joins"))
                } else {
                    ProgressView()
                        .frame(width: previewWidth, height: 200)
                        .accessibilityLabel(Text("Preparing preview"))
                }
            }
            .frame(height: 360)
            Text("Dashed lines mark where frames were joined. Check them for missing or repeated content.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if assemblyFailed {
                Text("The image is too large to assemble. Discard it and capture a shorter area.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Discard", role: .destructive, action: onDiscard)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(
                    partialReason == nil ? LocalizedStringKey("Accept") : LocalizedStringKey("Accept Partial Result"),
                    action: onAccept
                )
                .keyboardShortcut(.defaultAction)
                .disabled(assemblyFailed)
            }
        }
        .padding(16)
        .frame(width: previewWidth + 32)
    }

    private func seamMarkers(displayHeight: Double) -> some View {
        let scale = outputSize.height > 0 ? displayHeight / Double(outputSize.height) : 0
        return ZStack(alignment: .topLeading) {
            ForEach(seams, id: \.self) { seam in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: Double(seam) * scale))
                    path.addLine(to: CGPoint(x: previewWidth, y: Double(seam) * scale))
                }
                .stroke(
                    Color.primary,
                    style: StrokeStyle(lineWidth: contrast == .increased ? 2 : 1, dash: [6, 4]))
            }
        }
        .frame(width: previewWidth, height: displayHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    static func describe(_ reason: ScrollPartialReason) -> String {
        switch reason {
        case .limit(.duration): String(localized: "The 2-minute time limit was reached.")
        case .limit(.frames): String(localized: "The 200-frame limit was reached.")
        case .limit(.area): String(localized: "The 40-megapixel size limit was reached.")
        case .limit(.side): String(localized: "The 32,768-pixel side limit was reached.")
        case .limit(.height): String(localized: "The 20,000-pixel height limit was reached.")
        case .ambiguous: String(localized: "Capture stopped where content could not be matched reliably.")
        }
    }
}

#if DEBUG
    #Preview("HUD, collecting") {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: "Area on Built-in Display", state: .collecting, mode: .manual, notice: nil, acceptedFrames: 12,
                outputHeight: 5_400),
            onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {})
    }

    #Preview("HUD, page end likely") {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: "Area on Built-in Display", state: .collecting, mode: .manual, notice: nil,
                pageEndLikely: true, acceptedFrames: 18, outputHeight: 7_800),
            onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {})
    }

    #Preview("HUD, paused ambiguous") {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: "Area on Built-in Display", state: .paused(.ambiguousMatch), mode: .manual,
                notice: .automaticNeedsAccessibility, acceptedFrames: 4, outputHeight: 1_900),
            onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {})
    }

    #Preview("Review, partial") {
        ScrollReviewView(
            preview: PreviewSupport.image(width: 400, height: 1_200), outputSize: PixelSize(width: 800, height: 2_400),
            seams: [600, 1_200, 1_800], partialReason: .limit(.height), assemblyFailed: false, onAccept: {},
            onDiscard: {})
    }
#endif
