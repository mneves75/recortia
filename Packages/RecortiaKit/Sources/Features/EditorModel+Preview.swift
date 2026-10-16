import CoreGraphics
import Domain
import Foundation

/// The document fields `renderBase` reads, plus the privacy epoch. Annotations, callouts, crop,
/// resize, and presentation are drawn live by the canvas and never re-render the base.
struct BaseKey: Equatable {
    let documentID: DocumentID
    let privacyEpoch: UInt64
    let assets: [AssetID: ImageAssetInfo]
    let canvasSize: Size<DocumentSpace>
    let layers: [ImageLayer]
    let masks: [SecureMask]
    let obfuscations: [CosmeticObfuscation]
}

/// The whole document plus the privacy epoch, for the full output preview.
struct OutputKey: Equatable {
    let document: Document
    let privacyEpoch: UInt64
}

// Sanitized preview pipeline (FR-04, RED-03). At most one render of each kind runs at a time; a
// change during a render queues exactly one follow-up for the latest state.
//
// Acceptance: a finished render is installed when `DocumentSession.accepts` its identity, or when
// every field it read is unchanged (same document, privacy epoch, layers, masks, and effects), so
// annotation edits during a render do not starve the preview. A privacy-epoch change always
// rejects it: a base rendered before a mask change can never be shown (RED-03).
extension EditorModel {
    var currentBaseKey: BaseKey {
        let d = session.document
        return BaseKey(
            documentID: d.id, privacyEpoch: session.privacyEpoch, assets: d.assets, canvasSize: d.canvasSize,
            layers: d.layers, masks: d.masks, obfuscations: d.obfuscations)
    }

    var currentOutputKey: OutputKey { OutputKey(document: session.document, privacyEpoch: session.privacyEpoch) }

    /// True when the installed base shows exactly the current layers, masks, and effects. Pixel
    /// tools sample only a current base.
    public var isBaseCurrent: Bool { baseImage != nil && installedBaseKey == currentBaseKey }

    /// The base for magnifier previews: only one rendered for the current privacy epoch.
    public var calloutBaseImage: CGImage? {
        guard let key = installedBaseKey, key.documentID == session.document.id,
            key.privacyEpoch == session.privacyEpoch
        else { return nil }
        return baseImage
    }

    /// True when the output preview matches the current document.
    public var isOutputPreviewCurrent: Bool { outputPreview != nil && installedOutputKey == currentOutputKey }

    func scheduleBaseRender() {
        guard !isClosed, baseTask == nil else { return }
        let key = currentBaseKey
        guard key != installedBaseKey, key != failedBaseKey else { return }
        let identity = session.requestIdentity()
        let document = session.document
        let renderer = environment.renderer
        baseTask = Task { [weak self] in
            let result: Result<CGImage, any Error>
            do {
                result = .success(try await renderer.renderBase(document, scale: 1))
            } catch {
                result = .failure(error)
            }
            self?.finishBaseRender(result, identity: identity, key: key)
        }
    }

    private func finishBaseRender(_ result: Result<CGImage, any Error>, identity: RequestIdentity, key: BaseKey) {
        baseTask = nil
        guard !isClosed else { return }
        if session.accepts(identity) || key == currentBaseKey {
            switch result {
            case .success(let image):
                baseImage = image
                installedBaseKey = key
                failedBaseKey = nil
            case .failure:
                failedBaseKey = key
                post(.previewFailed)
            }
        } else {
            droppedResultCount += 1
        }
        scheduleBaseRender()
    }

    /// Shows the full sanitized output (crop, presentation, callouts) instead of the editing surface.
    public func setShowsOutputPreview(_ shows: Bool) {
        showsOutputPreview = shows
        if shows {
            scheduleOutputRender()
        } else {
            outputTask?.cancel()
            outputPreview = nil
            installedOutputKey = nil
            failedOutputKey = nil
        }
    }

    func scheduleOutputRender() {
        guard !isClosed, showsOutputPreview, outputTask == nil else { return }
        let key = currentOutputKey
        guard key != installedOutputKey, key != failedOutputKey else { return }
        let identity = session.requestIdentity()
        let renderer = environment.renderer
        outputTask = Task { [weak self] in
            let result: Result<CGImage, any Error>
            do {
                result = .success(try await renderer.render(key.document, scale: 1))
            } catch {
                result = .failure(error)
            }
            self?.finishOutputRender(result, identity: identity, key: key)
        }
    }

    private func finishOutputRender(_ result: Result<CGImage, any Error>, identity: RequestIdentity, key: OutputKey) {
        outputTask = nil
        guard !isClosed, showsOutputPreview else { return }
        guard !Task.isCancelled else {
            scheduleOutputRender()
            return
        }
        if session.accepts(identity) || key == currentOutputKey {
            switch result {
            case .success(let image):
                outputPreview = image
                installedOutputKey = key
                failedOutputKey = nil
            case .failure:
                failedOutputKey = key
                post(.previewFailed)
            }
        } else {
            droppedResultCount += 1
        }
        scheduleOutputRender()
    }

    /// Called whenever the privacy epoch changed: every derivative of the old epoch is stale.
    func privacyEpochChanged() {
        let pins = environment.pins
        let before = pins.pins.count
        pins.invalidate(documentID: session.document.id, epoch: session.privacyEpoch)
        let removed = before - pins.pins.count
        inspection = nil
        pickedColor = nil
        // Output masks alone cannot hide every duplicate of a source-bound mask in an old base.
        baseImage = nil
        installedBaseKey = nil
        failedBaseKey = nil
        if outputPreview != nil, installedOutputKey != currentOutputKey { outputPreview = nil }
        let cleared = invalidateCompletedRecognition()
        if removed > 0 {
            post(.pinsInvalidated(removed))
        } else if cleared {
            post(.recognitionInvalidated)
        }
    }

    /// Waits until no preview render is in flight (tests and the offscreen preview harness).
    func settlePreviews() async {
        while baseTask != nil || outputTask != nil {
            if let baseTask { await baseTask.value }
            if let outputTask { await outputTask.value }
        }
    }
}
