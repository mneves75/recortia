import Domain
import Foundation

// Automatic masking of a new capture (FR-06 amendment; decisions.md 2026-11-20). The editor opens
// at once. Until the masks land as one undo step it renders no capture pixels and refuses every
// edit, selection, export, pin, Output Preview and recognition, and the automatic batch waits.
// A detector error, cancellation or the deadline fails closed: nothing is masked, the editor says
// so, manual export is allowed again, and that capture's automatic batch is skipped.
extension EditorModel {
    /// Automatic masks, or the line masks of a text-only redaction, have not landed yet.
    public var isMaskingPending: Bool { autoRedaction == .pending || textRedaction != nil }

    /// Whether closing now may keep the document for Reopen Closed Capture: never while masks are
    /// pending, nor after automatic masking failed until the person dismissed that notice. A notice
    /// that replaced the failure is not a dismissal, so it fails closed.
    public var isKeptOnClose: Bool {
        !isClosed && !isMaskingPending && (autoRedaction != .failed || maskingFailureAcknowledged)
    }

    /// The one admission point for the person's actions while the masks are pending (R-4): every
    /// entry point that edits, selects, samples, renders, recognizes, imports or exports asks it
    /// first, and `edit` asks it for every document change. `explaining` posts
    /// `.maskingInProgress` (`.textRedactionInProgress` for a text-only redaction) for a command
    /// the person gave by name; pointer, selection, history and edit traffic is refused silently.
    /// `MaskingAdmissionTests` drives every public function.
    func admitsAction(explaining: Bool = false) -> Bool {
        guard isMaskingPending else { return true }
        if explaining { post(textRedaction == nil ? .maskingInProgress : .textRedactionInProgress) }
        return false
    }

    /// Starts detection and its deadline; whichever settles first decides (`finishAutoRedaction`).
    func startAutoRedaction() {
        guard let asset = document.layers.first.flatMap({ document.assets[$0.assetID] }) else {
            return finishAutoRedaction(
                .failure(SensitiveTextUnavailable()), for: nil, startedAt: environment.clock.uptime())
        }
        let request = session.requestIdentity()
        autoRedactionRequest = request
        let service = environment.sensitiveText
        let clock = environment.clock
        // Absolute and monotonic, taken now: a timer that starts or resumes late does not extend it.
        let started = clock.uptime()
        let deadline = started + Self.autoRedactionDeadline
        let detection = Task { [weak self] in
            let result: Result<[PixelRect], any Error>
            do {
                result = .success(try await service.sensitiveRegions(in: asset))
            } catch {
                result = .failure(error)
            }
            // An overdue result fails closed exactly like the timeout, whether or not the timer ran.
            let onTime = clock.uptime() < deadline
            self?.finishAutoRedaction(onTime ? result : .failure(CancellationError()), for: request, startedAt: started)
        }
        let timer = Task { [weak self] in
            do { try await clock.sleep(for: max(.zero, deadline - clock.uptime())) } catch { return }
            // Stops the sweep even when no editor is left to settle.
            detection.cancel()
            self?.finishAutoRedaction(.failure(CancellationError()), for: request, startedAt: started)
        }
        autoRedactionTasks = [detection, timer]
    }

    /// What the capture's automatic batch may export once masking is no longer pending (at once when
    /// it is not): the frozen baseline, or nil when masking failed.
    func autoRedactionSettled() async -> DocumentSession? {
        guard autoRedaction == .pending else { return automaticExportBaseline }
        return await withCheckedContinuation { autoRedactionWaiters.append($0) }
    }

    /// Closing while pending: detection is cancelled and nothing waits for it any more.
    func cancelAutoRedaction() {
        guard autoRedaction == .pending else { return }
        settleAutoRedaction(.failed)
    }

    /// `request` is the identity detection started with; nil only when there was nothing to scan.
    private func finishAutoRedaction(
        _ result: Result<[PixelRect], any Error>, for request: RequestIdentity?, startedAt: Duration
    ) {
        // The first of detection and deadline decides; a late result, or one for a superseded
        // request, is ignored.
        guard autoRedaction == .pending, !isClosed, request == autoRedactionRequest else { return }
        // A result counts only for the document state it was computed from, from a task that was
        // not cancelled; anything else fails closed, an empty result included.
        let isCurrent = !Task.isCancelled && request.map { session.accepts($0) } == true
        let duration = environment.clock.uptime() - startedAt
        if isCurrent, case .success(let regions) = result, landAutoMasks(regions) {
            settleAutoRedaction(.done)
            environment.diagnostics?.record(
                .autoMaskingFinished(regions: regions.count, outcome: .masked, duration: duration))
            // Zero included: with masking on, the person always learns what it found.
            post(.sensitiveTextMasked(regions.count))
        } else {
            settleAutoRedaction(.failed)
            // The deadline, an overdue result and cancellation all arrive as CancellationError.
            var timedOut = false
            if case .failure(let error) = result { timedOut = error is CancellationError }
            environment.diagnostics?.record(
                .autoMaskingFinished(regions: 0, outcome: timedOut ? .timedOut : .failed, duration: duration))
            post(.maskingFailed)
        }
    }

    /// Freezes the batch's baseline before any waiter resumes, so nothing queued on the main actor
    /// between this and the batch (an Undo, an edit) can change what it exports.
    private func settleAutoRedaction(_ outcome: AutoRedaction) {
        for task in autoRedactionTasks { task.cancel() }
        autoRedactionTasks = []
        autoRedactionRequest = nil
        autoRedaction = outcome
        automaticExportBaseline = outcome == .done ? session : nil
        let waiters = autoRedactionWaiters
        autoRedactionWaiters = []
        for waiter in waiters { waiter.resume(returning: automaticExportBaseline) }
        scheduleBaseRender()
    }

    /// One undo step of opaque secure masks, each bound to exactly the source pixels the detector
    /// returned. A fresh capture maps document pixels onto its source one to one; if this document
    /// does not, the step is refused and masking fails closed.
    private func landAutoMasks(_ regions: [PixelRect]) -> Bool {
        guard !regions.isEmpty else { return true }
        let fill = redactionFill
        // Allocated before the edit, whose closure runs twice and must build one document (R6-04).
        let ids = regions.map { _ in MaskID() }
        // The masks are their own undo step, never part of a group that was open (none can be).
        endContinuousChange()
        let landed = performEdit("Redact Sensitive Text") { document in
            guard fill.isOpaque else { throw DocumentError.translucentSecureMask }
            guard document.layers.count == 1, let asset = document.layers.first?.assetID else {
                throw DocumentError.invalidGeometry
            }
            for (id, region) in zip(ids, regions) {
                let area = Rect<DocumentSpace>(
                    x: Double(region.x), y: Double(region.y), width: Double(region.width),
                    height: Double(region.height))
                do { try area.validated() } catch { throw DocumentError.invalidGeometry }
                guard !area.isEmpty else { throw DocumentError.emptyMask }
                let bound = try document.sourceRegions(for: area)
                guard bound == [asset: [region]] else { throw DocumentError.invalidGeometry }
                document.masks.append(SecureMask(id: id, outputRect: area, sourceRegions: bound, fill: fill))
            }
        }
        // The masks are not the person's edit: closing the masked capture asks no more than closing
        // an unmasked one would.
        if landed { session.markSaved() }
        return landed
    }
}

/// The capture document has no image to scan.
struct SensitiveTextUnavailable: Error {}
