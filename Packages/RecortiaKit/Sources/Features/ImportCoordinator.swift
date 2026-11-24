import Domain
import Foundation
import Imaging
import Observation

public enum ImportSource: Hashable, Sendable {
    case file(URL)
    /// Explicit Paste; the only path that reads the clipboard (FR-03, no polling).
    case pasteboard
    case droppedFile(URL)
    case droppedData(Data)
}

/// User-presentable import failures (IO-01).
public enum ImportFailure: Error, Hashable, Sendable {
    case busy
    case cancelled
    case nothingToPaste
    case tooLarge
    case tooManyPixels
    case invalidDimensions
    case unsupportedFormat
    case multipleFrames
    case corrupt
    case unreadable
    /// Beyond `ImportCoordinator.maximumOpenedFiles` in one request from the system (never read),
    /// or beyond what is left of its `ImportLimits.maxOpenedPixelArea` (never decoded).
    case tooManyFiles

    init(_ error: ImportError) {
        switch error {
        case .tooManyBytes: self = .tooLarge
        case .tooManyPixels: self = .tooManyPixels
        case .invalidDimensions: self = .invalidDimensions
        case .unsupportedFormat: self = .unsupportedFormat
        case .multiFrame: self = .multipleFrames
        case .corrupt: self = .corrupt
        case .unreadable: self = .unreadable
        }
    }
}

/// Open, Paste, and Drop → bounded read → decode → new document session. Needs no screen access.
@MainActor
@Observable
public final class ImportCoordinator {
    public var isImporting: Bool { imageImporter.isImporting }
    public let imageImporter: ImageImporter
    private(set) var lastFailure: ImportFailure?
    /// Receives each new document, its file name, and whether its e-mail addresses and phone
    /// numbers are to be masked before it is shown (FR-06), read once when the document is created.
    @ObservationIgnored public var onImported:
        ((DocumentSession, _ fileName: String?, _ masksSensitiveText: Bool) -> Void)?
    @ObservationIgnored private let settings: SettingsStore

    public init(input: any ImageInputService, assets: any ImageAssetService, settings: SettingsStore) {
        imageImporter = ImageImporter(input: input, assets: assets)
        self.settings = settings
    }

    @discardableResult
    public func importImage(from source: ImportSource) async -> Result<DocumentSession, ImportFailure> {
        await importImage(from: source, pixelBudget: nil).map(\.session)
    }

    private func importImage(from source: ImportSource, pixelBudget: Int?) async
        -> Result<(session: DocumentSession, pixelArea: Int), ImportFailure>
    {
        do throws(ImportFailure) {
            let admission = try imageImporter.admit { source }
            let info = try await imageImporter.importImage(admission, pixelBudget: pixelBudget)
            let session = DocumentSession(document: Document(asset: info))
            lastFailure = nil
            onImported?(session, admission.fileName, settings.preferences.autoRedactsSensitiveText)
            return .success((session, info.pixelSize.checkedArea ?? Int.max))
        } catch {
            lastFailure = error
            return .failure(error)
        }
    }

    /// The most files one Open With, Dock-icon drop or `open -a` request opens: each is a decoded
    /// image in its own editor.
    public static let maximumOpenedFiles = 10

    /// Opens files handed over by the system, one editor each, through the same admission as
    /// File › Open. Files are imported one after another so the shared slot admits each in turn;
    /// a refused file does not stop the rest, and together they hold at most
    /// `ImportLimits.maxOpenedPixelArea` decoded pixels. Returns the refusals, in order, for one report.
    public func openFiles(_ urls: [URL]) async -> [ImportFailure] {
        var failures: [ImportFailure] = []
        var pixelsLeft = ImportLimits.maxOpenedPixelArea
        for url in urls.prefix(Self.maximumOpenedFiles) {
            switch await importImage(from: .file(url), pixelBudget: pixelsLeft) {
            case .success(let opened): pixelsLeft -= min(opened.pixelArea, pixelsLeft)
            case .failure(let failure): failures.append(failure)
            }
        }
        failures += repeatElement(.tooManyFiles, count: max(0, urls.count - Self.maximumOpenedFiles))
        return failures
    }

    /// Opens requests that queued up (before launch wired the editors) one after another, each
    /// with its own limit, and returns each request's refusals for its own report.
    public func openRequests(_ requests: [[URL]]) async -> [[ImportFailure]] {
        var failures: [[ImportFailure]] = []
        for urls in requests { failures.append(await openFiles(urls)) }
        return failures
    }
}

/// An import admitted into the shared slot, with the source it read. It holds the slot until its
/// matching `id` is imported or released.
public struct ImportAdmission: Sendable {
    public let source: ImportSource
    let fileName: String?
    let id: UUID
}

/// One read/decode admission slot, shared by the app's new-document and editor-layer paths.
/// Rejection is synchronous before any byte read; no queue retains waiting image payloads.
@MainActor
@Observable
public final class ImageImporter {
    private enum SlotState: Equatable {
        case idle
        case admitted(UUID)
        case importing(UUID)
    }

    private var slot: SlotState = .idle
    public var isImporting: Bool { slot != .idle }
    @ObservationIgnored private let input: any ImageInputService
    @ObservationIgnored private let assets: any ImageAssetService

    public init(input: any ImageInputService, assets: any ImageAssetService) {
        self.input = input
        self.assets = assets
    }

    /// Takes the slot, then calls `readSource`: a busy importer rejects without reading. Called on
    /// the main actor while a drop is performed, so a drag pasteboard is read while it is valid.
    /// The admission holds the slot until `importImage(_:)` or `release(_:)`.
    func admit(readSource: () throws(ImportFailure) -> ImportSource) throws(ImportFailure) -> ImportAdmission {
        guard !Task.isCancelled else { throw .cancelled }
        guard slot == .idle else { throw .busy }
        let id = UUID()
        slot = .admitted(id)
        do throws(ImportFailure) {
            let source = try readSource()
            let fileName: String? =
                switch source {
                case .file(let url), .droppedFile(let url): url.lastPathComponent
                case .pasteboard, .droppedData: nil
                }
            return ImportAdmission(source: source, fileName: fileName, id: id)
        } catch {
            if slot == .admitted(id) { slot = .idle }
            throw error
        }
    }

    /// Releases an unused admission that will not be imported (its editor closed first).
    /// Only the active unused admission's identity can release the slot.
    public func release(_ admission: ImportAdmission) {
        guard slot == .admitted(admission.id) else { return }
        slot = .idle
    }

    public func importImage(from source: ImportSource) async throws(ImportFailure) -> ImageAssetInfo {
        try await importImage(admit(readSource: { source }))
    }

    /// Acquires a lazy drag provider only after admission, before it can materialize image bytes.
    public func importImage(readSource: () throws(ImportFailure) -> ImportSource) async throws(ImportFailure)
        -> ImageAssetInfo
    {
        try await importImage(admit(readSource: readSource))
    }

    /// Reads and decodes an admitted source, then frees the slot. With a `pixelBudget`, a source
    /// that declares more pixels is refused as `.tooManyFiles` before the decoder allocates.
    public func importImage(_ admission: ImportAdmission, pixelBudget: Int? = nil) async throws(ImportFailure)
        -> ImageAssetInfo
    {
        guard slot == .admitted(admission.id) else {
            throw slot == .idle ? .cancelled : .busy
        }
        slot = .importing(admission.id)
        // Cancellation does not free the slot while a reader or decoder still owns its buffers.
        defer {
            if slot == .importing(admission.id) { slot = .idle }
        }
        guard !Task.isCancelled else { throw .cancelled }
        let data: Data
        let origin: AssetOrigin
        switch admission.source {
        case .file(let url), .droppedFile(let url):
            do throws(ImportError) {
                data = try await input.readFile(at: url)
            } catch {
                throw Task.isCancelled ? .cancelled : ImportFailure(error)
            }
            origin = .imported
        case .pasteboard:
            guard let pasted = input.readPasteboardImage() else { throw .nothingToPaste }
            data = pasted
            origin = .pasted
        case .droppedData(let dropped):
            data = dropped
            origin = .imported
        }
        if let pixelBudget {
            let size: PixelSize
            do throws(ImportError) {
                size = try await Self.declaredSize(data)
            } catch {
                throw Task.isCancelled ? .cancelled : ImportFailure(error)
            }
            guard let area = size.checkedArea, area <= pixelBudget else { throw .tooManyFiles }
        }
        guard !Task.isCancelled else { throw .cancelled }
        let info: ImageAssetInfo
        do throws(ImportError) {
            info = try await assets.importImage(data, origin: origin)
        } catch {
            throw Task.isCancelled ? .cancelled : ImportFailure(error)
        }
        guard !Task.isCancelled else {
            assets.release(info.id)
            throw .cancelled
        }
        return info
    }

    @concurrent private static func declaredSize(_ data: Data) async throws(ImportError) -> PixelSize {
        try ImageHeader.pixelSize(data)
    }
}
