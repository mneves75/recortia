import AppKit
import CoreGraphics
import Domain
import Foundation

/// Produces viewport frames for one scrolling session. The live implementation wraps an SCStream;
/// tests use a fake. `stop()` must end capture and drop both handlers.
protocol ScrollFrameProducer: Sendable {
    func start(
        deliver: @escaping @Sendable (CGImage) -> Void, ended: @escaping @Sendable (CaptureError) -> Void
    ) async throws(CaptureError)
    func stop() async
}

/// Viewport frames of one region for an explicit scrolling session only (FR-10). Never used for
/// still capture, never running while idle (CAP-02).
///
/// Frames arrive through `frames`, a bounded newest-wins buffer of at most `bufferDepth`
/// full-resolution images: when the consumer falls behind, older frames are dropped. The source is
/// single-use; `stop()` ends the stream, stops capture, and releases the frame handlers. It stops
/// by itself when the display configuration changes or the stream fails.
@MainActor
public final class ScrollFrameSource {
    public enum StopReason: Sendable, Equatable {
        case requested
        case targetChanged
        case displayChanged
        case failed(CaptureError)
    }

    public enum State: Sendable, Equatable {
        case idle
        case starting
        case running
        case stopped(StopReason)
    }

    /// Maximum number of undelivered frames held (SPEC.md FR-10: at most two full-resolution buffers).
    public static let bufferDepth = 2

    public nonisolated let frames: AsyncStream<CGImage>
    public private(set) var state: State = .idle

    private let producer: any ScrollFrameProducer
    private var continuation: AsyncStream<CGImage>.Continuation?
    private var displayObserver: (any NSObjectProtocol)?

    /// A live source for `region` on `display`, excluding Recortia's windows and the given window
    /// numbers. The region is clamped to the display; an empty result fails at `start()`.
    public convenience init(region: Rect<DesktopSpace>, display: DisplayInfo, excludingWindowNumbers: [Int] = []) {
        let local = DesktopGeometry.pixelAlignedLocalRect(region, on: display)
        self.init(
            producer: SCStreamFrameProducer(
                displayID: display.id,
                sourceRect: local.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
                expectedScale: display.pointPixelScale,
                excludedWindowIDs: excludingWindowNumbers.compactMap { CGWindowID(exactly: $0) },
                ownProcessID: ProcessInfo.processInfo.processIdentifier))
        observeDisplayChanges()
    }

    init(producer: any ScrollFrameProducer) {
        self.producer = producer
        let (stream, continuation) = AsyncStream<CGImage>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferDepth))
        frames = stream
        self.continuation = continuation
    }

    public func start() async throws(CaptureError) {
        guard state == .idle, let continuation else { throw .canceled }
        state = .starting
        do {
            try await producer.start(
                deliver: { image in continuation.yield(image) },
                ended: { [weak self] error in
                    Task { @MainActor in await self?.stop(reason: .failed(error)) }
                })
        } catch {
            if state == .starting { finish(.failed(error)) }
            throw error
        }
        guard state == .starting else {
            // stop() ran while the stream was starting; make sure nothing keeps running.
            await producer.stop()
            throw .canceled
        }
        state = .running
    }

    public func stop(reason: StopReason = .requested) async {
        switch state {
        case .stopped:
            return
        case .idle:
            finish(reason)
        case .starting:
            // start() observes the new state and stops the producer when its start returns.
            finish(reason)
        case .running:
            // Mark stopped first so a concurrent stop() returns; end the stream only after capture
            // has really stopped, so a consumer that sees the end knows no handler is left.
            state = .stopped(reason)
            await producer.stop()
            finish(reason)
        }
    }

    private func finish(_ reason: StopReason) {
        state = .stopped(reason)
        continuation?.finish()
        continuation = nil
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
            self.displayObserver = nil
        }
    }

    private func observeDisplayChanges() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.stop(reason: .displayChanged) }
            }
        }
    }
}
