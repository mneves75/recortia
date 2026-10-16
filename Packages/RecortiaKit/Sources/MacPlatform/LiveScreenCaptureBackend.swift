import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit one-shot capture (`SCScreenshotManager.captureImage(contentFilter:configuration:)`,
/// macOS 14.0). Never SCStream, `screencapture`, or `CGWindowListCreateImage`.
///
/// SCK objects (`SCShareableContent`, `SCContentFilter`, `SCStreamConfiguration`) are not Sendable.
/// They are created, used, and dropped inside these nonisolated functions and never cross an
/// isolation boundary, so no concurrency annotations are relaxed. Only value snapshots and the
/// Sendable `CGImage` leave.
struct LiveScreenCaptureBackend: ScreenCaptureBackend {
    func shareableContent() async throws -> ShareableContentSnapshot {
        Self.snapshot(of: try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
    }

    private static func snapshot(of content: SCShareableContent) -> ShareableContentSnapshot {
        ShareableContentSnapshot(
            displays: content.displays.map { .init(id: $0.displayID, frame: $0.frame) },
            windows: content.windows.map { window in
                ShareableContentSnapshot.Window(
                    id: window.windowID, ownerName: window.owningApplication?.applicationName ?? "",
                    ownerPID: window.owningApplication?.processID ?? 0, title: window.title, frame: window.frame,
                    layer: window.windowLayer, isOnScreen: window.isOnScreen)
            })
    }

    func captureImage(_ plan: CapturePlan) async throws -> BackendImage {
        // Re-read content at capture time so a window or display that vanished since selection is
        // reported as unavailable instead of capturing something else.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        switch plan.source {
        case .display(let displayID, let excludedIDs):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetUnavailable
            }
            if let expected = plan.expectedDisplayFrame, !ScreenCaptureService.framesMatch(expected, display.frame) {
                throw CaptureError.displayChanged
            }
            filter = try await CaptureExclusion.filter(
                display: display, excludingWindowIDs: Set(excludedIDs), content: content,
                ownPID: ProcessInfo.processInfo.processIdentifier)
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.targetUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let scale = Double(filter.pointPixelScale)
        guard scale.isFinite, scale > 0 else { throw CaptureError.displayChanged }
        let pointRect = plan.sourceRect ?? CGRect(origin: .zero, size: filter.contentRect.size)
        let size = try CapturePlan.pixelSize(for: pointRect, scale: scale)

        let configuration = SCStreamConfiguration()
        if let sourceRect = plan.sourceRect { configuration.sourceRect = sourceRect }
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = false
        configuration.showsCursor = plan.showsCursor
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = !plan.includesShadow
        configuration.includeChildWindows = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return BackendImage(image: image, pointPixelScale: scale, content: Self.snapshot(of: content))
    }
}
