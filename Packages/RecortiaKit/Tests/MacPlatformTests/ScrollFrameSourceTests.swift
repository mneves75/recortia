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

    @Test("A consumer that keeps up receives every frame in order")
    func keepsUp() async throws {
        let producer = FakeFrameProducer()
        let source = ScrollFrameSource(producer: producer)
        try await source.start()
        var iterator = source.frames.makeAsyncIterator()
        var received: [Int] = []
        for width in 1...4 {
            producer.push(try frame(width: width))
            if let image = await iterator.next() { received.append(image.width) }
        }
        #expect(received == [1, 2, 3, 4])
        await source.stop()
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

    @Test("Display and target changes stop the source with their reason")
    func stopReasons() async throws {
        for reason in [ScrollFrameSource.StopReason.displayChanged, .targetChanged] {
            let producer = FakeFrameProducer()
            let source = ScrollFrameSource(producer: producer)
            try await source.start()
            await source.stop(reason: reason)
            #expect(source.state == .stopped(reason))
            #expect(producer.stopCount == 1)
        }
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

    @Test("A source is single-use: it cannot be restarted after it stopped")
    func singleUse() async throws {
        let producer = FakeFrameProducer()
        let source = ScrollFrameSource(producer: producer)
        try await source.start()
        await #expect(throws: CaptureError.canceled) { try await source.start() }
        await source.stop()
        await #expect(throws: CaptureError.canceled) { try await source.start() }
        #expect(producer.state.withLock { $0.startCount } == 1)
    }

    @Test("Stopping before start never starts the producer")
    func stopBeforeStart() async throws {
        let producer = FakeFrameProducer()
        let source = ScrollFrameSource(producer: producer)
        await source.stop()
        #expect(source.state == .stopped(.requested))
        await #expect(throws: CaptureError.canceled) { try await source.start() }
        #expect(producer.state.withLock { $0.startCount } == 0)
        #expect(producer.stopCount == 0)
    }
}
