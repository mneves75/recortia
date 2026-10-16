import CoreGraphics
import Domain
import Foundation
import Synchronization
import Testing

@testable import MacPlatform

/// Stands in for the SCStream: the test pushes frames through the handler the source installed.
final class FakeFrameProducer: ScrollFrameProducer {
    struct State {
        var deliver: (@Sendable (CGImage) -> Void)?
        var ended: (@Sendable (CaptureError) -> Void)?
        var startCount = 0
        var stopCount = 0
        var startFailure: CaptureError?
    }

    let state = Mutex(State())

    func start(
        deliver: @escaping @Sendable (CGImage) -> Void, ended: @escaping @Sendable (CaptureError) -> Void
    ) async throws(CaptureError) {
        let failure = state.withLock { state -> CaptureError? in
            state.startCount += 1
            if let failure = state.startFailure { return failure }
            state.deliver = deliver
            state.ended = ended
            return nil
        }
        if let failure { throw failure }
    }

    func stop() async {
        state.withLock { state in
            state.stopCount += 1
            state.deliver = nil
            state.ended = nil
        }
    }

    /// Delivers through the installed handler, or through a handler captured before stop.
    func push(_ image: CGImage, via handler: (@Sendable (CGImage) -> Void)? = nil) {
        let deliver = handler ?? state.withLock { $0.deliver }
        deliver?(image)
    }

    func fail(_ error: CaptureError) {
        let ended = state.withLock { $0.ended }
        ended?(error)
    }

    var hasHandlers: Bool { state.withLock { $0.deliver != nil || $0.ended != nil } }
    var stopCount: Int { state.withLock { $0.stopCount } }
}

@MainActor
private final class FakeScrollTargetChecker: ScrollTargetChecking {
    var boundWindowID: CGWindowID? = 42
    var canBind = true
    var current = true

    func bind() -> Bool { canBind }
    func isCurrent() -> Bool { current }
}

private actor SuspendedFrameProducer: ScrollFrameProducer {
    enum Suspension: Sendable { case preparation, startCallback }
    struct Observation: Sendable {
        var stops = 0
        var starts = 0
        var startsAfterControlStop = 0
        var hasHandlers = false
        var running = false
    }

    let suspension: Suspension
    private var observation = Observation()
    private var deliver: (@Sendable (CGImage) -> Void)?
    private var ended: (@Sendable (CaptureError) -> Void)?
    private var generation = UUID()
    private var controlStopped = false
    private var suspended = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(_ suspension: Suspension) { self.suspension = suspension }

    func start(
        deliver: @escaping @Sendable (CGImage) -> Void, ended: @escaping @Sendable (CaptureError) -> Void
    ) async throws(CaptureError) {
        let request = generation
        self.deliver = deliver
        self.ended = ended
        if suspension == .preparation { await hold() }
        guard request == generation else { throw .canceled }
        observation.starts += 1
        if controlStopped { observation.startsAfterControlStop += 1 }
        observation.running = true
        if suspension == .startCallback { await hold() }
        guard request == generation else { throw .canceled }
    }

    func stop() async {
        generation = UUID()
        observation.stops += 1
        deliver = nil
        ended = nil
        observation.running = false
    }

    private func hold() async {
        await withCheckedContinuation { continuation in
            release = continuation
            suspended = true
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func noteControlStopped() { controlStopped = true }
    func observe() -> Observation {
        var result = observation
        result.hasHandlers = deliver != nil || ended != nil
        return result
    }
    func resume() {
        release?.resume()
        release = nil
    }
}

@MainActor
private func frame(width: Int) throws -> CGImage {
    try #require(TestSupport.image(width: width, height: 2))
}

@MainActor
private func drain(_ source: ScrollFrameSource) async -> [Int] {
    var widths: [Int] = []
    for await image in source.frames { widths.append(image.width) }
    return widths
}

@MainActor
@Suite("Scroll frame source: bounded newest-wins buffering and explicit stop (FR-10, PERM-02, SCR-04)")
struct ScrollFrameSourceTests {
    @Test("The running source exposes its startup window binding and clears it on stop")
    func exposesBoundWindow() async throws {
        let checker = FakeScrollTargetChecker()
        let source = ScrollFrameSource(producer: FakeFrameProducer(), targetChecker: checker)
        #expect(source.boundWindowID == nil)
        try await source.start()
        #expect(source.boundWindowID == 42)
        checker.boundWindowID = 99
        #expect(source.boundWindowID == 42)
        await source.stop()
        #expect(source.boundWindowID == nil)
    }

    @Test(
        "Cancel during preparation or an outstanding start stops the producer immediately",
        arguments: [SuspendedFrameProducer.Suspension.preparation, .startCallback])
    fileprivate func stopDuringStartup(_ suspension: SuspendedFrameProducer.Suspension) async {
        let producer = SuspendedFrameProducer(suspension)
        let source = ScrollFrameSource(producer: producer)
        let start = Task {
            await #expect(throws: CaptureError.canceled) { try await source.start() }
        }
        await producer.waitUntilSuspended()
        await source.stop()
        await producer.noteControlStopped()
        let stopped = await producer.observe()
        #expect(stopped.stops > 0)
        #expect(!stopped.hasHandlers)
        #expect(!stopped.running)
        await producer.resume()
        _ = await start.value
        let finished = await producer.observe()
        #expect(finished.startsAfterControlStop == 0)
        #expect(finished.starts == (suspension == .preparation ? 0 : 1))
        #expect(!finished.hasHandlers)
        #expect(!finished.running)
        #expect(await drain(source).isEmpty)
    }

    @Test("A missing scroll target refuses to start any screen stream")
    func missingTargetNeverStarts() async {
        let producer = FakeFrameProducer()
        let checker = FakeScrollTargetChecker()
        checker.canBind = false
        let source = ScrollFrameSource(producer: producer, targetChecker: checker)
        await #expect(throws: CaptureError.targetUnavailable) { try await source.start() }
        #expect(producer.state.withLock { $0.startCount } == 0)
        #expect(source.state == .stopped(.targetChanged))
    }

    @Test("A changed target stops capture and releases handlers, including while no frames arrive")
    func changedTargetStopsWithoutFrame() async throws {
        let producer = FakeFrameProducer()
        let checker = FakeScrollTargetChecker()
        let source = ScrollFrameSource(producer: producer, targetChecker: checker)
        try await source.start()
        checker.current = false
        #expect(await source.ensureTargetCurrent() == false)
        #expect(source.state == .stopped(.targetChanged))
        #expect(producer.stopCount == 1)
        #expect(!producer.hasHandlers)
    }

    @Test("The buffer holds at most two frames and keeps the newest")
    func boundedNewestWins() async throws {
        #expect(ScrollFrameSource.bufferDepth == 2)
        let producer = FakeFrameProducer()
        let source = ScrollFrameSource(producer: producer)
        try await source.start()
        for width in 1...5 { producer.push(try frame(width: width)) }
        await source.stop()
        #expect(await drain(source) == [4, 5])
    }

    @Test("stop() ends the stream, stops the producer once, releases handlers, and ignores late frames")
    func stopReleasesEverything() async throws {
        let producer = FakeFrameProducer()
        let source = ScrollFrameSource(producer: producer)
        try await source.start()
        #expect(source.state == .running)
        let lateHandler = producer.state.withLock { $0.deliver }
        await source.stop()
        await source.stop()
        #expect(source.state == .stopped(.requested))
        #expect(producer.stopCount == 1)
        #expect(!producer.hasHandlers)
        producer.push(try frame(width: 9), via: lateHandler)
        #expect(await drain(source).isEmpty)
    }

    @Test("A stream failure stops the source, reports the error, and releases the producer")
    func producerFailure() async throws {
        let producer = FakeFrameProducer()
        let source = ScrollFrameSource(producer: producer)
        try await source.start()
        producer.fail(.permissionDenied)
        #expect(await drain(source).isEmpty)
        for _ in 0..<50 where source.state == .running { await Task.yield() }
        #expect(source.state == .stopped(.failed(.permissionDenied)))
        #expect(producer.stopCount == 1)
        #expect(!producer.hasHandlers)
    }

    @Test("A failed start throws, finishes the stream, and leaves nothing running")
    func startFailure() async throws {
        let producer = FakeFrameProducer()
        producer.state.withLock { $0.startFailure = .permissionDenied }
        let source = ScrollFrameSource(producer: producer)
        await #expect(throws: CaptureError.permissionDenied) { try await source.start() }
        #expect(source.state == .stopped(.failed(.permissionDenied)))
        #expect(await drain(source).isEmpty)
    }

}
