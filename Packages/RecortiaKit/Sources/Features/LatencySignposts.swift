import os

/// Latency intervals for Instruments' os_signpost instrument and `xctrace` (FR-14, A-13 step 1),
/// subsystem `dev.mvneves.Recortia`, category `latency`. They carry durations only, never content,
/// and claim no measurement by themselves: numbers come from recorded traces.
@MainActor
public enum LatencySignposts {
    public enum Interval: CaseIterable, Hashable, Sendable {
        /// A capture shortcut's key-up to the region overlay or chooser on screen.
        case shortcutToOverlay
        /// The capture call, after the selection and any countdown, to its returned image.
        case selectionToCapture
        /// A completed capture handed to the shell to its editor window on screen.
        case captureToEditor
        /// A newly shown editor window to the canvas's first successful draw of the image.
        case editorToFirstDraw

        fileprivate var name: StaticString {
            switch self {
            case .shortcutToOverlay: "Shortcut to overlay"
            case .selectionToCapture: "Selection to capture"
            case .captureToEditor: "Capture to editor window"
            case .editorToFirstDraw: "Editor to first canvas draw"
            }
        }
    }

    private static let signposter = OSSignposter(subsystem: "dev.mvneves.Recortia", category: "latency")
    /// One open interval per kind: a newer request supersedes an older one.
    private static var open: [Interval: OSSignpostIntervalState] = [:]

    public static func begin(_ interval: Interval) {
        end(interval)
        open[interval] = signposter.beginInterval(interval.name, id: signposter.makeSignpostID())
    }

    /// Ends `interval` if it is open; otherwise does nothing.
    public static func end(_ interval: Interval) {
        guard let state = open.removeValue(forKey: interval) else { return }
        signposter.endInterval(interval.name, state)
    }

    static func isOpen(_ interval: Interval) -> Bool { open[interval] != nil }
}
