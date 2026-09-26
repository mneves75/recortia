import AppKit
import Domain
import Features
import Imaging
import MacPlatform

// Live adapters from the Features service protocols to the Imaging and MacPlatform
// implementations. Heavy work (decode, render, encode, file I/O, capture) runs off the main
// actor inside the adapted types or in the `@concurrent` helpers below.

// MARK: - Capture and permissions

final class LiveCaptureService: CaptureService {
    private let service = ScreenCaptureService()

    func displays() -> [DisplayInfo] { DesktopGeometry.displays() }

    func windows() async throws(CaptureError) -> [WindowInfo] {
        try await service.windows()
    }

    func capture(_ target: CaptureTarget, showsCursor: Bool, includesShadow: Bool) async throws(CaptureError)
        -> (CGImage, CaptureGeometry)
    {
        // Framepin's own windows are always excluded by the service.
        try await service.capture(
            target, showsCursor: showsCursor, includesShadow: includesShadow, excludingWindowNumbers: [])
    }
}

final class LiveScreenPermission: ScreenPermissionService {
    var isGranted: Bool { ScreenPermission.isGranted }

    func request() async -> Bool { ScreenPermission.request() }
}

final class LiveAccessibilityPermission: AccessibilityPermissionService {
    var isTrusted: Bool { AccessibilityPermission.isTrusted }

    func requestWithPrompt() { AccessibilityPermission.requestWithPrompt() }
}

// MARK: - Assets, input, render, export

final class LiveImageAssets: ImageAssetService {
    let store: ImageStore

    init(store: ImageStore) {
        self.store = store
    }

    func importImage(_ data: Data, origin: AssetOrigin) async throws(ImportError) -> ImageAssetInfo {
        let decoded = try await Self.decode(data)
        return await store.insert(decoded, origin: origin)
    }

    func registerCapture(_ image: CGImage, geometry: CaptureGeometry) async throws(ImportError) -> ImageAssetInfo {
        let decoded = try await Self.canonicalize(image)
        return await store.insert(decoded, origin: .captured(geometry))
    }

    func registerStitched(_ image: CGImage, partialReason: String?) async throws(ImportError) -> ImageAssetInfo {
        let decoded = try await Self.canonicalize(image)
        return await store.insert(decoded, origin: .scrollCapture(partialReason: partialReason))
    }

    func release(_ id: AssetID) {
        Task { await store.remove(id) }
    }

    @concurrent private static func decode(_ data: Data) async throws(ImportError) -> DecodedImage {
        try ImageDecoder.decode(data)
    }

    @concurrent private static func canonicalize(_ image: CGImage) async throws(ImportError) -> DecodedImage {
        try ImageDecoder.canonicalize(image)
    }
}

final class LiveImageInput: ImageInputService {
    func readFile(at url: URL) async throws(ImportError) -> Data {
        try await Self.read(url)
    }

    func readPasteboardImage() -> Data? { ImageInput.readPasteboard(.general) }

    @concurrent private static func read(_ url: URL) async throws(ImportError) -> Data {
        try ImageInput.readFile(at: url)
    }
}

final class LiveRenderer: RenderService {
    private let renderer: PrivacyRenderer

    init(store: ImageStore) {
        renderer = PrivacyRenderer(store: store)
    }

    func render(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.render(document, scale: scale)
    }

    func renderBase(_ document: Document, scale: Double) async throws -> CGImage {
        try await renderer.renderBase(document, scale: scale)
    }
}

final class LiveExporter: ExportService {
    private let pipeline: ExportPipeline

    init(store: ImageStore) {
        pipeline = ExportPipeline(renderer: PrivacyRenderer(store: store))
    }

    func makeSnapshot(of session: DocumentSession, options: ExportOptions, date: Date) async throws(ExportServiceError)
        -> ShareSnapshot
    {
        do {
            return try await pipeline.snapshot(of: session, options: options, date: date)
        } catch {
            throw ExportServiceError(Self.failure(for: error))
        }
    }

    static func failure(for error: ExportError) -> ExportFailure {
        switch error {
        case .encodingFailed: .encodeFailed
        case .render(.budgetExceeded): .budgetExceeded
        case .render, .invalidOptions: .renderFailed
        }
    }
}

// MARK: - Sinks

final class LiveClipboard: ClipboardSinkService {
    func write(_ snapshot: ShareSnapshot) throws(SinkError) {
        try ClipboardSink(pasteboard: .general).write(snapshot)
    }
}

final class LiveFiles: FileSinkService {
    func save(_ snapshot: ShareSnapshot, to url: URL, overwrite: Bool) async throws(SinkError) -> URL {
        try await Self.save(snapshot, url, overwrite)
    }

    func saveUnique(_ snapshot: ShareSnapshot, in folder: URL) async throws(SinkError) -> URL {
        try await Self.saveUnique(snapshot, folder)
    }

    @concurrent private static func save(_ snapshot: ShareSnapshot, _ url: URL, _ overwrite: Bool)
        async throws(SinkError) -> URL
    {
        try FileSink().save(snapshot, to: url, overwrite: overwrite)
    }

    @concurrent private static func saveUnique(_ snapshot: ShareSnapshot, _ folder: URL) async throws(SinkError)
        -> URL
    {
        try FileSink().saveUnique(snapshot, in: folder)
    }
}

final class LiveSaveFolders: SaveFolderService {
    func resolveFolder(bookmark: Data) -> URL? {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
            !stale
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return url
    }
}

// MARK: - System

final class LiveLoginItem: LoginItemService {
    var isEnabled: Bool { LoginItem.isEnabled }

    func setEnabled(_ enabled: Bool) throws { try LoginItem.set(enabled) }
}
