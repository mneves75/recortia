import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Synchronization
import VideoToolbox

/// The live SCStream behind `ScrollFrameSource`, used only during an explicit scrolling session.
///
/// SCK objects are not Sendable. They are built in a nonisolated helper that returns them as a
/// `sending` value, then owned by this actor for the life of the session. Start and stop use the
/// completion-handler APIs with explicitly `@Sendable` callbacks, so no SCK object crosses an
/// isolation boundary. Frames are copied out of the capture surface immediately, so the consumer
/// never holds ScreenCaptureKit's buffer pool.
actor SCStreamFrameProducer: ScrollFrameProducer {
    private struct Session {
        var stream: SCStream
        var output: StreamOutput
    }

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect?
    private let expectedScale: Double
    private let excludedWindowIDs: [CGWindowID]
    private let ownProcessID: pid_t
    private let sampleQueue = DispatchQueue(label: "recortia.scroll-frames", qos: .userInitiated)
    private var session: Session?

    /// Scrolling needs steady frames, not video: 15 fps keeps work and memory bounded.
    private static let framesPerSecond: Int32 = 15
    /// Few capture surfaces in flight; each frame is copied out and its surface returned at once.
    private static let surfaceQueueDepth = 3

    init(
        displayID: CGDirectDisplayID, sourceRect: CGRect?, expectedScale: Double, excludedWindowIDs: [CGWindowID],
        ownProcessID: pid_t
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.expectedScale = expectedScale
        self.excludedWindowIDs = excludedWindowIDs
        self.ownProcessID = ownProcessID
    }

    func start(
        deliver: @escaping @Sendable (CGImage) -> Void, ended: @escaping @Sendable (CaptureError) -> Void
    ) async throws(CaptureError) {
        guard session == nil else { throw .canceled }
        guard let sourceRect else { throw .targetUnavailable }
        do {
            let made = try await Self.makeSession(
                displayID: displayID, sourceRect: sourceRect, expectedScale: expectedScale,
                excludedWindowIDs: Set(excludedWindowIDs), ownProcessID: ownProcessID, sampleQueue: sampleQueue,
                output: StreamOutput(deliver: deliver, ended: ended))
            session = made
            let stream = made.stream
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                stream.startCapture { @Sendable error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            await stop()
            throw ScreenCaptureService.map(error)
        }
    }

    func stop() async {
        guard let current = session else { return }
        session = nil
        current.output.detach()
        let stream = current.stream
        // Removing the output cannot fail for an output that was added; if the stream already ended
        // (for example, the system stopped it) the stop callback reports an error that changes nothing:
        // the handlers are detached above and the stream is released with `current`.
        try? stream.removeStreamOutput(current.output, type: .screen)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { @Sendable _ in continuation.resume() }
        }
    }

    private static func makeSession(
        displayID: CGDirectDisplayID, sourceRect: CGRect, expectedScale: Double, excludedWindowIDs: Set<CGWindowID>,
        ownProcessID: pid_t, sampleQueue: DispatchQueue, output: StreamOutput
    ) async throws -> sending Session {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.targetUnavailable
        }
        // Recortia is excluded as an application so its windows created after the stream starts (a
        // pin, the drag chip) never enter scroll frames.
        let filter = try await CaptureExclusion.filter(
            display: display, excludingWindowIDs: excludedWindowIDs, content: content, ownPID: ownProcessID)
        let scale = Double(filter.pointPixelScale)
        guard abs(scale - expectedScale) <= 0.001 else { throw CaptureError.displayChanged }
        let size = try CapturePlan.pixelSize(for: sourceRect, scale: scale)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = surfaceQueueDepth
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        return Session(stream: stream, output: output)
    }
}

/// Receives sample buffers on the sample queue and copies complete frames into standalone images.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private struct Handlers {
        var deliver: (@Sendable (CGImage) -> Void)?
        var ended: (@Sendable (CaptureError) -> Void)?
    }

    private let handlers: Mutex<Handlers>

    init(deliver: @escaping @Sendable (CGImage) -> Void, ended: @escaping @Sendable (CaptureError) -> Void) {
        handlers = Mutex(Handlers(deliver: deliver, ended: ended))
    }

    /// Drops both handlers so no frame or error reaches the session after stop.
    func detach() {
        handlers.withLock { $0 = Handlers() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
            let pixelBuffer = sampleBuffer.imageBuffer, let image = Self.copyImage(from: pixelBuffer)
        else { return }
        // Delivered under the lock so no frame follows `detach()`; the handler only yields to a
        // buffered stream and never re-enters this output.
        handlers.withLock { $0.deliver?(image) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let ended = handlers.withLock { state -> (@Sendable (CaptureError) -> Void)? in
            let ended = state.ended
            state = Handlers()
            return ended
        }
        ended?(ScreenCaptureService.map(error))
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    /// Copies the frame into memory owned by the image so the capture surface returns to SCK's pool.
    private static func copyImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var surfaceImage: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &surfaceImage) == noErr,
            let surfaceImage
        else { return nil }
        let colorSpace =
            surfaceImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: surfaceImage.width, height: surfaceImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(surfaceImage, in: CGRect(x: 0, y: 0, width: surfaceImage.width, height: surfaceImage.height))
        return context.makeImage()
    }
}
