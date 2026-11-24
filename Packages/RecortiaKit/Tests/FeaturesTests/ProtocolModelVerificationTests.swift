import Domain
import Foundation
import Testing

@testable import Features

/// Deterministic bounded breadth-first state-space model checker.
///
/// Explores all reachable states from `initial` under `step` up to `stateLimit`, checking
/// `invariant` on every visited state and emitting the shortest counterexample trace on violation.
private struct BoundedModelChecker<State: Hashable, Action> {
    struct Violation {
        let reason: String
        let trace: [String]
        let state: State
    }

    struct Report {
        let exploredStates: Int
        let exploredTransitions: Int
        let violation: Violation?
        let reachable: Set<State>
    }

    static func explore(
        initial: [State],
        stateLimit: Int = 50_000,
        transitions: (State) -> [(Action, State)],
        invariant: (State) -> String?
    ) -> Report {
        var visited: Set<State> = []
        var parent: [State: (previous: State, action: String)] = [:]
        var queue: [State] = []
        var head = 0
        var edgeCount = 0

        for start in initial {
            if visited.insert(start).inserted {
                if let reason = invariant(start) {
                    return Report(
                        exploredStates: visited.count,
                        exploredTransitions: edgeCount,
                        violation: Violation(reason: reason, trace: [], state: start),
                        reachable: visited)
                }
                queue.append(start)
            }
        }

        while head < queue.count {
            let current = queue[head]
            head += 1
            for (action, next) in transitions(current) {
                edgeCount += 1
                guard visited.insert(next).inserted else { continue }
                parent[next] = (current, String(describing: action))
                if let reason = invariant(next) {
                    var trace: [String] = []
                    var cursor = next
                    while let link = parent[cursor] {
                        trace.append(link.action)
                        cursor = link.previous
                    }
                    trace.reverse()
                    return Report(
                        exploredStates: visited.count,
                        exploredTransitions: edgeCount,
                        violation: Violation(reason: reason, trace: trace, state: next),
                        reachable: visited)
                }
                if visited.count < stateLimit {
                    queue.append(next)
                }
            }
        }

        return Report(
            exploredStates: visited.count,
            exploredTransitions: edgeCount,
            violation: nil,
            reachable: visited)
    }
}

/// Bounded exhaustive formal state-space verification of Recortia's critical concurrency and
/// lifecycle protocols.
///
/// Abstraction boundaries:
/// - All models execute the production state-transition functions directly
///   (`QuitAfterLastWindow.decide`, `ExportState.next`, `ScrollState.next`) rather than
///   re-implementing their rules.
/// - Infinite domains (UUIDs, epochs, frame counts, waiter counts) are quotiented to small
///   representative bounds (0...1 epochs, 0...2 frames/waiters) sufficient to exercise every
///   aliasing, staleness, cancellation, and interleaving class.
@Suite("Bounded exhaustive protocol model verification (H4)")
struct ProtocolModelVerificationTests {

    // MARK: - Protocol A: QuitAfterLastWindow + AppModel/AppPresence lifecycle

    /// Concrete correspondence:
    /// - `QuitAfterLastWindow.decide(...)` in `Packages/RecortiaKit/Sources/Features/QuitAfterLastWindow.swift`
    /// - `AppModel.lastWindowClosed()` / `decideQuit(_:)` (`quitDecision` token + `withObservationTracking`)
    ///   in `RecortiaApp/App/AppModel.swift`
    /// - `AppPresence` (`hasUserWindow`, real-close-only trigger: launch/minimize/hide/capture suspension
    ///   never report last-window-closed) in `RecortiaApp/App/AppPresence.swift`
    private enum QuitWindowState: Hashable {
        case none
        case visible
        case minimized
        case hidden

        var hasUserWindow: Bool { self != .none }
    }

    private enum QuitTrigger: Hashable {
        case launch
        case realClose
        case minimize
        case hide
        case suspendForCapture
        case reevaluate
    }

    private struct QuitProtocolState: Hashable {
        var keepsRunningInMenuBar: Bool
        var isExporting: Bool
        var isOpeningFiles: Bool
        var window: QuitWindowState
        var isCapturing: Bool
        var isWaiting: Bool
        var quitRequested: Bool
        var lastTrigger: QuitTrigger
        /// Snapshot of preconditions at the moment `quitRequested` transitioned to `true`.
        var quitPreconditionsHeld: Bool
    }

    private enum QuitAction: CustomStringConvertible {
        case toggleMenuBar(Bool)
        case startExport, finishExport
        case startOpenFiles, finishOpenFiles
        case openWindow, realCloseLastWindow, minimizeWindow, hideWindow, restoreWindow
        case startCapture, finishCapture
        case reevaluateWait

        var description: String {
            switch self {
            case .toggleMenuBar(let on): "toggleMenuBar(\(on))"
            case .startExport: "startExport"
            case .finishExport: "finishExport"
            case .startOpenFiles: "startOpenFiles"
            case .finishOpenFiles: "finishOpenFiles"
            case .openWindow: "openWindow"
            case .realCloseLastWindow: "realCloseLastWindow"
            case .minimizeWindow: "minimizeWindow"
            case .hideWindow: "hideWindow"
            case .restoreWindow: "restoreWindow"
            case .startCapture: "startCapture"
            case .finishCapture: "finishCapture"
            case .reevaluateWait: "reevaluateWait"
            }
        }
    }

    private static func evaluateQuit(_ state: inout QuitProtocolState, trigger: QuitTrigger) {
        let decision = QuitAfterLastWindow.decide(
            keepsRunningInMenuBar: state.keepsRunningInMenuBar,
            isExporting: state.isExporting,
            isOpeningFiles: state.isOpeningFiles,
            hasUserWindow: state.window.hasUserWindow,
            isCapturing: state.isCapturing)
        state.lastTrigger = trigger
        switch decision {
        case .wait:
            state.isWaiting = true
        case .stay:
            state.isWaiting = false
        case .quit:
            state.isWaiting = false
            state.quitRequested = true
            state.quitPreconditionsHeld =
                !state.keepsRunningInMenuBar && !state.isExporting && !state.isOpeningFiles
                && !state.window.hasUserWindow && !state.isCapturing
                && (trigger == .realClose || trigger == .reevaluate)
        }
    }

    private static func quitTransitions(from state: QuitProtocolState) -> [(QuitAction, QuitProtocolState)] {
        guard !state.quitRequested else { return [] }
        var next: [(QuitAction, QuitProtocolState)] = []

        func append(_ action: QuitAction, _ mutate: (inout QuitProtocolState) -> Void) {
            var copy = state
            mutate(&copy)
            next.append((action, copy))
        }

        append(.toggleMenuBar(!state.keepsRunningInMenuBar)) { $0.keepsRunningInMenuBar.toggle() }
        if !state.isExporting { append(.startExport) { $0.isExporting = true } }
        if state.isExporting { append(.finishExport) { $0.isExporting = false } }
        if !state.isOpeningFiles { append(.startOpenFiles) { $0.isOpeningFiles = true } }
        if state.isOpeningFiles { append(.finishOpenFiles) { $0.isOpeningFiles = false } }

        switch state.window {
        case .none:
            append(.openWindow) { $0.window = .visible }
        case .visible:
            append(.realCloseLastWindow) {
                $0.window = .none
                evaluateQuit(&$0, trigger: .realClose)
            }
            append(.minimizeWindow) {
                $0.window = .minimized
                $0.lastTrigger = .minimize
            }
            append(.hideWindow) {
                $0.window = .hidden
                $0.lastTrigger = .hide
            }
        case .minimized, .hidden:
            append(.restoreWindow) { $0.window = .visible }
        }

        if !state.isCapturing {
            append(.startCapture) {
                $0.isCapturing = true
                // Accepted capture startup invalidates any pending quit decision synchronously.
                if $0.isWaiting {
                    evaluateQuit(&$0, trigger: .suspendForCapture)
                } else {
                    $0.lastTrigger = .suspendForCapture
                }
            }
        } else {
            append(.finishCapture) { $0.isCapturing = false }
        }

        if state.isWaiting {
            append(.reevaluateWait) { evaluateQuit(&$0, trigger: .reevaluate) }
        }

        return next
    }

    @Test("QuitAfterLastWindow protocol: safety and liveness across full bounded state space")
    func quitAfterLastWindowModel() {
        let initial = [false, true].map { keeps in
            QuitProtocolState(
                keepsRunningInMenuBar: keeps, isExporting: false, isOpeningFiles: false,
                window: .none, isCapturing: false, isWaiting: false, quitRequested: false,
                lastTrigger: .launch, quitPreconditionsHeld: true)
        }

        let report = BoundedModelChecker<QuitProtocolState, QuitAction>.explore(
            initial: initial,
            transitions: Self.quitTransitions(from:),
            invariant: { state in
                if state.quitRequested {
                    if !state.quitPreconditionsHeld {
                        return "Quit requested when preconditions did not hold: \(state)"
                    }
                    if state.lastTrigger == .launch || state.lastTrigger == .minimize
                        || state.lastTrigger == .hide || state.lastTrigger == .suspendForCapture
                    {
                        return "Quit triggered by non-close lifecycle event \(state.lastTrigger)"
                    }
                }
                if state.isWaiting && state.isCapturing {
                    return "Pending quit remained in .wait after capture started"
                }
                return nil
            })

        #expect(report.violation == nil, "Violation: \(String(describing: report.violation))")
        #expect(report.exploredStates > 50, "Expected non-trivial state space, got \(report.exploredStates)")

        // Liveness: every reachable `.wait` state must have a finite resolution path via work
        // completion and observation re-evaluation to `!isWaiting` (never stuck in `.wait`).
        var resolves: Set<QuitProtocolState> = Set(report.reachable.filter { !$0.isWaiting })
        var changed = true
        while changed {
            changed = false
            for state in report.reachable where state.isWaiting && !resolves.contains(state) {
                let completionTargets = Self.quitTransitions(from: state).compactMap {
                    action, target -> QuitProtocolState? in
                    switch action {
                    case .finishExport, .finishOpenFiles, .reevaluateWait: return target
                    default: return nil
                    }
                }
                if completionTargets.contains(where: resolves.contains) {
                    resolves.insert(state)
                    changed = true
                }
            }
        }
        let stuck = report.reachable.filter { $0.isWaiting && !resolves.contains($0) }
        #expect(stuck.isEmpty, "Found \(stuck.count) stuck .wait states: \(stuck.prefix(3))")
    }

    // MARK: - Protocol B: ExportCoordinator + AutomaticExportPlan + ExportLease

    private enum ExportStepKind: Hashable {
        case none
        case copy
        case save
        case upload
        case drag
    }

    private enum LeaseState: Hashable {
        case none
        case active
        case committing(revokeRequested: Bool)
        case committed
        case revoked
    }

    private enum ExportPhase: Hashable {
        case idle
        case snapshotting
        case committingFile
        case uploading
        case offeringDrag
    }

    private struct ExportProtocolState: Hashable {
        var batchActive: Bool
        var batchCanceled: Bool
        var step: ExportStepKind
        var phase: ExportPhase
        var exportState: ExportState?
        var opCanceled: Bool
        var lease: LeaseState
        var docEpoch: Int
        var snapshotEpoch: Int
        var editorClosed: Bool
        var consentEpoch: Int
        var planConsentEpoch: Int
        var waiterCount: Int
        var opCommits: Int
        var illegalCommit: Bool
        var stateMachineError: String?
        var leaseViolation: String?
    }

    private enum ExportModelAction {
        case startDrag
        case startAutoBatch(step: ExportStepKind)
        case finishSnapshot
        case failSnapshot
        case finishFileSave
        case editDocument
        case closeEditor
        case revokeConsent
        case cancelCoordinator
        case commitUpload
        case dragBeginCommit
        case dragFinishCommit
        case dragFailCommit
        case dragEndOffer
        case enqueueWaiter
        case cancelWaiter
    }

    private static func applyExport(_ state: inout ExportProtocolState, _ event: ExportEvent) {
        if case .commit = event {
            let stale = state.editorClosed || state.docEpoch != state.snapshotEpoch
            let consentLost = state.step == .upload && state.consentEpoch != state.planConsentEpoch
            let committedDragBeforeRevoke = state.step == .drag && state.lease == .committed
            if !committedDragBeforeRevoke && (stale || consentLost) {
                state.illegalCommit = true
            }
        }
        guard let current = state.exportState else { return }
        do {
            state.exportState = try current.next(event)
        } catch {
            state.stateMachineError = "\(error)"
        }
    }

    private static func finishExportOp(_ state: inout ExportProtocolState) {
        if case .active = state.lease { state.lease = .revoked }
        if case .committing = state.lease { state.lease = .committing(revokeRequested: true) }
        state.step = .none
        state.phase = .idle
        state.opCanceled = false
        state.batchActive = false
        state.batchCanceled = false
        state.lease = .none
        state.opCommits = 0
        // `isBusy` transitions to false: Observation wakes every queued waiter on the main actor.
        state.waiterCount = 0
    }

    private static func revokeLease(_ state: inout ExportProtocolState) {
        switch state.lease {
        case .active: state.lease = .revoked
        case .committing: state.lease = .committing(revokeRequested: true)
        case .committed, .revoked, .none: break
        }
    }

    private static func exportTransitions(from state: ExportProtocolState) -> [(ExportModelAction, ExportProtocolState)]
    {
        guard state.stateMachineError == nil, !state.illegalCommit, state.leaseViolation == nil else { return [] }
        var next: [(ExportModelAction, ExportProtocolState)] = []

        func append(_ action: ExportModelAction, _ mutate: (inout ExportProtocolState) -> Void) {
            var copy = state
            mutate(&copy)
            next.append((action, copy))
        }

        if state.phase == .idle {
            if !state.editorClosed {
                append(.startDrag) {
                    $0.step = .drag
                    $0.phase = .snapshotting
                    $0.snapshotEpoch = $0.docEpoch
                    $0.exportState = .requested
                    applyExport(&$0, .snapshot)
                    applyExport(&$0, .sanitize)
                    applyExport(&$0, .render)
                    $0.opCommits = 0
                }
                for kind in [ExportStepKind.copy, .save, .upload] {
                    append(.startAutoBatch(step: kind)) {
                        $0.batchActive = true
                        $0.batchCanceled = false
                        $0.planConsentEpoch = $0.consentEpoch
                        $0.step = kind
                        $0.phase = .snapshotting
                        $0.snapshotEpoch = $0.docEpoch
                        $0.exportState = .requested
                        applyExport(&$0, .snapshot)
                        applyExport(&$0, .sanitize)
                        applyExport(&$0, .render)
                        $0.opCommits = 0
                    }
                }
            }
        } else {
            if state.waiterCount < 2 {
                append(.enqueueWaiter) { $0.waiterCount += 1 }
            }
            if state.waiterCount > 0 {
                append(.cancelWaiter) { $0.waiterCount -= 1 }
            }

            // `snapshotTask` always unwinds even if `cancelOperation` moved `exportState` to `.canceled`.
            if state.phase == .snapshotting {
                append(.finishSnapshot) {
                    if $0.opCanceled {
                        finishExportOp(&$0)
                        return
                    }
                    applyExport(&$0, .encode)
                    // Post-render staleness / close / consent checks (ExportCoordinator.perform).
                    if $0.editorClosed || $0.docEpoch != $0.snapshotEpoch {
                        applyExport(&$0, .fail(.staleDocument))
                        finishExportOp(&$0)
                        return
                    }
                    if $0.step == .upload && $0.consentEpoch != $0.planConsentEpoch {
                        applyExport(&$0, .cancel)
                        finishExportOp(&$0)
                        return
                    }
                    switch $0.step {
                    case .copy:
                        // Synchronous clipboard write on MainActor before any suspension.
                        applyExport(&$0, .commit)
                        $0.opCommits += 1
                        applyExport(&$0, .committed)
                        finishExportOp(&$0)
                    case .save:
                        // Enters `.committing` synchronously, then awaits async `files.saveUnique`.
                        applyExport(&$0, .commit)
                        $0.opCommits += 1
                        $0.phase = .committingFile
                    case .upload:
                        // Spawns `uploadTask`, rechecking `isLive`/`isCurrent` before `.commit`.
                        $0.phase = .uploading
                    case .drag:
                        $0.lease = .active
                        $0.phase = .offeringDrag
                    case .none:
                        break
                    }
                }
                append(.failSnapshot) {
                    if $0.opCanceled {
                        finishExportOp(&$0)
                        return
                    }
                    applyExport(&$0, .fail(.renderFailed))
                    finishExportOp(&$0)
                }
            }

            if state.phase == .committingFile {
                append(.finishFileSave) {
                    applyExport(&$0, $0.opCanceled ? .cancel : .committed)
                    finishExportOp(&$0)
                }
            }

            if state.phase == .uploading {
                append(.commitUpload) {
                    let stale = $0.editorClosed || $0.docEpoch != $0.snapshotEpoch
                    let consentLost = $0.consentEpoch != $0.planConsentEpoch
                    if $0.opCanceled || consentLost {
                        if $0.exportState != .canceled { applyExport(&$0, .cancel) }
                        finishExportOp(&$0)
                        return
                    }
                    if stale {
                        applyExport(&$0, .fail(.upload(.staleDocument)))
                        finishExportOp(&$0)
                        return
                    }
                    applyExport(&$0, .commit)
                    $0.opCommits += 1
                    applyExport(&$0, $0.opCanceled ? .cancel : .committed)
                    finishExportOp(&$0)
                }
            }

            if state.phase == .offeringDrag {
                if state.lease == .active {
                    append(.dragBeginCommit) { $0.lease = .committing(revokeRequested: false) }
                }
                if case .committing = state.lease {
                    append(.dragFinishCommit) {
                        $0.lease = .committed
                        $0.opCommits += 1
                    }
                    append(.dragFailCommit) {
                        if case .committing(let revoked) = $0.lease {
                            $0.lease = revoked ? .revoked : .active
                        }
                    }
                } else {
                    append(.dragEndOffer) {
                        if $0.lease == .committed {
                            applyExport(&$0, .commit)
                            applyExport(&$0, $0.opCanceled ? .cancel : .committed)
                        } else if $0.opCanceled {
                            applyExport(&$0, .cancel)
                        } else if $0.lease == .revoked {
                            applyExport(&$0, .fail(.staleDocument))
                        } else {
                            applyExport(&$0, .cancel)
                        }
                        finishExportOp(&$0)
                    }
                }
            }

            if !state.opCanceled {
                append(.cancelCoordinator) {
                    $0.opCanceled = true
                    if $0.batchActive { $0.batchCanceled = true }
                    if $0.phase == .offeringDrag {
                        revokeLease(&$0)
                    } else if let current = $0.exportState,
                        current == .requested || current == .snapshotting || current == .sanitizing
                            || current == .rendering || current == .encoding
                    {
                        applyExport(&$0, .cancel)
                    }
                }
            }
        }

        if state.docEpoch == 0 && !state.editorClosed {
            append(.editDocument) {
                $0.docEpoch = 1
                if $0.phase == .offeringDrag { revokeLease(&$0) }
            }
        }
        if !state.editorClosed {
            append(.closeEditor) {
                $0.editorClosed = true
                if $0.phase != .idle {
                    $0.opCanceled = true
                    if $0.batchActive { $0.batchCanceled = true }
                    if $0.phase == .offeringDrag {
                        revokeLease(&$0)
                    } else if let current = $0.exportState,
                        current == .requested || current == .snapshotting || current == .sanitizing
                            || current == .rendering || current == .encoding
                    {
                        applyExport(&$0, .cancel)
                    }
                }
            }
        }
        if state.consentEpoch == 0 {
            append(.revokeConsent) { $0.consentEpoch = 1 }
        }

        return next
    }

    @Test("ExportCoordinator + AutomaticExportPlan + ExportLease protocol: safety, at-most-once commit, no leaked busy")
    func exportCoordinatorLeaseModel() {
        let initial = ExportProtocolState(
            batchActive: false, batchCanceled: false, step: .none, phase: .idle, exportState: nil, opCanceled: false,
            lease: .none, docEpoch: 0, snapshotEpoch: 0, editorClosed: false, consentEpoch: 0,
            planConsentEpoch: 0, waiterCount: 0, opCommits: 0, illegalCommit: false,
            stateMachineError: nil, leaseViolation: nil)

        let report = BoundedModelChecker<ExportProtocolState, ExportModelAction>.explore(
            initial: [initial],
            transitions: Self.exportTransitions(from:),
            invariant: { state in
                if let error = state.stateMachineError { return "Illegal ExportState transition: \(error)" }
                if state.illegalCommit { return "Committed after staleness/close/consent revocation: \(state)" }
                if state.opCommits > 1 { return "ExportLease committed more than once: \(state.opCommits)" }
                if state.phase == .idle && state.waiterCount > 0 {
                    return "Waiters left stranded after export slot freed: \(state.waiterCount)"
                }
                if state.phase == .idle && state.batchActive {
                    return "Leaked automaticBatch while idle"
                }
                return nil
            })

        #expect(report.violation == nil, "Violation: \(String(describing: report.violation))")
        #expect(report.exploredStates > 100, "Expected non-trivial state space, got \(report.exploredStates)")

        // Liveness: from every reachable busy state, a finite completion path returns to idle with 0 waiters.
        var reachesIdle: Set<ExportProtocolState> = Set(
            report.reachable.filter { $0.phase == .idle && $0.waiterCount == 0 })
        var changed = true
        while changed {
            changed = false
            for state in report.reachable where !reachesIdle.contains(state) {
                if Self.exportTransitions(from: state).contains(where: { reachesIdle.contains($0.1) }) {
                    reachesIdle.insert(state)
                    changed = true
                }
            }
        }
        let deadlocked = report.reachable.subtracting(reachesIdle)
        #expect(deadlocked.isEmpty, "Found \(deadlocked.count) states that cannot drain to idle")
    }

    // MARK: - Protocol C: ScrollSessionModel interleaving exploration

    private enum SettleModelState: Hashable {
        case none
        case sleeping
        case awaitingIsAtEnd(canceled: Bool)
    }

    private struct ScrollProtocolState: Hashable {
        var scrollState: ScrollState
        var acceptedFrames: Int
        var appendInFlight: Bool
        var pendingFinish: Bool
        var settle: SettleModelState
        var unansweredSteps: Int
        var stateMachineError: String?
        var abortedByCanceledSettle: Bool
    }

    private enum ScrollModelAction {
        case frameArrives
        case appendAccepted
        case appendAmbiguous
        case settleTimerFires
        case isAtEndReturns(Bool)
        case pause
        case resume
        case stop
        case discard
        case deadline
    }

    private static func applyScroll(_ state: inout ScrollProtocolState, _ event: ScrollEvent) {
        do {
            state.scrollState = try state.scrollState.next(event)
        } catch {
            state.stateMachineError = "\(error)"
        }
    }

    private static func cancelSettle(_ state: inout ScrollProtocolState) {
        switch state.settle {
        case .sleeping: state.settle = .none
        case .awaitingIsAtEnd: state.settle = .awaitingIsAtEnd(canceled: true)
        case .none: break
        }
        state.unansweredSteps = 0
    }

    private static func finishScroll(_ state: inout ScrollProtocolState, event: ScrollEvent) {
        guard !state.pendingFinish else { return }
        cancelSettle(&state)
        if state.appendInFlight {
            state.pendingFinish = true
            return
        }
        completeScrollFinish(&state, event: event)
    }

    private static func completeScrollFinish(_ state: inout ScrollProtocolState, event: ScrollEvent) {
        state.pendingFinish = false
        applyScroll(&state, event)
        if state.acceptedFrames == 0 {
            applyScroll(&state, .fail(.noFrames))
        }
    }

    private static func scrollTransitions(from state: ScrollProtocolState)
        -> [(ScrollModelAction, ScrollProtocolState)]
    {
        guard state.stateMachineError == nil, !state.abortedByCanceledSettle else { return [] }
        var next: [(ScrollModelAction, ScrollProtocolState)] = []
        let endThreshold = 2

        func append(_ action: ScrollModelAction, _ mutate: (inout ScrollProtocolState) -> Void) {
            var copy = state
            mutate(&copy)
            next.append((action, copy))
        }

        if state.scrollState == .collecting && !state.appendInFlight && !state.pendingFinish {
            append(.frameArrives) {
                cancelSettle(&$0)
                $0.appendInFlight = true
            }
        }

        if state.appendInFlight {
            append(.appendAccepted) {
                $0.appendInFlight = false
                $0.acceptedFrames = min(2, $0.acceptedFrames + 1)
                if $0.pendingFinish {
                    completeScrollFinish(&$0, event: .stop)
                } else {
                    $0.unansweredSteps = 0
                    if $0.scrollState == .collecting {
                        $0.settle = .sleeping
                    }
                }
            }
            append(.appendAmbiguous) {
                $0.appendInFlight = false
                if $0.pendingFinish {
                    completeScrollFinish(&$0, event: .stop)
                } else if $0.scrollState == .collecting {
                    applyScroll(&$0, .pause(.ambiguousMatch))
                }
            }
        }

        if state.settle == .sleeping && state.scrollState == .collecting && !state.pendingFinish {
            append(.settleTimerFires) {
                let count = min(endThreshold, $0.unansweredSteps + 1)
                $0.unansweredSteps = count
                if count >= endThreshold && $0.acceptedFrames > 0 {
                    $0.settle = .awaitingIsAtEnd(canceled: false)
                } else {
                    $0.settle = .sleeping
                }
            }
        }

        if case .awaitingIsAtEnd(let canceled) = state.settle {
            for atEnd in [false, true] {
                append(.isAtEndReturns(atEnd)) {
                    $0.settle = .none
                    // H1 post-await guard: must require !canceled, collecting, and !pendingFinish.
                    guard !canceled, $0.scrollState == .collecting, !$0.pendingFinish else { return }
                    if canceled { $0.abortedByCanceledSettle = true }
                    finishScroll(&$0, event: .stop)
                }
            }
        }

        if state.scrollState == .collecting && !state.pendingFinish {
            append(.pause) {
                cancelSettle(&$0)
                applyScroll(&$0, .pause(.userPaused))
            }
        }

        if case .paused = state.scrollState, !state.pendingFinish {
            append(.resume) {
                applyScroll(&$0, .resume)
                $0.unansweredSteps = 0
                if $0.settle == .none { $0.settle = .sleeping }
            }
        }

        if state.scrollState == .collecting || (state.scrollState == .paused(.userPaused))
            || (state.scrollState == .paused(.ambiguousMatch))
        {
            append(.stop) { finishScroll(&$0, event: .stop) }
            append(.deadline) {
                let event: ScrollEvent = $0.scrollState == .collecting ? .limitReached(.duration) : .stop
                finishScroll(&$0, event: event)
            }
        }

        if state.scrollState.isActive {
            append(.discard) {
                $0.pendingFinish = false
                $0.appendInFlight = false
                cancelSettle(&$0)
                $0.acceptedFrames = 0
                applyScroll(&$0, .cancel)
            }
        }

        return next
    }

    @Test(
        "ScrollSessionModel interleavings: zero illegal transitions, H1 cancel-safety, review & pendingFinish invariants"
    )
    func scrollSessionInterleavingModel() {
        let initial = ScrollProtocolState(
            scrollState: .collecting, acceptedFrames: 0, appendInFlight: false, pendingFinish: false,
            settle: .none, unansweredSteps: 0, stateMachineError: nil, abortedByCanceledSettle: false)

        let report = BoundedModelChecker<ScrollProtocolState, ScrollModelAction>.explore(
            initial: [initial],
            transitions: Self.scrollTransitions(from:),
            invariant: { state in
                if let error = state.stateMachineError { return "Illegal ScrollState transition: \(error)" }
                if state.abortedByCanceledSettle { return "Canceled settleTask aborted active scroll collection" }
                if state.pendingFinish && !state.appendInFlight {
                    return "pendingFinish remained set without an append in flight"
                }
                if state.scrollState == .reviewing {
                    if state.appendInFlight || state.pendingFinish || state.acceptedFrames == 0 {
                        return "Review opened inconsistently: \(state)"
                    }
                    if state.settle == .sleeping {
                        return "Settle timer still sleeping while reviewing"
                    }
                }
                if state.scrollState == .canceled || state.scrollState == .failed(.noFrames) {
                    if state.appendInFlight || state.pendingFinish || state.acceptedFrames != 0 {
                        return "Terminal scroll state retained live work: \(state)"
                    }
                }
                return nil
            })

        #expect(report.violation == nil, "Violation: \(String(describing: report.violation))")
        #expect(report.exploredStates > 30, "Expected non-trivial state space, got \(report.exploredStates)")
    }

    // MARK: - Negative control for the BFS checker itself

    @Test("BoundedModelChecker emits a minimal counterexample trace when a planted bug violates an invariant")
    func modelCheckerNegativeControl() {
        // Planted bug: allow QuitAfterLastWindow to fire on `.minimize` without waiting for close.
        let initial = QuitProtocolState(
            keepsRunningInMenuBar: false, isExporting: false, isOpeningFiles: false,
            window: .visible, isCapturing: false, isWaiting: false, quitRequested: false,
            lastTrigger: .launch, quitPreconditionsHeld: true)

        let report = BoundedModelChecker<QuitProtocolState, QuitAction>.explore(
            initial: [initial],
            transitions: { state in
                guard !state.quitRequested else { return [] }
                var broken = state
                broken.window = .minimized
                broken.lastTrigger = .minimize
                broken.quitRequested = true
                return [(.minimizeWindow, broken)]
            },
            invariant: { state in
                if state.quitRequested && state.lastTrigger == .minimize {
                    return "Planted bug: quit triggered on minimize"
                }
                return nil
            })

        #expect(report.violation != nil)
        #expect(report.violation?.trace == ["minimizeWindow"])
    }
}
