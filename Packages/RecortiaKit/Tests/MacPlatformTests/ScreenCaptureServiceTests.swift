import CoreGraphics
import Domain
import Foundation
import ScreenCaptureKit
import Synchronization
import Testing

@testable import MacPlatform

/// Failures the fake seam can inject, built into real error values at throw time.
enum FakeFailure: Sendable {
    case streamError(Int)
    case cancellation
    case capture(CaptureError)
    case foreign(domain: String, code: Int)

    var error: any Error {
        switch self {
        case .streamError(let code): NSError(domain: SCStreamErrorDomain, code: code)
        case .cancellation: CancellationError()
        case .capture(let error): error
        case .foreign(let domain, let code): NSError(domain: domain, code: code)
        }
    }
}

/// A scripted stand-in for ScreenCaptureKit. It never touches the real screen.
final class FakeCaptureBackend: ScreenCaptureBackend {
    struct State {
        var content: ShareableContentSnapshot
        var contentFailure: FakeFailure?
        var captureFailure: FakeFailure?
        var imageSize = PixelSize(width: 200, height: 100)
        var reportedScale = 2.0
        var plans: [CapturePlan] = []
        var contentCalls = 0
        var gated = false
    }

    let state: Mutex<State>
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()

    init(content: ShareableContentSnapshot) {
        state = Mutex(State(content: content))
    }

    func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var plans: [CapturePlan] { state.withLock { $0.plans } }

    func shareableContent() async throws -> ShareableContentSnapshot {
        let (content, failure) = state.withLock { state in
            state.contentCalls += 1
            return (state.content, state.contentFailure)
        }
        if let failure { throw failure.error }
        return content
    }

    func captureImage(_ plan: CapturePlan) async throws -> BackendImage {
        let (failure, size, scale, gated) = state.withLock { state in
            state.plans.append(plan)
            return (state.captureFailure, state.imageSize, state.reportedScale, state.gated)
        }
        if gated {
            entered.continuation.yield()
            for await _ in release.stream { break }
        }
        if let failure { throw failure.error }
        guard let image = TestSupport.image(width: size.width, height: size.height) else {
            throw FakeFailure.foreign(domain: "test", code: 1).error
        }
        return BackendImage(image: image, pointPixelScale: scale)
    }
}

private let ownPID: pid_t = 4242
private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

private let retina = TestSupport.display(id: 1, x: 0, y: 0, width: 1440, height: 900, scale: 2)
private let standard = TestSupport.display(id: 2, x: -1920, y: -180, width: 1920, height: 1080, scale: 1)

private func record(_ display: DisplayInfo) -> ShareableContentSnapshot.Display {
    ShareableContentSnapshot.Display(
        id: display.id,
        frame: CGRect(
            x: display.frame.minX, y: display.frame.minY, width: display.frame.width, height: display.frame.height))
}

private func window(
    _ id: CGWindowID, pid: pid_t = 900, frame: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300),
    layer: Int = 0, onScreen: Bool = true, title: String? = "Secret document title"
) -> ShareableContentSnapshot.Window {
    ShareableContentSnapshot.Window(
        id: id, ownerName: "Other", ownerPID: pid, title: title, frame: frame, layer: layer, isOnScreen: onScreen)
}

private func makeService(
    windows: [ShareableContentSnapshot.Window] = [], displays: [DisplayInfo] = [retina, standard]
) -> (ScreenCaptureService, FakeCaptureBackend) {
    let backend = FakeCaptureBackend(
        content: ShareableContentSnapshot(displays: displays.map(record), windows: windows))
    let service = ScreenCaptureService(backend: backend, ownProcessID: ownPID, now: { fixedDate })
    return (service, backend)
}

@Suite("Screen capture service over a fake ScreenCaptureKit seam (CAP-01, CAP-02, GEO-01)")
struct ScreenCaptureServiceTests {
    @Test("A 2× region capture uses display-local points and the display's scale")
    func regionAt2x() async throws {
        let (service, backend) = makeService()
        let rect = Rect<DesktopSpace>(x: 100, y: 100, width: 100, height: 50)
        let (image, geometry) = try await service.capture(
            .region(rect, display: retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        let plan = try #require(backend.plans.first)
        #expect(plan.source == .display(1, excludedWindowIDs: []))
        #expect(plan.sourceRect == CGRect(x: 100, y: 100, width: 100, height: 50))
        #expect(plan.showsCursor == false)
        #expect(geometry.pointPixelScale == 2)
        #expect(geometry.source == .region(displayID: 1))
        #expect(geometry.desktopBounds == rect)
        #expect(geometry.pixelSize == PixelSize(width: image.width, height: image.height))
        #expect(geometry.capturedAt == fixedDate)
    }

    @Test("A 1× region on a negative-origin display is converted to that display's local points")
    func regionAt1xNegativeOrigin() async throws {
        let (service, backend) = makeService()
        backend.update { $0.reportedScale = 1 }
        let rect = Rect<DesktopSpace>(x: -1900, y: -100, width: 100, height: 50)
        let (_, geometry) = try await service.capture(
            .region(rect, display: standard), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        #expect(backend.plans.first?.sourceRect == CGRect(x: 20, y: 80, width: 100, height: 50))
        #expect(geometry.pointPixelScale == 1)
        #expect(geometry.desktopBounds == rect)
    }

    @Test("The recorded pixel size comes from the actual image, not from points × scale")
    func pixelSizeFromImage() async throws {
        let (service, backend) = makeService()
        backend.update { $0.imageSize = PixelSize(width: 123, height: 45) }
        let (_, geometry) = try await service.capture(
            .region(Rect(x: 0, y: 0, width: 10, height: 10), display: retina), showsCursor: false,
            includesShadow: true, excludingWindowNumbers: [])
        #expect(geometry.pixelSize == PixelSize(width: 123, height: 45))
    }

    @Test("A region spilling off its display is clamped to it; one entirely outside is unavailable")
    func regionClamping() async throws {
        let (service, backend) = makeService()
        let (_, geometry) = try await service.capture(
            .region(Rect(x: 1400.25, y: 880, width: 300, height: 300), display: retina), showsCursor: false,
            includesShadow: true, excludingWindowNumbers: [])
        #expect(backend.plans.first?.sourceRect == CGRect(x: 1400, y: 880, width: 40, height: 20))
        #expect(geometry.desktopBounds == Rect<DesktopSpace>(x: 1400, y: 880, width: 40, height: 20))
        await #expect(throws: CaptureError.targetUnavailable) {
            _ = try await service.capture(
                .region(Rect(x: 2000, y: 0, width: 10, height: 10), display: retina), showsCursor: false,
                includesShadow: true, excludingWindowNumbers: [])
        }
        #expect(backend.plans.count == 1)
    }

    @Test("Recortia's own windows and the caller's window numbers are excluded; other apps' are not")
    func exclusionList() async throws {
        let (service, backend) = makeService(windows: [window(77, pid: ownPID), window(88), window(78, pid: ownPID)])
        _ = try await service.capture(
            .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [66, 55, 66, -1])
        #expect(backend.plans.first?.source == .display(1, excludedWindowIDs: [55, 66, 77, 78]))
    }

    @Test(
        "Cursor and shadow flags pass through unchanged",
        arguments: [(false, false), (false, true), (true, false), (true, true)])
    func flagsPassThrough(showsCursor: Bool, includesShadow: Bool) async throws {
        let (service, backend) = makeService(windows: [window(10)])
        _ = try await service.capture(
            .window(
                WindowInfo(
                    id: 10, ownerName: "Other", ownerPID: 900, title: nil,
                    frame: Rect(x: 100, y: 100, width: 400, height: 300),
                    displayID: 1)),
            showsCursor: showsCursor, includesShadow: includesShadow, excludingWindowNumbers: [])
        let plan = try #require(backend.plans.first)
        #expect(plan.showsCursor == showsCursor)
        #expect(plan.includesShadow == includesShadow)
    }

    @Test("Oversized captures are rejected before capture surfaces are allocated")
    func oversizedCaptureNeverReachesBackend() async throws {
        let huge = TestSupport.display(id: 1, x: 0, y: 0, width: 8000, height: 6000, scale: 1)
        let (service, backend) = makeService(displays: [huge])
        backend.update { $0.reportedScale = 1 }
        for request in [CaptureTarget.display(huge), .region(huge.frame, display: huge)] {
            await #expect(throws: CaptureError.targetUnavailable) {
                _ = try await service.capture(
                    request, showsCursor: false, includesShadow: false, excludingWindowNumbers: [])
            }
        }
        #expect(backend.plans.isEmpty)
    }

    @Test("A display capture covers the whole display at its scale")
    func displayCapture() async throws {
        let (service, backend) = makeService()
        backend.update { $0.reportedScale = 1 }
        let (_, geometry) = try await service.capture(
            .display(standard), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        #expect(backend.plans.first?.sourceRect == nil)
        #expect(geometry.source == .display(id: 2))
        #expect(geometry.desktopBounds == standard.frame)
        #expect(geometry.pointPixelScale == 1)
    }

    @Test("A window capture uses the window's current frame and the scale SCK reports for it")
    func windowCapture() async throws {
        let moved = CGRect(x: -1500, y: 20, width: 640, height: 480)
        let (service, backend) = makeService(windows: [window(10, frame: moved)])
        backend.update { $0.reportedScale = 1 }
        let info = WindowInfo(
            id: 10, ownerName: "Other", ownerPID: 900, title: nil, frame: Rect(x: 0, y: 0, width: 10, height: 10),
            displayID: 1)
        let (_, geometry) = try await service.capture(
            .window(info), showsCursor: false, includesShadow: false, excludingWindowNumbers: [])
        #expect(backend.plans.first?.source == .window(10))
        #expect(geometry.source == .window(id: 10, displayID: 2))
        #expect(geometry.desktopBounds == Rect<DesktopSpace>(x: -1500, y: 20, width: 640, height: 480))
        #expect(geometry.pointPixelScale == 1)
    }

    @Test("A vanished window, a Recortia window, or a missing display is unavailable")
    func unavailableTargets() async throws {
        let (service, backend) = makeService(windows: [window(20, pid: ownPID)], displays: [retina])
        let gone = WindowInfo(
            id: 99, ownerName: "Other", ownerPID: 900, title: nil, frame: Rect(x: 0, y: 0, width: 10, height: 10),
            displayID: 1)
        let own = WindowInfo(
            id: 20, ownerName: "Recortia", ownerPID: ownPID, title: nil, frame: Rect(x: 0, y: 0, width: 10, height: 10),
            displayID: 1)
        for target in [CaptureTarget.window(gone), .window(own), .display(standard)] {
            await #expect(throws: CaptureError.targetUnavailable) {
                _ = try await service.capture(
                    target, showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
            }
        }
        #expect(backend.plans.isEmpty)
    }

    @Test("A display whose frame or scale changed since selection reports displayChanged")
    func displayChangedDetection() async throws {
        let rearranged = TestSupport.display(id: 1, x: 0, y: 0, width: 1728, height: 1117, scale: 2)
        let (service, backend) = makeService(displays: [rearranged])
        await #expect(throws: CaptureError.displayChanged) {
            _ = try await service.capture(
                .region(Rect(x: 0, y: 0, width: 10, height: 10), display: retina), showsCursor: false,
                includesShadow: true, excludingWindowNumbers: [])
        }
        #expect(backend.plans.isEmpty)

        let (sameFrame, scaleBackend) = makeService(displays: [retina])
        scaleBackend.update { $0.reportedScale = 1 }
        await #expect(throws: CaptureError.displayChanged) {
            _ = try await sameFrame.capture(
                .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        }
    }

    @Test(
        "ScreenCaptureKit and cancellation errors map to typed capture errors",
        arguments: [
            (FakeFailure.streamError(-3801), CaptureError.permissionDenied),
            (.streamError(-3815), .targetUnavailable),
            (.streamError(-3813), .targetUnavailable),
            (.streamError(-3814), .targetUnavailable),
            (.streamError(-3817), .canceled),
            (.streamError(-3811), .system(code: -3811)),
            (.streamError(-3821), .system(code: -3821)),
            (.cancellation, .canceled),
            (.capture(.displayChanged), .displayChanged),
            (.foreign(domain: NSCocoaErrorDomain, code: 4), .system(code: 4)),
        ])
    func errorMapping(failure: FakeFailure, expected: CaptureError) async throws {
        let (service, backend) = makeService()
        backend.update { $0.captureFailure = failure }
        await #expect(throws: expected) {
            _ = try await service.capture(
                .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        }
    }

    @Test("A permission failure while listing content is permissionDenied")
    func contentPermissionDenied() async throws {
        let (service, backend) = makeService()
        backend.update { $0.contentFailure = .streamError(-3801) }
        await #expect(throws: CaptureError.permissionDenied) { _ = try await service.windows() }
        await #expect(throws: CaptureError.permissionDenied) {
            _ = try await service.capture(
                .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        }
        #expect(backend.plans.isEmpty)
    }

    @Test(
        "Only one capture runs at a time; an overlapping request is rejected without queueing", .timeLimit(.minutes(1)))
    func oneRequestAtATime() async throws {
        let (service, backend) = makeService()
        backend.update { $0.gated = true }
        let first = Task {
            try await service.capture(
                .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        }
        var entered = backend.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        await #expect(throws: CaptureError.canceled) {
            _ = try await service.capture(
                .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        }
        backend.release.continuation.yield()
        let (_, geometry) = try await first.value
        #expect(geometry.source == .display(id: 1))
        #expect(backend.plans.count == 1)

        backend.update { $0.gated = false }
        _ = try await service.capture(
            .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        #expect(backend.plans.count == 2)
    }

    @Test("Cancelling the caller while SCK is working discards the image and reports canceled", .timeLimit(.minutes(1)))
    func cancellationDuringCapture() async throws {
        let (service, backend) = makeService()
        backend.update { $0.gated = true }
        let task = Task {
            try await service.capture(
                .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        }
        var entered = backend.entered.stream.makeAsyncIterator()
        _ = await entered.next()
        task.cancel()
        backend.release.continuation.yield()
        await #expect(throws: CaptureError.canceled) { _ = try await task.value }

        backend.update { $0.gated = false }
        _ = try await service.capture(
            .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
    }

    @Test("A request that is already cancelled never reaches ScreenCaptureKit")
    func cancelledBeforeStart() async throws {
        let (service, backend) = makeService()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.capture(
                .display(retina), showsCursor: false, includesShadow: true, excludingWindowNumbers: [])
        }
        await #expect(throws: CaptureError.canceled) { _ = try await task.value }
        #expect(backend.plans.isEmpty)
        #expect(backend.state.withLock { $0.contentCalls } == 0)
    }

    @Test("The window list keeps on-screen, normal-layer windows of other apps and assigns each a display")
    func windowListFiltering() async throws {
        let straddling = CGRect(x: -100, y: 100, width: 400, height: 300)
        let (service, _) = makeService(windows: [
            window(1),
            window(2, onScreen: false),
            window(3, layer: 25),
            window(4, pid: ownPID),
            window(5, frame: CGRect(x: 10, y: 10, width: 0, height: 50)),
            window(6, frame: straddling),
            window(7, frame: CGRect(x: -1800, y: -150, width: 300, height: 200)),
            window(8, frame: CGRect(x: 5000, y: 5000, width: 300, height: 200)),
        ])
        let windows = try await service.windows()
        #expect(windows.map(\.id) == [1, 6, 7])
        #expect(windows.map(\.displayID) == [1, 1, 2])
        #expect(windows[2].frame == Rect<DesktopSpace>(x: -1800, y: -150, width: 300, height: 200))
        #expect(windows[0].ownerPID == 900)
    }

    @Test("A cancelled window listing reports canceled")
    func windowsCancellation() async throws {
        let (service, _) = makeService(windows: [window(1)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.windows()
        }
        await #expect(throws: CaptureError.canceled) { _ = try await task.value }
    }
}
