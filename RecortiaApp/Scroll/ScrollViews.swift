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
    var direction: ScrollCaptureDirection = .vertical
    var notice: ScrollSessionModel.Notice?
    /// Manual mode: the page stopped moving and may have ended.
    var pageEndLikely = false
    var acceptedFrames: Int
    /// The stitch's length along `direction`: its height, or its width.
    var outputLength: Int
}

struct ScrollHUDView: View {
    let hud: ScrollHUDState
    var onChooseDirection: (ScrollCaptureDirection) -> Void = { _ in }
    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            Text("Scrolling Capture")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(hud.source)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(statusText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if hud.state == .armed {
                Picker(
                    "Direction",
                    selection: Binding(get: { hud.direction }, set: { onChooseDirection($0) })
                ) {
                    Text("Vertical").tag(ScrollCaptureDirection.vertical)
                    Text("Horizontal").tag(ScrollCaptureDirection.horizontal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("scroll.hud.direction")
            }
            if hud.pageEndLikely, hud.state == .collecting {
                Label {
                    Text("The page stopped moving. If you reached the end, press Stop.")
                } icon: {
                    Image(systemName: "arrow.down.to.line").accessibilityHidden(true)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .noticeStyle()
            }
            if let noticeText {
                Label {
                    Text(noticeText)
                } icon: {
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .noticeStyle()
            }
            Text(progressText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("scroll.hud.progress")
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                switch hud.state {
                case .armed:
                    Button("Start", action: onStart)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .collecting:
                    Button("Pause", action: onPause)
                    Button("Stop", action: onStop)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .paused:
                    Button("Resume", action: onResume)
                    Button("Stop", action: onStop)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                default:
                    EmptyView()
                }
            }
        }
        .padding(DesignTokens.Space.m)
        .frame(width: 340)
    }

    private var progressText: String {
        hud.direction == .horizontal
            ? String(localized: "\(hud.acceptedFrames) frames · \(hud.outputLength) pixels wide")
            : String(localized: "\(hud.acceptedFrames) frames · \(hud.outputLength) pixels tall")
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
                hud.direction == .horizontal
                    ? String(localized: "Paused: scrolling changed direction. Scroll right again, then resume.")
                    : String(localized: "Paused: scrolling changed direction. Scroll down again, then resume.")
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
                    "Automatic scrolling needs Accessibility permission. Scroll manually, or allow it in Settings › Capture."
            )
        case .accessibilityRevoked:
            String(localized: "Accessibility permission was turned off. Continue scrolling manually.")
        case .screenPermissionDenied, .assemblyFailed, nil:
            nil
        }
    }
}

struct ScrollReviewView: View {
    let preview: CGImage?
    let outputSize: PixelSize
    var direction: ScrollCaptureDirection = .vertical
    /// Output rows where frames join, or columns for a horizontal capture.
    let seams: [Int]
    let partialReason: ScrollPartialReason?
    /// The model's notice: the stitch cannot be assembled (or drawn) within its budget.
    let assemblyFailed: Bool
    /// The model's rules (`ScrollSessionModel`), passed through unchanged.
    let isPreparingPreview: Bool
    let canAccept: Bool
    let canDiscard: Bool
    let onAccept: () -> Void
    let onDiscard: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private let previewWidth = 360.0
    /// The scroll view's height; a wide capture is drawn this tall, minus room for a scroller.
    private let previewViewportHeight = 360.0
    static let horizontalPreviewHeight = 340.0

    var body: some View {
        // The window's title says what this is; a complete result needs no status line.
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            if let partialReason {
                Label {
                    Text("Partial result. \(Self.describe(partialReason))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .noticeStyle()
            }
            Text("\(outputSize.width) × \(outputSize.height) pixels")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            // Vertical: fit to the width and scroll down. Horizontal: fit to the height and scroll
            // sideways, so a wide capture stays readable instead of shrinking to a strip.
            ScrollView(direction == .horizontal ? .horizontal : .vertical) {
                if let preview {
                    let size = displaySize(of: preview)
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) {
                            seamMarkers(size: size)
                        }
                        .accessibilityElement()
                        .accessibilityLabel(Text("Stitched preview with \(seams.count) joins"))
                        .accessibilityHint(
                            Text(
                                "Dashed lines mark where frames were joined. Check them for missing or repeated content."
                            )
                        )
                        .accessibilityIdentifier("scroll.review.preview")
                } else if isPreparingPreview {
                    ProgressView()
                        .frame(width: previewWidth, height: 200)
                        .accessibilityLabel(Text("Preparing preview"))
                }
            }
            .frame(width: previewWidth, height: previewViewportHeight)
            if assemblyFailed {
                Label {
                    Text(
                        direction == .horizontal
                            ? LocalizedStringKey(
                                "The image is too large to assemble. Discard it and capture a narrower area.")
                            : LocalizedStringKey(
                                "The image is too large to assemble. Discard it and capture a shorter area."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .noticeStyle()
            }
            HStack {
                Button("Discard", role: .destructive, action: onDiscard)
                    .keyboardShortcut(.cancelAction)
                    .disabled(!canDiscard)
                    .accessibilityIdentifier("scroll.review.discard")
                Spacer()
                Button(
                    partialReason == nil ? LocalizedStringKey("Accept") : LocalizedStringKey("Accept Partial Result"),
                    action: onAccept
                )
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAccept)
                .accessibilityIdentifier("scroll.review.accept")
            }
        }
        .padding(DesignTokens.Space.l)
        .frame(width: previewWidth + 2 * DesignTokens.Space.l)
    }

    private func displaySize(of preview: CGImage) -> CGSize {
        let aspect = Double(preview.width) / Double(max(preview.height, 1))
        return direction == .horizontal
            ? CGSize(width: Self.horizontalPreviewHeight * aspect, height: Self.horizontalPreviewHeight)
            : CGSize(width: previewWidth, height: previewWidth / aspect)
    }

    private func seamMarkers(size: CGSize) -> some View {
        let horizontal = direction == .horizontal
        let length = Double(horizontal ? outputSize.width : outputSize.height)
        let scale = length > 0 ? Double(horizontal ? size.width : size.height) / length : 0
        let width: Double = contrast == .increased ? 2 : 1
        return ZStack(alignment: .topLeading) {
            ForEach(seams, id: \.self) { seam in
                let position = Double(seam) * scale
                // A seam crosses the whole preview: a horizontal line in a vertical capture, a
                // vertical one in a horizontal capture.
                let mark = Path { path in
                    path.move(to: horizontal ? CGPoint(x: position, y: 0) : CGPoint(x: 0, y: position))
                    path.addLine(
                        to: horizontal ? CGPoint(x: position, y: size.height) : CGPoint(x: size.width, y: position))
                }
                // Over arbitrary page pixels one colour disappears: primary is black in light
                // appearance, so the marks vanish on the dark pages people scroll most. A keyline
                // (opaque white under-stroke, black core) reads over any page colour, keeps working
                // for every accent colour, and carries its contrast in shape rather than in hue.
                mark.stroke(Color.white, style: StrokeStyle(lineWidth: width + 2, dash: [6, 4]))
                mark.stroke(Color.black, style: StrokeStyle(lineWidth: width, dash: [6, 4]))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    static func describe(_ reason: ScrollPartialReason) -> String {
        switch reason {
        case .limit(.duration): String(localized: "The 2-minute time limit was reached.")
        case .limit(.frames): String(localized: "The 200-frame limit was reached.")
        case .limit(.area): String(localized: "The 40-megapixel size limit was reached.")
        case .limit(.side): String(localized: "The 32,768-pixel side limit was reached.")
        case .limit(.height): String(localized: "The 20,000-pixel height limit was reached.")
        case .limit(.width): String(localized: "The 20,000-pixel width limit was reached.")
        case .limit(.memory): String(localized: "The memory limit for scrolling capture was reached.")
        case .ambiguous: String(localized: "Capture stopped where content could not be matched reliably.")
        case .stoppedMoving:
            String(
                localized: "Scrolling stopped when the page stopped moving; content that loads later may be missing.")
        }
    }
}

#if DEBUG
    #Preview("HUD, collecting") {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: "Area on Built-in Display", state: .collecting, mode: .manual, notice: nil, acceptedFrames: 12,
                outputLength: 5_400),
            onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {})
    }

    #Preview("HUD, page end likely") {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: "Area on Built-in Display", state: .collecting, mode: .manual, notice: nil,
                pageEndLikely: true, acceptedFrames: 18, outputLength: 7_800),
            onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {})
    }

    #Preview("HUD, paused ambiguous") {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: "Area on Built-in Display", state: .paused(.ambiguousMatch), mode: .manual,
                notice: .automaticNeedsAccessibility, acceptedFrames: 4, outputLength: 1_900),
            onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {})
    }

    #Preview("HUD, armed horizontal") {
        ScrollHUDView(
            hud: ScrollHUDState(
                source: "Area on Built-in Display", state: .armed, mode: .manual, direction: .horizontal,
                notice: nil, acceptedFrames: 0, outputLength: 0),
            onStart: {}, onPause: {}, onResume: {}, onStop: {}, onCancel: {})
    }

    #Preview("Review, horizontal") {
        ScrollReviewView(
            preview: PreviewSupport.image(width: 1_200, height: 300), outputSize: PixelSize(width: 2_400, height: 600),
            direction: .horizontal, seams: [600, 1_200, 1_800], partialReason: nil, assemblyFailed: false,
            isPreparingPreview: false, canAccept: true, canDiscard: true, onAccept: {}, onDiscard: {})
    }

    #Preview("Review, partial") {
        ScrollReviewView(
            preview: PreviewSupport.image(width: 400, height: 1_200), outputSize: PixelSize(width: 800, height: 2_400),
            seams: [600, 1_200, 1_800], partialReason: .limit(.height), assemblyFailed: false,
            isPreparingPreview: false, canAccept: true, canDiscard: true, onAccept: {}, onDiscard: {})
    }
#endif
