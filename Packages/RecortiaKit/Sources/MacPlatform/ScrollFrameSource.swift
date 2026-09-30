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

@MainActor
protocol ScrollTargetChecking {
    /// Bind the window beneath the selected region before starting a display stream.
    func bind() -> Bool
    func isCurrent() -> Bool
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
    private let targetChecker: (any ScrollTargetChecking)?
    private var continuation: AsyncStream<CGImage>.Continuation?
    private var displayObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?
    private var targetWatch: Task<Void, Never>?

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
                ownProcessID: ProcessInfo.processInfo.processIdentifier),
            targetChecker: LiveScrollTargetChecker(region: region, display: display))
        observeDisplayChanges()
    }

    init(producer: any ScrollFrameProducer, targetChecker: (any ScrollTargetChecking)? = nil) {
        self.producer = producer
        self.targetChecker = targetChecker
        let (stream, continuation) = AsyncStream<CGImage>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferDepth))
        frames = stream
        self.continuation = continuation
    }

    public func start() async throws(CaptureError) {
        guard state == .idle, let continuation else { throw .canceled }
        state = .starting
        if targetChecker?.bind() == false {
            finish(.targetChanged)
            throw .targetUnavailable
        }
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
        observeTargetChanges()
        guard await ensureTargetCurrent() else { throw .targetUnavailable }
    }

    /// Check again before accepting a buffered frame, including one queued before a focus change.
    public func ensureTargetCurrent() async -> Bool {
        guard state == .running else { return false }
        guard targetChecker?.isCurrent() != false else {
            await stop(reason: .targetChanged)
            return false
        }
        return true
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
        targetWatch?.cancel()
        targetWatch = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
            self.displayObserver = nil
        }
    }

    private func observeTargetChanges() {
        guard targetChecker != nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { _ = await self.ensureTargetCurrent() }
            }
        }
        // Window closure and movement have no reliable notification without Accessibility. Check
        // window identity while collecting or paused, even when no new frame arrives.
        targetWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, await self.ensureTargetCurrent() else { return }
            }
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
