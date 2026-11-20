import os

/// Latency intervals for Instruments' os_signpost instrument and `xctrace` (FR-14, A-13 step 1),
/// subsystem `dev.mvneves.Recortia`, category `latency`. They carry durations only, never content,
/// and claim no measurement by themselves: numbers come from recorded traces. Every interval is
/// owned by the request or window it times, so a stale request can close only its own.
@MainActor
public enum LatencySignposts {
    public enum Interval: CaseIterable, Hashable, Sendable {
        /// A capture's start (a shortcut or menu command runs it at once) to its region overlay or
        /// chooser on screen.
        case startToOverlay
        /// The capture call, after the selection and any countdown, to its returned image.
        case selectionToCapture
        /// A completed capture handed to the shell to its editor window ordered on screen.
        case captureToEditor
        /// A newly shown editor window to its canvas's first successful draw of the image.
        case editorToFirstDraw

        fileprivate var name: StaticString {
            switch self {
            case .startToOverlay: "Capture start to overlay"
            case .selectionToCapture: "Selection to capture"
            case .captureToEditor: "Capture to editor window"
            case .editorToFirstDraw: "Editor to first canvas draw"
            }
        }
    }

    fileprivate static let signposter = OSSignposter(subsystem: "dev.mvneves.Recortia", category: "latency")

    public static func begin(_ kind: Interval) -> LatencyInterval {
        LatencyInterval(kind: kind, state: signposter.beginInterval(kind.name, id: signposter.makeSignpostID()))
    }
}

/// One open latency interval. Ending it a second time does nothing.
@MainActor
public final class LatencyInterval {
    public let kind: LatencySignposts.Interval
    public private(set) var isOpen = true
    private let state: OSSignpostIntervalState

    fileprivate init(kind: LatencySignposts.Interval, state: OSSignpostIntervalState) {
        self.kind = kind
        self.state = state
    }

    /// The interval reached its end point.
    public func end() {
        guard isOpen else { return }
        isOpen = false
        LatencySignposts.signposter.endInterval(kind.name, state)
    }

    /// The interval stopped without reaching its end point (no overlay was shown, the request was
    /// canceled); marked so a trace can leave it out of medians.
    public func abandon() {
        guard isOpen else { return }
        isOpen = false
        LatencySignposts.signposter.endInterval(kind.name, state, "abandoned")
    }
}
