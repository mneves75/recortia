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
    public private(set) var isImporting = false
    public private(set) var lastFailure: ImportFailure?
    @ObservationIgnored public var onImported: ((DocumentSession) -> Void)?

    @ObservationIgnored private let input: any ImageInputService
    @ObservationIgnored private let assets: any ImageAssetService

    public init(input: any ImageInputService, assets: any ImageAssetService) {
        self.input = input
        self.assets = assets
    }

    @discardableResult
    public func importImage(from source: ImportSource) async -> Result<DocumentSession, ImportFailure> {
        isImporting = true
        defer { isImporting = false }
        let result = await load(source)
        switch result {
        case .success(let session):
            lastFailure = nil
            onImported?(session)
        case .failure(let failure):
            lastFailure = failure
        }
        return result
    }

    public func clearFailure() { lastFailure = nil }

    private func load(_ source: ImportSource) async -> Result<DocumentSession, ImportFailure> {
        let data: Data
        let origin: AssetOrigin
        do throws(ImportError) {
            switch source {
            case .file(let url), .droppedFile(let url):
                data = try await input.readFile(at: url)
                origin = .imported
            case .pasteboard:
                guard let pasted = input.readPasteboardImage() else { return .failure(.nothingToPaste) }
                data = pasted
                origin = .pasted
            case .droppedData(let dropped):
                data = dropped
                origin = .imported
            }
            let info = try await assets.importImage(data, origin: origin)
            return .success(DocumentSession(document: Document(asset: info)))
        } catch {
            return .failure(ImportFailure(error))
        }
    }
}
