import CoreGraphics
import Domain
import Foundation
import ScreenCaptureKit

// MARK: - Seam over ScreenCaptureKit

/// A value snapshot of `SCShareableContent`. SCK's own objects are not Sendable, so they never
/// leave the backend; the service reasons only about these values.
struct ShareableContentSnapshot: Sendable, Equatable {
    struct Display: Sendable, Equatable {
        var id: CGDirectDisplayID
        /// Desktop points, top-left origin (SCK reports Core Graphics global coordinates).
        var frame: CGRect
    }

    struct Window: Sendable, Equatable {
        var id: CGWindowID
        var ownerName: String
        var ownerPID: pid_t
        var title: String?
        var frame: CGRect
        var layer: Int
        var isOnScreen: Bool
    }

    var displays: [Display]
    var windows: [Window]
}

/// What the backend must capture. Built and validated by the service.
struct CapturePlan: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        /// A display with the given windows removed from the image.
        case display(CGDirectDisplayID, excludedWindowIDs: [CGWindowID])
        /// One window, captured independently of the desktop.
        case window(CGWindowID)
    }

    var source: Source
    /// Display-local points, top-left origin; nil captures the whole display or window.
    var sourceRect: CGRect?
    /// The display frame the selection was made on (display and region captures). The backend
    /// refuses to capture when its own content read reports another frame, so the stored source
    /// rectangle is never applied to a resized or moved display.
    var expectedDisplayFrame: CGRect?
    var showsCursor: Bool
    var includesShadow: Bool

    /// Bound dimensions before ScreenCaptureKit allocates capture surfaces or converts to Int.
    static func pixelSize(for rect: CGRect, scale: Double) throws(CaptureError) -> PixelSize {
        guard scale.isFinite, scale > 0 else { throw .displayChanged }
        let width = (rect.width * scale).rounded()
        let height = (rect.height * scale).rounded()
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, width.isFinite, height.isFinite,
            width >= 1, height >= 1, width <= 32_768, height <= 32_768
        else { throw .targetUnavailable }
        let size = PixelSize(width: Int(width), height: Int(height))
        guard ImportLimits.check(pixelSize: size) == nil else { throw .targetUnavailable }
        return size
    }
}

struct BackendImage: Sendable {
    var image: CGImage
    /// Pixels per point that ScreenCaptureKit reports for the captured content.
    var pointPixelScale: Double
    /// The shareable-content snapshot the capture filter was built from. The service derives the
    /// returned geometry from it, so pixels and geometry always describe the same displays.
    var content: ShareableContentSnapshot
}

/// The only boundary to ScreenCaptureKit. The live implementation uses the one-shot screenshot
/// API; tests substitute a fake so they never capture the real screen.
protocol ScreenCaptureBackend: Sendable {
    func shareableContent() async throws -> ShareableContentSnapshot
    func captureImage(_ plan: CapturePlan) async throws -> BackendImage
}

// MARK: - Service

/// One-shot still capture of a region, display, or window (FR-02, CAP-01, CAP-02).
///
/// Policy: at most one capture is in flight. A request that arrives while another is running is
/// rejected with `CaptureError.canceled` and never queued; the capture session in Features decides
/// whether to retry. Recortia's own windows are always excluded from display and region captures,
/// in addition to the window numbers the caller passes.
public actor ScreenCaptureService {
    private let backend: any ScreenCaptureBackend
    private let ownProcessID: pid_t
    private let now: @Sendable () -> Date
    private var isCapturing = false

    /// Tolerance for comparing display frames and scales reported at different times.
    private static let tolerance = 0.001

    public init() {
        self.init(
            backend: LiveScreenCaptureBackend(), ownProcessID: ProcessInfo.processInfo.processIdentifier,
            now: { Date() })
    }

    init(backend: any ScreenCaptureBackend, ownProcessID: pid_t, now: @escaping @Sendable () -> Date) {
        self.backend = backend
        self.ownProcessID = ownProcessID
        self.now = now
    }

    /// On-screen, normal-layer windows of other applications, each assigned to the display that
    /// shows most of it. Titles are for the chooser only; never log them or put them in filenames.
    public func windows() async throws(CaptureError) -> [WindowInfo] {
        try Self.checkCancellation()
        let content = try await fetchContent()
        try Self.checkCancellation()
        return content.windows.compactMap { window -> WindowInfo? in
            guard window.isOnScreen, window.layer == 0, window.ownerPID > 0, window.ownerPID != ownProcessID,
                window.frame.width >= 1, window.frame.height >= 1,
                let displayID = Self.bestDisplay(for: window.frame, in: content.displays)
            else { return nil }
            return WindowInfo(
                id: window.id, ownerName: window.ownerName, ownerPID: window.ownerPID, title: window.title,
                frame: Self.desktopRect(window.frame), displayID: displayID)
        }
    }

    public func capture(
        _ request: CaptureTarget, showsCursor: Bool, includesShadow: Bool, excludingWindowNumbers: [Int]
    ) async throws(CaptureError) -> (CGImage, CaptureGeometry) {
        guard !isCapturing else { throw .canceled }
        try Self.checkCancellation()
        isCapturing = true
        defer { isCapturing = false }

        let content = try await fetchContent()
        try Self.checkCancellation()
        let prepared = try prepare(
            request, content: content, showsCursor: showsCursor, includesShadow: includesShadow,
            excludingWindowNumbers: excludingWindowNumbers)

        let captured: BackendImage
        do {
            captured = try await backend.captureImage(prepared.plan)
        } catch {
            throw Self.map(error)
        }
        // SCK's completion-based API cannot be interrupted; a cancelled caller discards the image.
        try Self.checkCancellation()

        // Geometry comes from the snapshot the backend filtered with, not from the planning read:
        // a window can move between displays, or a display can be resized at an unchanged scale,
        // between the two reads.
        let (source, desktopBounds) = try Self.resolveGeometry(prepared, in: captured.content, ownPID: ownProcessID)

        if let expectedScale = prepared.expectedScale,
            abs(expectedScale - captured.pointPixelScale) > Self.tolerance
        {
            throw .displayChanged
        }
        guard captured.pointPixelScale.isFinite, captured.pointPixelScale > 0 else {
            throw .system(code: SCStreamError.Code.internalError.rawValue)
        }
        let geometry = CaptureGeometry(
            source: source, desktopBounds: desktopBounds, pointPixelScale: captured.pointPixelScale,
            pixelSize: PixelSize(width: captured.image.width, height: captured.image.height), capturedAt: now())
        return (captured.image, geometry)
    }

    // MARK: Planning

    private struct Prepared {
        var plan: CapturePlan
        var source: CaptureSource
        var desktopBounds: Rect<DesktopSpace>
        /// The selection-time display scale the capture must still match; nil for windows.
        var expectedScale: Double?
        /// The selection-time display a display or region capture must still match; nil for windows.
        var expectedDisplay: DisplayInfo?
        /// The window a window capture targets.
        var windowID: CGWindowID?
    }

    /// The source and bounds to report, checked against the content the backend captured from.
    private static func resolveGeometry(
        _ prepared: Prepared, in content: ShareableContentSnapshot, ownPID: pid_t
    ) throws(CaptureError) -> (CaptureSource, Rect<DesktopSpace>) {
        if let display = prepared.expectedDisplay {
            try verify(display, in: content)
            return (prepared.source, prepared.desktopBounds)
        }
        guard let id = prepared.windowID, let window = content.windows.first(where: { $0.id == id }),
            window.ownerPID != ownPID, let displayID = bestDisplay(for: window.frame, in: content.displays)
        else { throw .targetUnavailable }
        return (.window(id: id, displayID: displayID), desktopRect(window.frame))
    }

    private func prepare(
        _ request: CaptureTarget, content: ShareableContentSnapshot, showsCursor: Bool, includesShadow: Bool,
        excludingWindowNumbers: [Int]
    ) throws(CaptureError) -> Prepared {
        switch request {
        case .region(let rect, let display):
            try Self.verify(display, in: content)
            guard let local = DesktopGeometry.pixelAlignedLocalRect(rect, on: display) else {
                throw .targetUnavailable
            }
            _ = try CapturePlan.pixelSize(
                for: CGRect(x: local.minX, y: local.minY, width: local.width, height: local.height),
                scale: display.pointPixelScale)
            let plan = CapturePlan(
                source: .display(display.id, excludedWindowIDs: excludedWindowIDs(excludingWindowNumbers, content)),
                sourceRect: CGRect(x: local.minX, y: local.minY, width: local.width, height: local.height),
                expectedDisplayFrame: Self.cgRect(display.frame),
                showsCursor: showsCursor, includesShadow: includesShadow)
            return Prepared(
                plan: plan, source: .region(displayID: display.id),
                desktopBounds: DesktopGeometry.desktopRect(fromLocal: local, on: display),
                expectedScale: display.pointPixelScale, expectedDisplay: display, windowID: nil)

        case .display(let display):
            try Self.verify(display, in: content)
            _ = try CapturePlan.pixelSize(
                for: CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height),
                scale: display.pointPixelScale)
            let plan = CapturePlan(
                source: .display(display.id, excludedWindowIDs: excludedWindowIDs(excludingWindowNumbers, content)),
                sourceRect: nil, expectedDisplayFrame: Self.cgRect(display.frame), showsCursor: showsCursor,
                includesShadow: includesShadow)
            return Prepared(
                plan: plan, source: .display(id: display.id), desktopBounds: display.frame,
                expectedScale: display.pointPixelScale, expectedDisplay: display, windowID: nil)

        case .window(let info):
            guard let window = content.windows.first(where: { $0.id == info.id }), window.ownerPID != ownProcessID,
                let displayID = Self.bestDisplay(for: window.frame, in: content.displays)
            else { throw .targetUnavailable }
            let plan = CapturePlan(
                source: .window(window.id), sourceRect: nil, expectedDisplayFrame: nil, showsCursor: showsCursor,
                includesShadow: includesShadow)
            return Prepared(
                plan: plan, source: .window(id: window.id, displayID: displayID),
                desktopBounds: Self.desktopRect(window.frame), expectedScale: nil, expectedDisplay: nil,
                windowID: window.id)
        }
    }

    /// The caller's window numbers plus every window Recortia itself owns, sorted and unique.
    private func excludedWindowIDs(_ numbers: [Int], _ content: ShareableContentSnapshot) -> [CGWindowID] {
        var ids = Set(numbers.compactMap { CGWindowID(exactly: $0) })
        for window in content.windows where window.ownerPID == ownProcessID {
            ids.insert(window.id)
        }
        return ids.sorted()
    }

    private static func verify(_ display: DisplayInfo, in content: ShareableContentSnapshot) throws(CaptureError) {
        guard let current = content.displays.first(where: { $0.id == display.id }) else { throw .targetUnavailable }
        guard framesMatch(cgRect(display.frame), current.frame) else { throw .displayChanged }
    }

    /// Display frames reported at different times agree within rounding noise.
    static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func cgRect(_ rect: Rect<DesktopSpace>) -> CGRect {
        CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
    static func bestDisplay(
        for frame: CGRect, in displays: [ShareableContentSnapshot.Display]
    ) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: Double)?
        for display in displays {
            let overlap = frame.intersection(display.frame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (display.id, area) }
        }
        return best?.id
    }

    private static func desktopRect(_ rect: CGRect) -> Rect<DesktopSpace> {
        Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    // MARK: Errors

    private func fetchContent() async throws(CaptureError) -> ShareableContentSnapshot {
        do {
            return try await backend.shareableContent()
        } catch {
            throw Self.map(error)
        }
    }

    private static func checkCancellation() throws(CaptureError) {
        if Task.isCancelled { throw .canceled }
    }

    /// Maps ScreenCaptureKit and concurrency errors to the typed contract. A dark image is never
    /// treated as a denial; only reported errors are.
    static func map(_ error: any Error) -> CaptureError {
        if let error = error as? CaptureError { return error }
        if error is CancellationError { return .canceled }
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return .system(code: nsError.code) }
        switch SCStreamError.Code(rawValue: nsError.code) {
        case .userDeclined:
            return .permissionDenied
        case .noCaptureSource, .noWindowList, .noDisplayList:
            return .targetUnavailable
        case .userStopped:
            return .canceled
        default:
            return .system(code: nsError.code)
        }
    }
}
