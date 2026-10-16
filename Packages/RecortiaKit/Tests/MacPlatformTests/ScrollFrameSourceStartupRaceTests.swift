import CoreGraphics
import Domain
import Foundation
import Testing

@testable import MacPlatform

/// A producer whose start completes after Stop as if Stop never happened, like an SCStream whose
/// start callback raced a stop: the source alone must make sure nothing keeps running (C-2).
private actor UnheedingFrameProducer: ScrollFrameProducer {
    enum Completion: Sendable {
        case succeed
        case fail(CaptureError)
    }

    let completion: Completion
    private(set) var stops = 0
    private(set) var starts = 0
    private var deliver: (@Sendable (CGImage) -> Void)?
    private var ended: (@Sendable (CaptureError) -> Void)?
    private var release: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var suspended = false

    init(_ completion: Completion) { self.completion = completion }

    func start(
        deliver: @escaping @Sendable (CGImage) -> Void, ended: @escaping @Sendable (CaptureError) -> Void
    ) async throws(CaptureError) {
        starts += 1
        await withCheckedContinuation { continuation in
            release = continuation
            suspended = true
            arrival?.resume()
            arrival = nil
        }
        switch completion {
        case .succeed:
            self.deliver = deliver
            self.ended = ended
        case .fail(let error):
            throw error
        }
    }

    func stop() async {
        stops += 1
        deliver = nil
        ended = nil
    }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func resume() {
        release?.resume()
        release = nil
    }

    var hasHandlers: Bool { deliver != nil || ended != nil }

    func push(_ image: CGImage) { deliver?(image) }
}

@MainActor
@Suite("Scroll frame source: Stop during startup with a producer that ignores it (C-2, FR-10)")
struct ScrollFrameSourceStartupRaceTests {
    private func frames(of source: ScrollFrameSource) async -> Int {
        var count = 0
        for await _ in source.frames { count += 1 }
        return count
    }

    @Test("A start that succeeds after Stop is stopped again and delivers nothing")
    func successAfterStopIsStoppedAgain() async throws {
        let producer = UnheedingFrameProducer(.succeed)
        let source = ScrollFrameSource(producer: producer)
        let start = Task { () -> CaptureError? in
            do throws(CaptureError) {
                try await source.start()
                return nil
            } catch {
                return error
            }
        }
        await producer.waitUntilSuspended()
        await source.stop()
        #expect(await producer.stops == 1)
        #expect(source.state == .stopped(.requested))
        await producer.resume()
        #expect(await start.value == .canceled)
        #expect(await producer.stops == 2, "the stream that started after Stop must be stopped again")
        #expect(await !producer.hasHandlers)
        #expect(await producer.starts == 1)
        #expect(source.state == .stopped(.requested))
        #expect(source.boundWindowID == nil)
        await producer.push(try #require(TestSupport.image(width: 3, height: 2)))
        #expect(await frames(of: source) == 0)
    }

    @Test("A start failing after Stop reports cancellation and keeps the requested stop reason")
    func failureAfterStopReportsCancellation() async {
        let producer = UnheedingFrameProducer(.fail(.displayChanged))
        let source = ScrollFrameSource(producer: producer)
        let start = Task { () -> CaptureError? in
            do throws(CaptureError) {
                try await source.start()
                return nil
            } catch {
                return error
            }
        }
        await producer.waitUntilSuspended()
        await source.stop()
        await producer.resume()
        #expect(await start.value == .canceled)
        #expect(source.state == .stopped(.requested))
        #expect(await !producer.hasHandlers)
        #expect(await frames(of: source) == 0)
    }
}
