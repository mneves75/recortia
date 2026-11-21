import Domain
import Foundation

public enum EditorExportRequest: Hashable, Sendable {
    case copy
    /// A destination the user chose in a save panel, in the format that panel named;
    /// `replacing` is the existing file the person agreed to replace, as its collision named it.
    case save(URL, format: ExportFormatChoice, replacing: URL?)
    case saveToPreferredFolder
    case drag
    /// File › Print… (B-9a): the sanitized PNG, admitted like Copy.
    case print
}

// Export (FR-07) and pinning (FR-09). Every external write goes through `ExportCoordinator`
// (sanitized ShareSnapshot) or `PinsModel` (sanitized render); nothing here encodes or writes.
extension EditorModel {
    /// Shows an automatic export's outcome in the notice slot and returns true, or returns false
    /// when the editor is closed or a failure meets the masking count and its review reminder,
    /// which an export report never replaces (T1 security 3C); the caller raises that failure as
    /// an alert. A success waits instead and takes the slot once the count is dismissed.
    @discardableResult
    public func reportAutomaticExport(_ outcome: ExportOutcome) -> Bool {
        guard !isClosed else { return false }
        if case .sensitiveTextMasked = notice {
            if case .failed = outcome { return false }
            waitingNotice = .exported(outcome)
            return true
        }
        if case .failed(let failure) = outcome {
            post(.automaticExportFailed(failure))
        } else {
            post(.exported(outcome))
        }
        return true
    }

    /// Runs the automatic batch planned when this editor's capture completed (R-3) on the capture
    /// as it opened or, with automatic masking, as the masks left it. That state is frozen when
    /// masking settles; any later change, the person's Undo included, makes the batch stale rather
    /// than exporting it. Masking that failed skips the batch, and closing the editor cancels it.
    /// Masking defers the batch, so it waits for another editor's export to free the shared slot
    /// instead of failing busy (T1 review R-2).
    public func runAutomaticExports(_ plan: AutomaticExportPlan) async -> [ExportOutcome] {
        let baseline = await autoRedactionSettled()
        guard !isClosed else { return [.canceled] }
        guard let baseline else { return [.failed(.maskingUnfinished)] }
        if environment.export.isBusy {
            guard await waitForExportSlot() else { return [.canceled] }
            // An edit while it waited makes the frozen capture stale: nothing is rendered.
            guard session.accepts(baseline.requestIdentity()) else { return [.failed(.staleDocument)] }
        }
        return await environment.export.runAutomaticExports(
            plan, for: baseline,
            currentSession: { [weak self] in
                guard let self, !self.isClosed else { return nil }
                return self.session
            })
    }

    @discardableResult
    public func export(_ request: EditorExportRequest) async -> ExportOutcome {
        guard !isClosed else { return .failed(.staleDocument) }
        guard admitsAction(explaining: true) else { return .failed(.maskingUnfinished) }
        guard isPreviewReady else {
            post(.previewFailed)
            return .failed(.renderFailed)
        }
        let action: ExportAction
        switch request {
        case .copy:
            action = .copy
        case .save(let url, let format, let replacing):
            action = .save(to: url, format: format, replacing: replacing)
        case .drag:
            action = .drag
        case .print:
            action = .print
        case .saveToPreferredFolder:
            guard let bookmark = environment.settings.preferences.preferredSaveFolderBookmark,
                let folder = environment.folders.resolveFolder(bookmark: bookmark)
            else {
                post(.noPreferredFolder)
                return .failed(.accessDenied)
            }
            action = .saveToFolder(folder)
        }
        let revision = session.revision
        let outcome = await environment.export.export(
            action, session: session,
            currentSession: { [weak self] in
                // Rechecked after the render, before the sink commits (R2-D12b).
                guard let self, !self.isClosed, self.isPreviewReady else { return nil }
                return self.session
            })
        guard !isClosed else { return outcome }
        if outcome == .failed(.staleDocument), !isPreviewReady {
            post(.previewFailed)
            return .failed(.renderFailed)
        }
        // The exported state is now outside the app: closing no longer needs to ask.
        if outcome.didWrite, session.revision == revision { session.markSaved() }
        if outcome != .canceled { post(.exported(outcome)) }
        return outcome
    }

    /// Suspends until no export runs; false when the editor closed first. The coordinator sets and
    /// clears its operation without suspending between a batch's steps, so a free slot observed on
    /// the main actor is still free when the batch starts.
    private func waitForExportSlot() async -> Bool {
        let export = environment.export
        while export.isBusy, !isClosed {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                exportSlotWaiters.append(waiter)
                withObservationTracking {
                    _ = export.isBusy
                } onChange: { [weak self] in
                    Task { @MainActor in self?.resumeExportSlotWaiters() }
                }
            }
        }
        return !isClosed
    }

    func resumeExportSlotWaiters() {
        let waiters = exportSlotWaiters
        exportSlotWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// This editor's own export: drives its progress and Cancel Export.
    public var isExporting: Bool { environment.export.isBusy(documentID: session.document.id) }

    /// Whether the shared export slot is free. Copy, Save and Drag Out need it, so they are
    /// unavailable while any editor exports instead of opening a panel that would be refused.
    public var canStartExport: Bool { admitsAction() && !environment.export.isBusy }

    public func cancelExport() { environment.export.cancel(documentID: session.document.id) }

    /// Pins a sanitized render of the current document.
    public func pin() async {
        guard !isClosed else { return }
        guard admitsAction(explaining: true) else { return }
        guard isPreviewReady else {
            post(.previewFailed)
            return
        }
        do {
            try await environment.pins.pin(
                session,
                currentSession: { [weak self] in
                    // Rechecked after the render, before the pin is inserted (R2-D12b).
                    guard let self, !self.isClosed, self.isPreviewReady else { return nil }
                    return self.session
                })
            post(.pinned)
        } catch {
            post(error == .staleDocument && !isPreviewReady ? .previewFailed : .pinFailed(error))
        }
    }

    /// Ends the editor: cancels in-flight work, drops late results, and releases the pixels of
    /// every asset this editor held (undo history included). Idempotent.
    public func close() {
        guard !isClosed else { return }
        cancelGesture()
        endContinuousChange()
        textEditing = nil
        isClosed = true
        cancelAutoRedaction()
        cancelTextRedaction()
        resumeExportSlotWaiters()
        waitingNotice = nil
        environment.export.cancel(documentID: session.document.id)
        invalidateColorPick()
        clearContrastColors()
        baseTask?.cancel()
        outputTask?.cancel()
        baseTask = nil
        outputTask = nil
        clearRecognition()
        clearQR()
        baseImage = nil
        outputPreview = nil
        for id in knownAssets { environment.assets.release(id) }
        knownAssets = []
    }
}
