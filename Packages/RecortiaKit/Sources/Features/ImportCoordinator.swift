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
    @ObservationIgnored public var onImported: ((DocumentSession, _ fileName: String?) -> Void)?

    public init(input: any ImageInputService, assets: any ImageAssetService) {
        imageImporter = ImageImporter(input: input, assets: assets)
    }

    @discardableResult
    public func importImage(from source: ImportSource) async -> Result<DocumentSession, ImportFailure> {
        do throws(ImportFailure) {
            let admission = try imageImporter.admit { source }
            let info = try await imageImporter.importImage(admission)
            let session = DocumentSession(document: Document(asset: info))
            lastFailure = nil
            onImported?(session, admission.fileName)
            return .success(session)
        } catch {
            lastFailure = error
            return .failure(error)
        }
    }

    func clearFailure() { lastFailure = nil }
}

/// An import admitted into the shared slot, with the source it read. It holds the slot until it is
/// imported or released.
public struct ImportAdmission: Sendable {
    public let source: ImportSource
    let fileName: String?
}

/// One read/decode admission slot, shared by the app's new-document and editor-layer paths.
/// Rejection is synchronous before any byte read; no queue retains waiting image payloads.
@MainActor
@Observable
public final class ImageImporter {
    public private(set) var isImporting = false
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
        guard !isImporting else { throw .busy }
        isImporting = true
        do throws(ImportFailure) {
            let source = try readSource()
            let fileName: String? =
                switch source {
                case .file(let url), .droppedFile(let url): url.lastPathComponent
                case .pasteboard, .droppedData: nil
                }
            return ImportAdmission(source: source, fileName: fileName)
        } catch {
            isImporting = false
            throw error
        }
    }

    /// Releases an admission that will not be imported (its editor closed first).
    public func release(_ admission: ImportAdmission) {
        isImporting = false
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

    /// Reads and decodes an admitted source, then frees the slot.
    public func importImage(_ admission: ImportAdmission) async throws(ImportFailure) -> ImageAssetInfo {
        // Cancellation does not free the slot while a reader or decoder still owns its buffers.
        defer { isImporting = false }
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
}
