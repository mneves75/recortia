import CoreGraphics
import CryptoKit
import Domain
import Foundation
import Imaging
import MacPlatform
import Testing

@testable import Features

// In-memory fakes for every Features service. They never touch the screen, the pasteboard,
// TCC, or the file system. Suspending fakes hand control to the test through `Pending`, so a
// test decides exactly when (and whether) a completion arrives: before or after a cancel.

// MARK: - Helpers

/// A value the test resolves later; each `wait()` suspends until `resolve` is called.
@MainActor
final class Pending<Value: Sendable> {
    private var waiters: [CheckedContinuation<Value, Never>] = []

    var waiterCount: Int { waiters.count }

    func wait() async -> Value {
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Resumes the oldest waiter; returns false when nobody is waiting.
    @discardableResult
    func resolve(_ value: Value) -> Bool {
        guard !waiters.isEmpty else { return false }
        waiters.removeFirst().resume(returning: value)
        return true
    }
}

@MainActor
func waitFor(
    _ description: String, limit: Int = 500, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<limit {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for: \(description)", sourceLocation: sourceLocation)
}

/// Lets queued main-actor work run without asserting anything.
@MainActor
func drain(_ turns: Int = 100) async {
    for _ in 0..<turns { await Task.yield() }
}

func makeImage(width: Int = 8, height: Int = 8) -> CGImage? {
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

enum TestFixtures {
    static let primaryDisplay = DisplayInfo(
        id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), pointPixelScale: 2, fingerprint: "1-1512x982@2")
    /// A 1x display placed to the left of and above the primary (negative desktop origin).
    static let leftDisplay = DisplayInfo(
        id: 2, frame: Rect(x: -1920, y: -200, width: 1920, height: 1080), pointPixelScale: 1,
        fingerprint: "2-1920x1080@1")
    static let window = WindowInfo(
        id: 42, ownerName: "Fixture", ownerPID: 1234, title: "Secret title",
        frame: Rect(x: 10, y: 10, width: 300, height: 200),
        displayID: 1)

    static func geometry(for target: CaptureTarget) -> CaptureGeometry {
        switch target {
        case .region(let rect, let display):
            CaptureGeometry(
                source: .region(displayID: display.id), desktopBounds: rect, pointPixelScale: display.pointPixelScale,
                pixelSize: PixelSize(
                    width: Int(rect.width * display.pointPixelScale), height: Int(rect.height * display.pointPixelScale)
                ),
                capturedAt: Date(timeIntervalSince1970: 0))
        case .display(let display):
            CaptureGeometry(
                source: .display(id: display.id), desktopBounds: display.frame,
                pointPixelScale: display.pointPixelScale,
                pixelSize: PixelSize(width: 10, height: 10), capturedAt: Date(timeIntervalSince1970: 0))
        case .window(let window):
            CaptureGeometry(
                source: .window(id: window.id, displayID: window.displayID), desktopBounds: window.frame,
                pointPixelScale: 2,
                pixelSize: PixelSize(width: 10, height: 10), capturedAt: Date(timeIntervalSince1970: 0))
        }
    }

    static func session(width: Int = 8, height: Int = 8) -> DocumentSession {
        let asset = ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: width, height: height), origin: .imported)
        return DocumentSession(document: Document(asset: asset))
    }
}

// MARK: - Clock

@MainActor
final class ManualClock: FeatureClock {
    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var current = Date(timeIntervalSince1970: 1_000_000)
    private var sleepers: [Sleeper] = []
    private(set) var sleepRequests: [Duration] = []

    var pendingSleepCount: Int { sleepers.count }

    func now() -> Date { current }

    func sleep(for duration: Duration) async throws {
        sleepRequests.append(duration)
        let id = UUID()
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let deadline = current.addingTimeInterval(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    func advance(bySeconds seconds: Double) {
        current = current.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

// MARK: - Capture and permissions

@MainActor
final class FakeCaptureService: CaptureService {
    var displayList: [DisplayInfo] = [TestFixtures.primaryDisplay]
    var windowResult: Result<[WindowInfo], CaptureError> = .success([TestFixtures.window])
    /// When set, `capture` suspends until the test resolves it; otherwise it succeeds immediately.
    var pendingCapture: Pending<Result<(CGImage, CaptureGeometry), CaptureError>>?
    var immediateCaptureError: CaptureError?

    private(set) var captureCalls: [CaptureTarget] = []
    private(set) var lastOptions: (showsCursor: Bool, includesShadow: Bool)?
    private(set) var activeCaptures = 0
    private(set) var maxConcurrentCaptures = 0
    private(set) var windowCalls = 0

    func displays() -> [DisplayInfo] { displayList }

    func windows() async throws(CaptureError) -> [WindowInfo] {
        windowCalls += 1
        return try windowResult.get()
    }

    func capture(_ target: CaptureTarget, showsCursor: Bool, includesShadow: Bool) async throws(CaptureError)
        -> (CGImage, CaptureGeometry)
    {
        captureCalls.append(target)
        lastOptions = (showsCursor, includesShadow)
        activeCaptures += 1
        maxConcurrentCaptures = max(maxConcurrentCaptures, activeCaptures)
        defer { activeCaptures -= 1 }
        if let pendingCapture {
            return try await pendingCapture.wait().get()
        }
        if let immediateCaptureError { throw immediateCaptureError }
        guard let image = makeImage() else { throw .system(code: -99) }
        return (image, TestFixtures.geometry(for: target))
    }
}

@MainActor
final class FakeScreenPermission: ScreenPermissionService {
    var isGranted: Bool
    /// When set, `request` suspends until resolved; otherwise it answers `grantOnRequest`.
    var pendingRequest: Pending<Bool>?
    var grantOnRequest = false
    private(set) var requestCount = 0

    init(isGranted: Bool = true) {
        self.isGranted = isGranted
    }

    func request() async -> Bool {
        requestCount += 1
        let granted: Bool
        if let pendingRequest {
            granted = await pendingRequest.wait()
        } else {
            granted = grantOnRequest
        }
        if granted { isGranted = true }
        return granted
    }
}

@MainActor
final class FakeAccessibilityPermission: AccessibilityPermissionService {
    var isTrusted: Bool
    private(set) var promptCount = 0

    init(isTrusted: Bool = false) {
        self.isTrusted = isTrusted
    }

    func requestWithPrompt() { promptCount += 1 }
}

// MARK: - Assets and input

@MainActor
final class FakeAssetService: ImageAssetService {
    var importError: ImportError?
    private(set) var imported: [(byteCount: Int, origin: AssetOrigin)] = []
    private(set) var registeredCaptures: [ImageAssetInfo] = []
    private(set) var registeredStitched: [ImageAssetInfo] = []
    private(set) var released: [AssetID] = []

    func importImage(_ data: Data, origin: AssetOrigin) async throws(ImportError) -> ImageAssetInfo {
        if let importError { throw importError }
        imported.append((data.count, origin))
        return ImageAssetInfo(id: AssetID(), pixelSize: PixelSize(width: 16, height: 9), origin: origin)
    }

    func registerCapture(_ image: CGImage, geometry: CaptureGeometry) async throws(ImportError) -> ImageAssetInfo {
        let info = ImageAssetInfo(
            id: AssetID(), pixelSize: PixelSize(width: image.width, height: image.height), origin: .captured(geometry))
        registeredCaptures.append(info)
        return info
    }

    func registerStitched(_ image: CGImage, partialReason: ScrollPartialReason?) async throws(ImportError)
        -> ImageAssetInfo
    {
        let info = ImageAssetInfo(
            id: AssetID(), pixelSize: PixelSize(width: image.width, height: image.height),
            origin: .scrollCapture(partialReason: partialReason))
        registeredStitched.append(info)
        return info
    }

    func release(_ id: AssetID) { released.append(id) }
}

@MainActor
final class FakeImageInput: ImageInputService {
    var files: [URL: Result<Data, ImportError>] = [:]
    var pasteboardData: Data?
    private(set) var pasteboardReads = 0
    private(set) var fileReads: [URL] = []

    func readFile(at url: URL) async throws(ImportError) -> Data {
        fileReads.append(url)
        guard let result = files[url] else { throw .unreadable }
        return try result.get()
    }

    func readPasteboardImage() -> Data? {
        pasteboardReads += 1
        return pasteboardData
    }
}

// MARK: - Render and export

@MainActor
final class FakeRenderService: RenderService {
    var pending: Pending<Result<CGImage, ExportServiceError>>?
    var shouldFail = false
    private(set) var renderCount = 0

    func render(_ document: Document, scale: Double) async throws -> CGImage {
        renderCount += 1
        if let pending { return try await pending.wait().get() }
        if shouldFail { throw ExportServiceError(.renderFailed) }
        guard let image = makeImage() else { throw ExportServiceError(.renderFailed) }
        return image
    }

    func renderBase(_ document: Document, scale: Double) async throws -> CGImage {
        try await render(document, scale: scale)
    }
}

@MainActor
final class FakeExportService: ExportService {
    var pending: Pending<Result<Void, ExportServiceError>>?
    var failure: ExportFailure?
    private(set) var snapshotCount = 0

    func makeSnapshot(of session: DocumentSession, options: ExportOptions, date: Date) async throws(ExportServiceError)
        -> ShareSnapshot
    {
        snapshotCount += 1
        if let pending { try await pending.wait().get() }
        if let failure { throw ExportServiceError(failure) }
        return ShareSnapshot(
            documentID: session.document.id, revision: session.revision, privacyEpoch: session.privacyEpoch,
            format: options.format, pixelSize: PixelSize(width: 8, height: 8), bytes: Data([0x89, 0x50]),
            suggestedFilename: ExportFilename.make(for: date, format: options.format, timeZone: .gmt))
    }
}

@MainActor
final class FakeClipboard: ClipboardSinkService {
    var error: SinkError?
    private(set) var writes: [ShareSnapshot] = []

    func write(_ snapshot: ShareSnapshot) throws(SinkError) {
        if let error { throw error }
        writes.append(snapshot)
    }
}

@MainActor
final class FakeFileSink: FileSinkService {
    var error: SinkError?
    var pending: Pending<Void>?
    private(set) var saves: [(snapshot: ShareSnapshot, url: URL, overwrite: Bool)] = []
    private(set) var uniqueSaves: [(snapshot: ShareSnapshot, folder: URL)] = []

    func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) async throws(SinkError) -> URL {
        if let pending { await pending.wait() }
        if let error { throw error }
        saves.append((snapshot, url, overwrite))
        return url
    }

    func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) async throws(SinkError) -> URL {
        if let pending { await pending.wait() }
        if let error { throw error }
        uniqueSaves.append((snapshot, folder))
        return folder.appendingPathComponent(snapshot.suggestedFilename)
    }
}

@MainActor
final class FakeDragSink: DragSinkService {
    var outcome: Result<DragDeliveryOutcome, SinkError> = .success(.delivered)
    /// When set, `deliver` waits here, like the live chip waiting for the user to drag.
    var pending: Pending<DragDeliveryOutcome>?
    private(set) var deliveries: [ShareSnapshot] = []
    private(set) var leases: [ExportLease] = []
    private(set) var dismissCount = 0
    /// Bytes a receiver actually got: the live file promise writes only while the lease holds.
    private(set) var writtenSnapshots: [ShareSnapshot] = []
    /// False models a receiver that accepted the drop but has not asked for the file yet.
    var commitOnDelivery = true

    func deliver(_ snapshot: ShareSnapshot, lease: ExportLease) async throws(SinkError) -> DragDeliveryOutcome {
        deliveries.append(snapshot)
        leases.append(lease)
        let result: DragDeliveryOutcome
        if let pending {
            result = await pending.wait()
        } else {
            result = try outcome.get()
        }
        // The live file promise writes under the lease, which commits it.
        if result == .delivered, commitOnDelivery { _ = lease.whileValid { writtenSnapshots.append(snapshot) } }
        return result
    }

    func dismiss() {
        dismissCount += 1
        pending?.resolve(.canceledByUser)
    }
}

@MainActor
final class FakeSaveFolders: SaveFolderService {
    var folder: URL?
    func resolveFolder(bookmark: Data) -> URL? { folder }
}

// MARK: - OCR

@MainActor
final class FakeTextRecognition: TextRecognitionService {
    var languages: [Locale.Language] = [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "pt-BR")]

    func supportedLanguages() async -> [Locale.Language] { languages }

    func recognize(_ image: CGImage, languages: [Locale.Language]) async throws -> OCRResult {
        OCRResult(lines: [], revision: 3, languages: languages.map(\.minimalIdentifier))
    }
}

// MARK: - Scrolling

@MainActor
final class FakeFrameSource: ScrollFrameSourceService {
    var startError: CaptureError?
    let frames = Pending<Result<CGImage, CaptureError>>()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var stopped = false

    /// When set, each `start` suspends until `starts.resolve(())`, like a stream that takes time to open.
    var holdStarts = false
    let starts = Pending<Void>()

    func start(_ target: CaptureTarget) async throws(CaptureError) {
        startCount += 1
        stopped = false
        if holdStarts { await starts.wait() }
        if let startError { throw startError }
    }

    func nextFrame() async throws(CaptureError) -> CGImage {
        let result = await frames.wait()
        return try result.get()
    }

    func stop() {
        stopCount += 1
        stopped = true
        // A real stream resumes any waiter with `.canceled`; resolve all outstanding waits.
        while frames.resolve(.failure(.canceled)) {}
    }

    /// Delivers one frame to the model's pending `nextFrame()` call.
    @discardableResult
    func deliver(width: Int = 8, height: Int = 8) -> Bool {
        guard let image = makeImage(width: width, height: height) else { return false }
        return frames.resolve(.success(image))
    }
}

@MainActor
final class FakeStitcher: ScrollStitchService {
    /// Results handed out in order for each `append`; `.accepted(offset: 0)` when exhausted.
    var script: [ScrollAppendResult] = []
    var frameHeight = 100
    var assembleFails = false
    private(set) var appendCount = 0
    private(set) var lastElapsed: Duration?
    private(set) var resetCount = 0
    private(set) var acceptedFrameCount = 0
    private(set) var outputSize = PixelSize(width: 0, height: 0)
    /// Mirrors `ScrollStitcher`: the page ends after this many consecutive stationary frames.
    var stationaryFramesForEnd = ScrollStitcher.endOfPageStationaryFrames
    private(set) var consecutiveStationary = 0

    var endOfPageDetected: Bool { acceptedFrameCount > 0 && consecutiveStationary >= stationaryFramesForEnd }

    func reset() {
        resetCount += 1
        acceptedFrameCount = 0
        consecutiveStationary = 0
        outputSize = PixelSize(width: 0, height: 0)
    }

    /// When set, each `append` suspends until `appends.resolve(())`, like a slow stitch.
    var holdAppends = false
    let appends = Pending<Void>()

    func append(_ frame: CGImage, elapsed: Duration) async -> ScrollAppendResult {
        if holdAppends { await appends.wait() }
        appendCount += 1
        lastElapsed = elapsed
        let result = script.isEmpty ? .accepted(offset: 40) : script.removeFirst()
        switch result {
        case .accepted(let offset):
            acceptedFrameCount += 1
            consecutiveStationary = 0
            let added = outputSize.height == 0 ? frameHeight : offset
            outputSize = PixelSize(width: frame.width, height: outputSize.height + added)
        case .stationary:
            consecutiveStationary += 1
        case .ambiguous:
            consecutiveStationary = 0
        case .limitReached:
            break
        }
        return result
    }

    func preview(maxHeight: Int) async -> CGImage? {
        acceptedFrameCount > 0 ? makeImage(width: 4, height: 8) : nil
    }

    func assemble() async throws -> CGImage {
        if assembleFails { throw ExportServiceError(.budgetExceeded) }
        guard let image = makeImage(width: max(1, outputSize.width), height: max(1, outputSize.height)) else {
            throw ExportServiceError(.renderFailed)
        }
        return image
    }
}

@MainActor
final class FakeAutoScroller: AutoScrollService {
    var steps: [AutoScrollStep] = []
    private(set) var stepCount = 0
    private(set) var stopCount = 0

    func step(_ target: CaptureTarget) async -> AutoScrollStep {
        stepCount += 1
        return steps.isEmpty ? .scrolled : steps.removeFirst()
    }

    func stop() { stopCount += 1 }

    /// What the target reports about its scroll position; nil when it cannot tell.
    var atEnd: Bool?
    func isAtEnd(_ target: CaptureTarget) async -> Bool? { atEnd }
}

// MARK: - System

@MainActor
final class FakeLoginItem: LoginItemService {
    var isEnabled = false
    var error: (any Error)?

    func setEnabled(_ enabled: Bool) throws {
        if let error { throw error }
        isEnabled = enabled
    }
}

@MainActor
/// HMAC-SHA256 under a fixed test key, so stores reloaded in one test verify each other's seals.
final class FixedKeyPreferenceIntegrity: PreferenceIntegrityService {
    private let key: SymmetricKey
    private let available: Bool

    init(key: Data = Data(repeating: 7, count: 32), available: Bool = true) {
        self.key = SymmetricKey(data: key)
        self.available = available
    }

    func seal(_ data: Data) -> Data? {
        guard available else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    func verify(_ data: Data, seal: Data) -> Bool {
        available && HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: data, using: key)
    }
}

extension SettingsStore {
    convenience init(storage: any PreferenceStorage) {
        self.init(storage: storage, integrity: FixedKeyPreferenceIntegrity())
    }
}

final class MemoryPreferenceStorage: PreferenceStorage {
    var values: [String: Data] = [:]
    private(set) var writeCount = 0

    func preferenceData(forKey key: String) -> Data? { values[key] }

    func setPreferenceData(_ data: Data?, forKey key: String) {
        writeCount += 1
        values[key] = data
    }
}

@MainActor
final class FakeShortcutProbe: ShortcutRegistrationProbe {
    var failing: Set<String> = []
    func canRegister(shortcutNamed name: String) -> Bool { !failing.contains(name) }
}

struct TestError: Error {}

/// A mutable, main-actor home for a session that a test edits while an operation is in flight.
@MainActor
final class SessionBox {
    var session: DocumentSession

    init(_ session: DocumentSession) {
        self.session = session
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
