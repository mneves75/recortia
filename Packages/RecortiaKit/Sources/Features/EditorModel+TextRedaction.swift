import Domain
import Foundation

// Text-only redaction (A-6, decisions.md 2026-11-21). With Text Only on, a drawn redaction lands at
// once as an ordinary secure mask over the whole rectangle, and the automatic-masking sweep reads
// the source pixels under it. One secure mask per recognized line then replaces that cover inside
// the same undo step. Until then the masking admission point (R-4) refuses every export, pin, edit
// and selection. No line, a recognizer error, the deadline, closing the editor or a stale result
// keep the whole rectangle covered: the cover is never removed for want of an answer.

/// A drawn text-only redaction waiting for its lines.
struct PendingTextRedaction {
    /// The document state recognition started from; a result for any other state is stale.
    let request: RequestIdentity
    let cover: SecureMask
    let assetID: AssetID
    /// The asset's source pixels under the cover, where the lines are looked for.
    let sourceArea: PixelRect
    var tasks: [Task<Void, Never>] = []
}

extension EditorModel {
    /// How long recognition may take before the cover stays as it is.
    public static let textRedactionDeadline: Duration = .seconds(8)

    /// Applies to redactions drawn from now on in this editor; existing masks do not change.
    public func setRedactsTextOnly(_ on: Bool) {
        redactsTextOnly = on
    }

    /// Adds the cover over `rect` and starts looking for its lines. Returns the cover, which the
    /// line masks replace when they land.
    func addTextRedaction(covering rect: Rect<DocumentSpace>) -> EditorItemID? {
        guard !isClosed, admitsAction() else { return nil }
        endContinuousChange()
        // The cover and the line masks that replace it are one undo step.
        session.beginGroup("Redact Text")
        guard let created = addRedaction(covering: rect), case .mask(let id) = created,
            let cover = document.masks.first(where: { $0.id == id })
        else {
            closeTextRedactionStep()
            return nil
        }
        // Lines are read from one image's pixels; a cover over several images or none keeps its area.
        guard cover.sourceRegions.count == 1, let (assetID, regions) = cover.sourceRegions.first, regions.count == 1,
            let asset = document.assets[assetID]
        else {
            closeTextRedactionStep()
            post(.textRedactionKeptArea)
            return created
        }
        let request = session.requestIdentity()
        let sourceArea = regions[0]
        textRedaction = PendingTextRedaction(request: request, cover: cover, assetID: assetID, sourceArea: sourceArea)
        let service = environment.sensitiveText
        let clock = environment.clock
        // Absolute and monotonic, taken now: a timer that starts or resumes late does not extend it.
        let deadline = clock.uptime() + Self.textRedactionDeadline
        let recognition = Task { [weak self] in
            let result: Result<[PixelRect], any Error>
            do {
                result = .success(try await service.textLineRegions(in: asset, within: sourceArea))
            } catch {
                result = .failure(error)
            }
            // An overdue result keeps the cover exactly like the timeout, whether or not the timer ran.
            let onTime = clock.uptime() < deadline
            self?.finishTextRedaction(onTime ? result : .failure(CancellationError()), for: request)
        }
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: max(.zero, deadline - clock.uptime())) } catch { return }
            recognition.cancel()
            self?.finishTextRedaction(.failure(CancellationError()), for: request)
        }
        textRedaction?.tasks = [recognition, timer]
        return created
    }

    /// Closing while recognition runs: it is cancelled and the cover stays.
    func cancelTextRedaction() {
        guard textRedaction != nil else { return }
        settleTextRedaction()
    }

    private func finishTextRedaction(_ result: Result<[PixelRect], any Error>, for request: RequestIdentity) {
        // The first of recognition and deadline decides; a late answer, or one for a superseded
        // redaction, is ignored.
        guard let pending = textRedaction, pending.request == request, !isClosed else { return }
        // Lines count only for the document state they were read from, from a task that was not
        // cancelled; anything else keeps the cover.
        let isStale = !session.accepts(request)
        if isStale { droppedResultCount += 1 }
        var lines: [MaskID] = []
        if !isStale, !Task.isCancelled, case .success(let regions) = result, !regions.isEmpty {
            lines = replaceCover(pending, with: regions) ?? []
        }
        settleTextRedaction()
        if lines.isEmpty {
            post(.textRedactionKeptArea)
        } else {
            selection = Set(lines.map { .mask($0) })
            post(.textLinesCovered(lines.count))
        }
    }

    private func settleTextRedaction() {
        for task in textRedaction?.tasks ?? [] { task.cancel() }
        textRedaction = nil
        closeTextRedactionStep()
        scheduleBaseRender()
    }

    private func closeTextRedactionStep() {
        session.endGroup()
        releaseUnreachableAssets()
        noteUndoEvictionIfNeeded()
    }

    /// Swaps the cover for one opaque secure mask per line, each bound to the source pixels of its
    /// line, or changes nothing and returns nil when any line cannot be bound inside the cover.
    private func replaceCover(_ pending: PendingTextRedaction, with regions: [PixelRect]) -> [MaskID]? {
        // Allocated before the edit, whose closure runs twice and must build one document (R6-04).
        let ids = regions.map { _ in MaskID() }
        let area = pending.sourceArea
        let landed = performEdit("Redact Text") { document in
            guard let index = document.masks.firstIndex(of: pending.cover), pending.cover.fill.isOpaque,
                let asset = document.assets[pending.assetID]
            else { throw DocumentError.invalidGeometry }
            let layers = document.layers.filter { $0.assetID == pending.assetID }
            guard layers.count == 1 else { throw DocumentError.invalidGeometry }
            let toDocument = layers[0].sourceToDocument(assetSize: asset.pixelSize)
            var masks: [SecureMask] = []
            for (id, line) in zip(ids, regions) {
                guard !line.isEmpty, line.x >= area.x, line.y >= area.y, line.maxX <= area.maxX,
                    line.maxY <= area.maxY
                else { throw DocumentError.invalidGeometry }
                let mapped = EditorGeometry.outwardIntegral(toDocument.apply(line.asRect))
                guard let rect = mapped.intersection(pending.cover.outputRect) else { throw DocumentError.emptyMask }
                do { try rect.validated() } catch { throw DocumentError.invalidGeometry }
                guard !rect.isEmpty else { throw DocumentError.emptyMask }
                let bound = try document.sourceRegions(for: rect)
                // Every source pixel of the line must be bound, or the mask would not hide it.
                guard
                    bound[pending.assetID]?.contains(where: {
                        $0.x <= line.x && $0.y <= line.y && $0.maxX >= line.maxX && $0.maxY >= line.maxY
                    }) == true
                else { throw DocumentError.invalidGeometry }
                masks.append(SecureMask(id: id, outputRect: rect, sourceRegions: bound, fill: pending.cover.fill))
            }
            document.masks.replaceSubrange(index...index, with: masks)
        }
        return landed ? ids : nil
    }
}
