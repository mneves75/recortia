import CoreGraphics
import Domain
import Foundation
import Imaging
import Observation

/// The editor's document controller (FR-04 … FR-13): one `DocumentSession`, the active tool,
/// selection, style, viewport, sanitized preview, and results of OCR, QR, and pixel tools.
///
/// Every geometric input is in document space; the canvas converts pointer locations through
/// `viewport` first, so zoom and pan never change document geometry (EDIT-02). One pointer
/// gesture is one undo group. Asynchronous results (preview, OCR, QR) carry a request identity
/// and are dropped when the document moved on (RED-03). Nothing here writes to a sink except
/// through `ExportCoordinator`, `PinsModel`, or an explicit text copy.
@MainActor
@Observable
public final class EditorModel {
    public internal(set) var session: DocumentSession
    public internal(set) var tool: EditorTool = .select
    public internal(set) var selection: Set<EditorItemID> = []
    public internal(set) var style = EditorStyle()
    /// Opaque fill for new secure redactions.
    public internal(set) var redactionFill: RGBA = .black
    public internal(set) var viewport = EditorViewport()
    public internal(set) var viewportSize = Size<ViewSpace>(width: 0, height: 0)
    /// Device pixels per view point of the canvas's screen; 100 % zoom shows one document pixel per device pixel.
    public internal(set) var backingScale: Double = 1
    public internal(set) var draft: EditorDraft?
    public internal(set) var textEditing: EditorTextEditing?
    public internal(set) var notice: EditorNotice?
    /// Increments with every notice so the view can show a repeated identical notice again.
    public internal(set) var noticeSerial = 0
    /// Preferred OCR languages (English, Portuguese) the system does not offer; reported, never assumed (FR-08).
    public internal(set) var unavailableRecognitionLanguages: [String] = []
    public internal(set) var isClosed = false
    /// Automatic masking of a new capture (EditorModel+AutoRedaction.swift).
    public internal(set) var autoRedaction: AutoRedaction = .off

    // Preview (EditorModel+Preview.swift)
    public internal(set) var baseImage: CGImage?
    public internal(set) var showsOutputPreview = false
    public internal(set) var outputPreview: CGImage?
    /// Asynchronous results discarded because the document changed meanwhile (diagnostics, tests).
    internal(set) var droppedResultCount = 0

    // Recognition (EditorModel+Recognition.swift)
    public internal(set) var recognition: EditorRecognitionState = .idle
    public internal(set) var qr: EditorQRState = .idle

    // Pixel tools (EditorModel+PixelTools.swift)
    public internal(set) var inspection: EditorColorSample?
    public internal(set) var pickedColor: EditorColorSample?
    var storedColorSampleSize: PixelSampleSize = .singlePixel
    public var colorSampleSize: PixelSampleSize {
        get { storedColorSampleSize }
        set { setColorSampleSize(newValue) }
    }
    public internal(set) var ruler: EditorMeasurement?

    @ObservationIgnored public let environment: EditorEnvironment
    @ObservationIgnored var gesture: Gesture = .idle
    @ObservationIgnored var knownAssets: Set<AssetID>
    @ObservationIgnored var hasFittedViewport = false
    @ObservationIgnored private var reportedEvictedUndoCount = 0
    @ObservationIgnored var continuousChangeID: UUID?
    @ObservationIgnored private var listItemsMemo: (revision: UInt64, items: [EditorListItem])?
    /// Geometry resolutions performed while building `listItems`. Resolving a text frame is a full
    /// Core Text layout, so the memo is a performance invariant and tests assert this count instead
    /// of wall-clock time, which no gate on this host could qualify.
    @ObservationIgnored internal private(set) var listItemGeometryResolutions = 0

    @ObservationIgnored var baseTask: Task<Void, Never>?
    @ObservationIgnored var installedBaseKey: BaseKey?
    /// Observed: the canvas veil and export readiness follow it (`isPreviewReady`).
    var failedBaseKey: BaseKey?
    @ObservationIgnored var outputTask: Task<Void, Never>?
    @ObservationIgnored var installedOutputKey: OutputKey?
    var failedOutputKey: OutputKey?
    /// The document state the native canvas last failed to draw; nil once it draws (NEW-01).
    var failedCanvasDraw: OutputKey?
    @ObservationIgnored var recognitionRequest: UUID?
    @ObservationIgnored var recognizedResult: OCRResult?
    @ObservationIgnored var qrRequest: UUID?
    @ObservationIgnored var colorPickTask: Task<Void, Never>?
    @ObservationIgnored var colorPickRequest: UUID?
    @ObservationIgnored var autoRedactionTasks: [Task<Void, Never>] = []
    /// The document state detection started from; a result for any other state is stale.
    @ObservationIgnored var autoRedactionRequest: RequestIdentity?
    /// What the capture's automatic batch exports, frozen when masking settles: the capture itself
    /// without masking, the masked capture after it, nil when masking failed (`autoRedactionSettled`).
    @ObservationIgnored var automaticExportBaseline: DocumentSession?
    @ObservationIgnored var autoRedactionWaiters: [CheckedContinuation<DocumentSession?, Never>] = []

    enum Gesture {
        case idle
        case create(tool: EditorTool, start: Point<DocumentSpace>, points: [Point<DocumentSpace>])
        case move(items: [EditorItemID], start: Point<DocumentSpace>, original: Document)
        /// `start` is the pointer-down point and `anchor` the grabbed handle's position: the handle
        /// follows the pointer's delta from `start`.
        case resize(
            item: EditorItemID, handle: EditorHandle, frame: Rect<DocumentSpace>, original: Document,
            start: Point<DocumentSpace>, anchor: Point<DocumentSpace>)
        case marquee(start: Point<DocumentSpace>, initial: Set<EditorItemID>)
        case ruler(start: Point<DocumentSpace>)
        case sample
    }

    /// How long automatic masking may take before it fails closed (provisional, see
    /// docs/specs/program-2026-11/spike-auto-redaction.md).
    public static let autoRedactionDeadline: Duration = .seconds(8)

    /// `autoRedacts`: a new capture whose e-mail addresses and phone numbers are masked before the
    /// editor shows or exports its pixels (FR-06).
    public init(session: DocumentSession, environment: EditorEnvironment, autoRedacts: Bool = false) {
        self.session = session
        self.environment = environment
        knownAssets = Set(session.document.assets.keys)
        automaticExportBaseline = session
        if autoRedacts {
            autoRedaction = .pending
            startAutoRedaction()
        }
        scheduleBaseRender()
    }

    // An editor released without `close()` still stops its detection and deadline.
    isolated deinit {
        for task in autoRedactionTasks { task.cancel() }
    }

    public var document: Document { session.document }
    public var canUndo: Bool { session.canUndo }
    public var canRedo: Bool { session.canRedo }
    /// Edited since the last successful export of the current state.
    public var isDirty: Bool { session.isDirty }

    // MARK: - Notices

    func post(_ notice: EditorNotice) {
        self.notice = notice
        noticeSerial += 1
    }

    public func dismissNotice() { notice = nil }

    // MARK: - Tools and style

    public func selectTool(_ tool: EditorTool) {
        guard !isClosed, textEditing == nil else { return }
        cancelGesture()
        self.tool = tool
        if tool != .ruler { ruler = nil }
        if tool != .loupe { inspection = nil }
    }

    public func setStrokeColor(_ color: RGBA) {
        style.stroke = color.withAlpha(255)
        restyleSelection("Color") { $0.stroke = color.withAlpha(255) }
    }

    public func setFillColor(_ color: RGBA?) {
        style.fill = color
        restyleSelection("Fill") { $0.fill = color }
    }

    public func setLineWidth(_ width: Double) {
        guard width.isFinite else { return }
        let value = min(max(width, EditorStyle.lineWidthRange.lowerBound), EditorStyle.lineWidthRange.upperBound)
        do {
            for annotation in document.annotations where selection.contains(.annotation(annotation.id)) {
                var proposed = annotation
                proposed.style.lineWidth = value
                try Self.validateArrow(proposed)
            }
        } catch {
            post(.arrowGeometryRefused)
            return
        }
        style.lineWidth = value
        restyleSelection("Line Width") { $0.lineWidth = value }
    }

    public func setOpacity(_ opacity: Double) {
        guard opacity.isFinite else { return }
        let value = min(max(opacity, EditorStyle.opacityRange.lowerBound), EditorStyle.opacityRange.upperBound)
        style.opacity = value
        restyleSelection("Opacity") { $0.opacity = value }
    }

    public func setFontSize(_ size: Double) {
        guard size.isFinite else { return }
        let value = min(max(size, EditorStyle.fontSizeRange.lowerBound), EditorStyle.fontSizeRange.upperBound)
        style.fontSize = value
        let ids = selectedAnnotationIDs
        guard !ids.isEmpty else { return }
        edit("Font Size") { document in
            for index in document.annotations.indices where ids.contains(document.annotations[index].id) {
                if case .text(var text) = document.annotations[index].kind {
                    text.fontSize = value
                    document.annotations[index].kind = .text(text)
                }
            }
        }
    }

    public func setRedactionFill(_ color: RGBA) {
        let opaque = color.withAlpha(255)
        redactionFill = opaque
        let ids = Set(selection.compactMap { if case .mask(let id) = $0 { id } else { nil } })
        guard !ids.isEmpty else { return }
        edit("Redaction Color") { document in
            for index in document.masks.indices where ids.contains(document.masks[index].id) {
                document.masks[index].fill = opaque
            }
        }
    }

    /// Groups a run of changes (a slider drag, a color well session) into one undo step.
    @discardableResult
    public func beginContinuousChange() -> UUID {
        // Refused while masking runs, so no group can hold the masks' undo step (the returned ID
        // then ends nothing).
        guard !isMaskingPending else { return UUID() }
        if let continuousChangeID { return continuousChangeID }
        let id = UUID()
        continuousChangeID = id
        session.beginGroup("Adjust")
        return id
    }

    public func endContinuousChange() {
        guard let id = continuousChangeID else { return }
        endContinuousChange(id)
    }

    public func endContinuousChange(_ id: UUID) {
        guard continuousChangeID == id else { return }
        continuousChangeID = nil
        session.endGroup()
        releaseUnreachableAssets()
        noteUndoEvictionIfNeeded()
    }

    private var selectedAnnotationIDs: Set<AnnotationID> {
        Set(selection.compactMap { if case .annotation(let id) = $0 { id } else { nil } })
    }

    private func restyleSelection(_ label: String, _ change: (inout Annotation.Style) -> Void) {
        let ids = selectedAnnotationIDs
        guard !ids.isEmpty else { return }
        edit(label) { document in
            for index in document.annotations.indices where ids.contains(document.annotations[index].id) {
                change(&document.annotations[index].style)
            }
        }
    }

    // MARK: - Editing core

    /// Applies one change to the document. Returns false when the change threw (for example a
    /// mask over an unmappable layer); the document is then unchanged.
    ///
    /// Every edit first makes each mask's coverage durable (`preserveCoverage`), so no edit can
    /// uncover what a box hides by moving, scaling, cropping, adding or removing a layer (R2).
    /// `inPreview` marks a whole-image presentation setting, which selects nothing.
    @discardableResult
    func edit(_ label: String, inPreview: Bool = false, _ change: (inout Document) throws -> Void) -> Bool {
        // Output Preview is read-only for selection and objects (F-04); whole-image presentation
        // settings stay available there, where their effect is seen. Nothing changes while
        // automatic masking is pending.
        guard !isClosed, !isMaskingPending, !showsOutputPreview || inPreview else { return false }
        return performEdit(label, change)
    }

    /// `edit` without its guards; automatic masks land through it while masking is still pending.
    func performEdit(_ label: String, _ change: (inout Document) throws -> Void) -> Bool {
        let before = session.document
        let epoch = session.privacyEpoch
        do {
            let (preserved, updated) = try Self.applying(change, to: before)
            guard updated != preserved else { return true }
            settleTransformGesture()
            try session.perform(label) { $0 = updated }
        } catch {
            if error is ArrowGeometryFailure {
                post(.arrowGeometryRefused)
            } else if error is DocumentError {
                post(.redactionRefused)
            }
            return false
        }
        didChange(from: before, epoch: epoch)
        return true
    }

    /// Releases pixels of assets that neither the document nor retained history can bring back
    /// (an undone image whose redo step was discarded, or evicted history).
    func releaseUnreachableAssets() {
        let unreachable = knownAssets.subtracting(session.referencedAssetIDs)
        guard !unreachable.isEmpty else { return }
        for id in unreachable { environment.assets.release(id) }
        knownAssets.subtract(unreachable)
    }

    func didChange(from before: Document, epoch: UInt64) {
        noteUndoEvictionIfNeeded()
        guard session.document != before || session.privacyEpoch != epoch else { return }
        invalidateColorPick()
        releaseUnreachableAssets()
        // A drag offered for the previous state must not deliver it (RED-03, EXP-02).
        environment.export.invalidatePendingDrag(documentID: session.document.id)
        let existing = Set(allItemIDs)
        selection = selection.filter(existing.contains)
        loadSelectedTextAppearance()
        if session.privacyEpoch != epoch {
            privacyEpochChanged()
        } else if invalidateCompletedRecognition() {
            post(.recognitionInvalidated)
        }
        scheduleBaseRender()
        if showsOutputPreview { scheduleOutputRender() }
    }

    /// Why the document's scrolling capture is partial, when it is one; the editor keeps showing it
    /// so a partial result is never presented as complete (FR-10).
    public var partialScrollCaptureReason: ScrollPartialReason? {
        for asset in session.document.assets.values {
            if case .scrollCapture(let reason?) = asset.origin { return reason }
        }
        return nil
    }

    /// Undo history is bounded; when the oldest steps are evicted the user is told (SPEC FR-04).
    func noteUndoEvictionIfNeeded() {
        guard session.evictedUndoCount > reportedEvictedUndoCount else { return }
        reportedEvictedUndoCount = session.evictedUndoCount
        post(.undoHistoryTrimmed)
    }

    public func undo() {
        guard !isClosed, !isMaskingPending, !showsOutputPreview, textEditing == nil else { return }
        // During a drag, Undo cancels only that drag and never reaches the history past it.
        if case .idle = gesture {} else { return cancelGesture() }
        guard canUndo else { return }
        endContinuousChange()
        let before = session.document, epoch = session.privacyEpoch
        session.undo()
        didChange(from: before, epoch: epoch)
    }

    public func redo() {
        guard !isClosed, !isMaskingPending, !showsOutputPreview, textEditing == nil else { return }
        // During a drag, Redo cancels only that drag and never reaches the history past it.
        if case .idle = gesture {} else { return cancelGesture() }
        guard canRedo else { return }
        endContinuousChange()
        let before = session.document, epoch = session.privacyEpoch
        session.redo()
        didChange(from: before, epoch: epoch)
    }

    // MARK: - Items

    var allItemIDs: [EditorItemID] {
        let d = session.document
        return d.layers.map { .layer($0.id) } + d.obfuscations.map { .obfuscation($0.id) }
            + d.annotations.map { .annotation($0.id) } + d.masks.map { .mask($0.id) }
            + d.callouts.map { .callout($0.id) }
    }

    public func frame(of item: EditorItemID) -> Rect<DocumentSpace>? {
        EditorGeometry.frame(of: item, in: session.document)
    }

    public func kind(of item: EditorItemID) -> EditorItemKind? {
        let d = session.document
        switch item {
        case .annotation(let id): return d.annotations.first { $0.id == id }.map { EditorItemKind($0.kind) }
        case .layer(let id): return d.layers.contains { $0.id == id } ? .image : nil
        case .mask(let id): return d.masks.contains { $0.id == id } ? .redaction : nil
        case .obfuscation(let id):
            guard let effect = d.obfuscations.first(where: { $0.id == id }) else { return nil }
            if case .blur = effect.style { return .blur }
            return .pixelate
        case .callout(let id):
            guard let callout = d.callouts.first(where: { $0.id == id }) else { return nil }
            if case .spotlight = callout.kind { return .spotlight }
            return .magnifier
        }
    }

    /// Every object, topmost first, for the accessible object list and canvas accessibility.
    ///
    /// The canvas, the inspector, the sidebar and the marquee each ask for this list, and the canvas
    /// asks on every observed change — including the draft, which moves per pointer event. A text
    /// item's frame is a full Core Text layout, so the result is memoised against the document
    /// revision: `revision` moves in exactly one place (`DocumentSession.replaceDocument`), which is
    /// what makes it a sound key rather than a guess.
    public var listItems: [EditorListItem] {
        if let memo = listItemsMemo, memo.revision == session.revision { return memo.items }
        let items = resolveListItems()
        listItemsMemo = (revision: session.revision, items: items)
        return items
    }

    private func resolveListItems() -> [EditorListItem] {
        let d = session.document
        var counters: [EditorItemKind: Int] = [:]
        var bottomUp: [EditorListItem] = []
        // An item whose geometry cannot be resolved (missing asset, failed text layout) is left out.
        func append(_ id: EditorItemID, _ kind: EditorItemKind, _ frame: Rect<DocumentSpace>?, step: Int? = nil) {
            guard let frame else { return }
            listItemGeometryResolutions += 1
            counters[kind, default: 0] += 1
            bottomUp.append(
                EditorListItem(id: id, kind: kind, ordinal: counters[kind] ?? 1, frame: frame, stepNumber: step))
        }
        for layer in d.layers {
            append(.layer(layer.id), .image, EditorGeometry.frame(of: layer, in: d))
        }
        for effect in d.obfuscations {
            let kind: EditorItemKind = if case .blur = effect.style { .blur } else { .pixelate }
            append(.obfuscation(effect.id), kind, effect.rect)
        }
        for annotation in d.annotations {
            var step: Int?
            if case .step(_, let number) = annotation.kind { step = number }
            append(
                .annotation(annotation.id), EditorItemKind(annotation.kind), EditorGeometry.frame(of: annotation),
                step: step)
        }
        for mask in d.masks {
            append(.mask(mask.id), .redaction, mask.outputRect)
        }
        for callout in d.callouts {
            let kind: EditorItemKind = if case .spotlight = callout.kind { .spotlight } else { .magnifier }
            append(.callout(callout.id), kind, EditorGeometry.frame(of: callout))
        }
        return bottomUp.reversed()
    }

    /// The topmost item at `p`, with a hit tolerance of a few view points at the current zoom.
    public func item(at p: Point<DocumentSpace>) -> EditorItemID? {
        guard p.isFinite else { return nil }
        let tolerance = viewport.documentLength(4)
        let d = session.document
        // Masks draw over everything, so a mask's own pixels win. Its tolerance band loses to every
        // other object's visible pixels, images included (and only selects, see
        // beginSelectGesture), or a drag on a visible object would move the mask off its secret.
        for mask in d.masks.reversed() where EditorGeometry.containsInclusive(mask.outputRect, p) {
            return .mask(mask.id)
        }
        for callout in d.callouts.reversed() {
            if let frame = frame(of: .callout(callout.id)),
                EditorGeometry.containsInclusive(EditorGeometry.expanded(frame, by: tolerance), p)
            {
                return .callout(callout.id)
            }
        }
        for annotation in d.annotations.reversed() where EditorGeometry.hits(annotation, at: p, tolerance: tolerance) {
            return .annotation(annotation.id)
        }
        for effect in d.obfuscations.reversed()
        where EditorGeometry.containsInclusive(EditorGeometry.expanded(effect.rect, by: tolerance), p) {
            return .obfuscation(effect.id)
        }
        for layer in d.layers.reversed() {
            if let frame = frame(of: .layer(layer.id)), EditorGeometry.containsInclusive(frame, p) {
                return .layer(layer.id)
            }
        }
        // The band applies only where nothing else is hit, image layers included (R4-07).
        for mask in d.masks.reversed()
        where EditorGeometry.containsInclusive(EditorGeometry.expanded(mask.outputRect, by: tolerance), p) {
            return .mask(mask.id)
        }
        return nil
    }

    /// Handles of the single selected item, for drawing and hit testing. Output Preview hides them,
    /// so none can be grabbed there either.
    public var selectionHandles: [(handle: EditorHandle, point: Point<DocumentSpace>)] {
        guard !showsOutputPreview, selection.count == 1, let item = selection.first else { return [] }
        return handles(for: item).map { (handle: $0.0, point: $0.1) }
    }

    func handles(for item: EditorItemID) -> [(EditorHandle, Point<DocumentSpace>)] {
        let d = session.document
        guard let frame = frame(of: item) else { return [] }
        switch item {
        case .annotation(let id):
            guard let annotation = d.annotations.first(where: { $0.id == id }) else { return [] }
            switch annotation.kind {
            case .arrow(let start, let end, let control):
                let endpoints: [(EditorHandle, Point<DocumentSpace>)] = [(.start, start), (.end, end)]
                guard let control else { return endpoints }
                return endpoints + [(.bend, ArrowCurve.bend(start: start, end: end, control: control))]
            case .line(let start, let end): return [(.start, start), (.end, end)]
            case .step: return []
            case .text: return EditorGeometry.handles(for: frame, cornersOnly: true)
            default: return EditorGeometry.handles(for: frame, cornersOnly: false)
            }
        case .layer(let id):
            guard let layer = d.layers.first(where: { $0.id == id }), layer.placement.rotation == 0 else { return [] }
            return EditorGeometry.handles(for: frame, cornersOnly: true)
        case .mask, .obfuscation, .callout:
            return EditorGeometry.handles(for: frame, cornersOnly: false)
        }
    }

    /// Side of the handle square the canvas fills, in view points.
    public static func handleSquareSide(increasedContrast: Bool) -> Double { increasedContrast ? 10 : 8 }

    /// Width of the stroke the canvas draws centered on a handle square's edge, in view points. A
    /// handle's hit area is the painted square: its side plus this width.
    public static func handleLineWidth(increasedContrast: Bool) -> Double { increasedContrast ? 2 : 1 }

    /// The contrast mode the canvas last drew handles in, so a handle's hit area is the drawn square.
    @ObservationIgnored public var handlesDrawnWithIncreasedContrast = false

    func handle(at p: Point<DocumentSpace>) -> (handle: EditorHandle, point: Point<DocumentSpace>)? {
        // A mask's handle grabs only on its drawn square: the wider hit radius around it could
        // start a resize from another object's visible pixels and uncover the secret.
        if case .mask = selection.first {
            let contrast = handlesDrawnWithIncreasedContrast
            let half = viewport.documentLength(
                (Self.handleSquareSide(increasedContrast: contrast) + Self.handleLineWidth(increasedContrast: contrast))
                    / 2)
            return selectionHandles.first { abs($0.point.x - p.x) <= half && abs($0.point.y - p.y) <= half }
        }
        let tolerance = viewport.documentLength(6)
        return selectionHandles.first { hypot($0.point.x - p.x, $0.point.y - p.y) <= tolerance }
    }

    // MARK: - Selection

    public func select(_ item: EditorItemID, extending: Bool = false) {
        guard !isMaskingPending, !showsOutputPreview, allItemIDs.contains(item) else { return }
        if extending {
            if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
        } else {
            selection = [item]
        }
        loadSelectedTextAppearance()
    }

    /// Replaces the selection (object list); unknown items are ignored.
    public func setSelection(_ items: Set<EditorItemID>) {
        guard !isMaskingPending, !showsOutputPreview else { return }
        let existing = Set(allItemIDs)
        selection = items.filter(existing.contains)
        loadSelectedTextAppearance()
    }

    public func selectAll() { setSelection(Set(allItemIDs)) }

    public func clearSelection() { selection = [] }

    public func deleteSelection() {
        let items = selection
        guard !items.isEmpty else { return }
        endContinuousChange()
        edit("Delete") { document in
            document.annotations.removeAll { items.contains(.annotation($0.id)) }
            document.layers.removeAll { items.contains(.layer($0.id)) }
            let usedAssets = Set(document.layers.map(\.assetID))
            document.assets = document.assets.filter { usedAssets.contains($0.key) }
            document.masks.removeAll { items.contains(.mask($0.id)) }
            document.obfuscations.removeAll { items.contains(.obfuscation($0.id)) }
            document.callouts.removeAll { items.contains(.callout($0.id)) }
        }
    }

    static let duplicateOffset = 10.0

    public func duplicateSelection() {
        let items = selection
        guard !items.isEmpty else { return }
        // IDs are allocated here, not in the edit closure, which must build the same document on
        // each of its passes.
        var fresh: [EditorItemID: EditorItemID] = [:]
        for item in items {
            switch item {
            case .layer: fresh[item] = .layer(LayerID())
            case .obfuscation: fresh[item] = .obfuscation(MaskID())
            case .annotation: fresh[item] = .annotation(AnnotationID())
            case .mask: fresh[item] = .mask(MaskID())
            case .callout: fresh[item] = .callout(CalloutID())
            }
        }
        let offset = Self.duplicateOffset
        endContinuousChange()
        let ok = edit("Duplicate") { document in
            for index in document.layers.indices {
                guard case .layer(let id)? = fresh[.layer(document.layers[index].id)] else { continue }
                var copy = document.layers[index]
                copy.id = id
                copy.placement.translation = copy.placement.translation.offset(dx: offset, dy: offset)
                document.layers.append(copy)
            }
            for effect in document.obfuscations {
                guard case .obfuscation(let id)? = fresh[.obfuscation(effect.id)] else { continue }
                document.obfuscations.append(
                    CosmeticObfuscation(id: id, rect: effect.rect.offsetBy(dx: offset, dy: offset), style: effect.style)
                )
            }
            for annotation in document.annotations {
                guard case .annotation(let id)? = fresh[.annotation(annotation.id)] else { continue }
                var copy = annotation.translated(dx: offset, dy: offset)
                try Self.validateArrow(copy)
                copy.id = id
                document.annotations.append(copy)
            }
            for mask in document.masks {
                guard case .mask(let id)? = fresh[.mask(mask.id)] else { continue }
                let rect = mask.outputRect.offsetBy(dx: offset, dy: offset)
                document.masks.append(
                    SecureMask(
                        id: id, outputRect: rect, sourceRegions: try document.sourceRegions(for: rect), fill: mask.fill)
                )
            }
            for callout in document.callouts {
                guard case .callout(let id)? = fresh[.callout(callout.id)] else { continue }
                document.callouts.append(
                    Callout(id: id, kind: Self.translated(callout.kind, dx: offset, dy: offset, movesSource: true)))
            }
        }
        if ok { selection = Set(fresh.values).intersection(allItemIDs) }
    }

    /// Moves the selection by whole document pixels (arrow keys: 1, with Shift: 10).
    public func nudgeSelection(dx: Double, dy: Double) {
        let items = orderedSelection
        guard !items.isEmpty, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        endContinuousChange()
        edit("Nudge") { document in
            try Self.translate(&document, items: items, dx: dx, dy: dy)
        }
    }

    public func reorderSelection(_ order: EditorZOrder) {
        let items = selection
        guard !items.isEmpty else { return }
        endContinuousChange()
        edit("Arrange") { document in
            Self.reorder(&document.layers, order) { items.contains(.layer($0.id)) }
            Self.reorder(&document.obfuscations, order) { items.contains(.obfuscation($0.id)) }
            Self.reorder(&document.annotations, order) { items.contains(.annotation($0.id)) }
            Self.reorder(&document.masks, order) { items.contains(.mask($0.id)) }
            Self.reorder(&document.callouts, order) { items.contains(.callout($0.id)) }
        }
    }

    /// Renumbers numbered steps 1…n in z-order (explicit command, FR-05).
    public func renumberSteps() {
        endContinuousChange()
        edit("Renumber Steps") { $0.annotations = $0.annotations.renumberingSteps() }
    }

    /// Selection in a stable order: layers first, so masks moved with them map correctly.
    var orderedSelection: [EditorItemID] { allItemIDs.filter(selection.contains) }

    static func reorder<Element>(_ array: inout [Element], _ order: EditorZOrder, isSelected: (Element) -> Bool) {
        guard array.contains(where: isSelected) else { return }
        switch order {
        case .front:
            array = array.filter { !isSelected($0) } + array.filter(isSelected)
        case .back:
            array = array.filter(isSelected) + array.filter { !isSelected($0) }
        case .forward:
            var index = array.count - 2
            while index >= 0 {
                if isSelected(array[index]), !isSelected(array[index + 1]) { array.swapAt(index, index + 1) }
                index -= 1
            }
        case .backward:
            var index = 1
            while index < array.count {
                if isSelected(array[index]), !isSelected(array[index - 1]) { array.swapAt(index, index - 1) }
                index += 1
            }
        }
    }

    // MARK: - Geometry changes

    static func translated(_ kind: Callout.Kind, dx: Double, dy: Double, movesSource: Bool) -> Callout.Kind {
        switch kind {
        case .spotlight(let rect, let dim):
            return .spotlight(rect.offsetBy(dx: dx, dy: dy), dimOpacity: dim)
        case .magnifier(let source, let destination):
            return .magnifier(
                source: movesSource ? source.offsetBy(dx: dx, dy: dy) : source,
                destination: destination.offsetBy(dx: dx, dy: dy))
        }
    }

    /// Translates `items` in `document`; see `move(_:by:)`.
    static func translate(_ document: inout Document, items: [EditorItemID], dx: Double, dy: Double) throws {
        try move(&document, by: Dictionary(items.map { ($0, (dx, dy)) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Moves each item by its own delta, all resolved against the same starting document, in one
    /// pass. A box never moves with a layer (the caller's edit made its coverage durable first).
    /// A mask in `deltas` is an explicit mask move and moves by whole pixels (`setMaskRect`)
    /// after the layers it may be selected with (FR-06).
    static func move(_ document: inout Document, by deltas: [EditorItemID: (dx: Double, dy: Double)]) throws {
        for index in document.layers.indices {
            guard let (dx, dy) = deltas[.layer(document.layers[index].id)] else { continue }
            document.layers[index].placement.translation =
                document.layers[index].placement.translation.offset(dx: dx, dy: dy)
        }
        for index in document.obfuscations.indices {
            guard let (dx, dy) = deltas[.obfuscation(document.obfuscations[index].id)] else { continue }
            document.obfuscations[index].rect = document.obfuscations[index].rect.offsetBy(dx: dx, dy: dy)
        }
        for index in document.annotations.indices {
            guard let (dx, dy) = deltas[.annotation(document.annotations[index].id)] else { continue }
            let moved = document.annotations[index].translated(dx: dx, dy: dy)
            try validateArrow(moved)
            document.annotations[index] = moved
        }
        for index in document.callouts.indices {
            guard let (dx, dy) = deltas[.callout(document.callouts[index].id)] else { continue }
            document.callouts[index].kind = translated(
                document.callouts[index].kind, dx: dx, dy: dy, movesSource: false)
        }
        for index in document.masks.indices {
            guard let (dx, dy) = deltas[.mask(document.masks[index].id)] else { continue }
            let mdx = dx.rounded(), mdy = dy.rounded()
            guard mdx != 0 || mdy != 0 else { continue }
            try setMaskRect(&document, index: index, document.masks[index].outputRect.offsetBy(dx: mdx, dy: mdy))
        }
    }

    /// The one path every edit and drag takes: coverage first becomes durable, then `change`
    /// runs. Returns the document after each stage, so a caller can tell a no-op from a change.
    ///
    /// An edit is an explicit mask edit only when it changes no image layer and moves or resizes
    /// masks: those masks re-bind (`setMaskRect`) and every other mask's coverage is preserved.
    /// Any edit that changes a layer (a move, resize, reorder, align or nudge, even with masks
    /// selected) preserves every mask's coverage at its pre-edit rectangle and releases nothing.
    /// `change` runs once on a copy to tell which case applies, so it must have no side effects
    /// beyond the document. A mask whose box cannot be mapped refuses only an edit that changes
    /// layers; other edits cannot uncover anything, so they still apply.
    static func applying(_ change: (inout Document) throws -> Void, to document: Document) throws
        -> (preserved: Document, updated: Document)
    {
        var trial = document
        try change(&trial)
        let changesLayers = trial.layers != document.layers
        var explicit: Set<MaskID> = []
        if !changesLayers {
            let old = Dictionary(uniqueKeysWithValues: document.masks.map { ($0.id, $0.outputRect) })
            explicit = Set(
                trial.masks.compactMap { mask in
                    old[mask.id].flatMap { $0 != mask.outputRect ? mask.id : nil }
                })
        }
        var preserved = document
        var refusal: (any Error)?
        do { try preserveCoverage(&preserved, except: explicit) } catch {
            preserved = document
            refusal = error
        }
        var updated = preserved
        try change(&updated)
        // `change` runs twice, so it must build the same document each time and touch nothing
        // else: allocate IDs before `edit`. Only the source bindings may differ, by design.
        assert(
            Self.withoutBindings(trial) == Self.withoutBindings(updated),
            "an edit closure built different documents on its trial and real passes")
        if changesLayers {
            if let refusal { throw refusal }
            let kept = Dictionary(uniqueKeysWithValues: preserved.masks.map { ($0.id, $0.sourceRegions) })
            for index in updated.masks.indices {
                for (asset, regions) in kept[updated.masks[index].id] ?? [:] {
                    let bound = updated.masks[index].sourceRegions[asset] ?? []
                    let missing = regions.filter { !bound.contains($0) }
                    if !missing.isEmpty { updated.masks[index].sourceRegions[asset] = bound + missing }
                }
            }
        }
        return (preserved, updated)
    }

    private static func withoutBindings(_ document: Document) -> Document {
        var copy = document
        for index in copy.masks.indices { copy.masks[index].sourceRegions = [:] }
        return copy
    }

    /// Before any edit: every mask other than `explicit` also binds the source pixels now under
    /// its box, including those of layers added after it, whose protection the renderer otherwise
    /// derives from the box at render time. A later edit then never uncovers what a box hides,
    /// wherever the pixels go or whichever layer showing them is removed.
    static func preserveCoverage(_ document: inout Document, except explicit: Set<MaskID> = []) throws {
        for index in document.masks.indices where !explicit.contains(document.masks[index].id) {
            for (asset, regions) in try document.sourceRegions(for: document.masks[index].outputRect) {
                let bound = document.masks[index].sourceRegions[asset] ?? []
                let added = regions.filter { !bound.contains($0) }
                if !added.isEmpty { document.masks[index].sourceRegions[asset] = bound + added }
            }
        }
    }

    /// An explicit move or resize of a mask. Its box now hides what is under the new rectangle,
    /// and it keeps the bound pixels a layer edit carried wholly or partly out of its old box in
    /// any layer: those are still hidden where they are, and only deleting the mask releases them.
    static func setMaskRect(_ document: inout Document, index: Int, _ rect: Rect<DocumentSpace>) throws {
        let snapped = EditorGeometry.outwardIntegral(rect)
        guard EditorGeometry.isFinite(snapped), !snapped.isEmpty else { throw DocumentError.invalidGeometry }
        let old = document.masks[index]
        // An unchanged rectangle keeps its binding (a click within the slop changes nothing).
        guard snapped != old.outputRect else { return }
        var regions = try document.sourceRegions(for: snapped)
        // The box as rendered is clipped to the canvas; a binding under its off-canvas part was
        // never visibly covered there, so it is judged against the visible part alone (R6-01).
        let visible = old.outputRect.intersection(document.canvasRect)
        for (asset, bound) in old.sourceRegions {
            // A binding hides the asset in every layer that shows it, so it is released only when
            // the old box wholly contains its exact document footprint in every one of them; any
            // displacement, even by a fraction of a source pixel, keeps it.
            let footprints = document.layers.compactMap { layer -> AffineMap<SourcePixelSpace, DocumentSpace>? in
                guard layer.assetID == asset, let size = document.assets[asset]?.pixelSize else { return nil }
                return layer.sourceToDocument(assetSize: size)
            }
            for region in bound
            where
                !(visible.map { box in footprints.allSatisfy { Self.contains(box, $0.apply(region.asRect)) } } ?? false)
            {
                if !(regions[asset]?.contains(region) ?? false) { regions[asset, default: []].append(region) }
            }
        }
        document.masks[index].outputRect = snapped
        document.masks[index].sourceRegions = regions
    }

    private static func contains(_ outer: Rect<DocumentSpace>, _ inner: Rect<DocumentSpace>) -> Bool {
        let e = 1e-9
        return outer.minX <= inner.minX + e && outer.minY <= inner.minY + e && outer.maxX >= inner.maxX - e
            && outer.maxY >= inner.maxY - e
    }

    /// Places `item` into `rect` (resize handles and the inspector's x/y/width/height fields).
    /// Image layers keep their aspect ratio: the width decides the uniform scale.
    static func setFrame(_ document: inout Document, item: EditorItemID, to rect: Rect<DocumentSpace>) throws {
        guard EditorGeometry.isFinite(rect), rect.width >= 0, rect.height >= 0 else {
            throw DocumentError.invalidGeometry
        }
        if rect.width == 0 || rect.height == 0 {
            guard rect.width > 0 || rect.height > 0, case .annotation(let id) = item,
                let annotation = document.annotations.first(where: { $0.id == id })
            else { throw DocumentError.invalidGeometry }
            switch annotation.kind {
            case .line, .arrow: break
            default: throw DocumentError.invalidGeometry
            }
        }
        switch item {
        case .annotation(let id):
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
            let annotation = document.annotations[index]
            guard let original = EditorGeometry.frame(of: annotation) else { throw DocumentError.invalidGeometry }
            let resized = annotation.resized(from: original, to: rect)
            guard EditorGeometry.frame(of: resized) != nil else { throw DocumentError.invalidGeometry }
            try validateArrow(resized)
            if case .line(let start, let end) = resized.kind {
                guard start.isFinite, end.isFinite, EditorGeometry.isFinite(resized.bounds) else {
                    throw DocumentError.invalidGeometry
                }
            }
            document.annotations[index] = resized
        case .layer(let id):
            guard let index = document.layers.firstIndex(where: { $0.id == id }),
                let asset = document.assets[document.layers[index].assetID]
            else { return }
            let bounds = document.layers[index].documentBounds(assetSize: asset.pixelSize)
            guard bounds.width > 0 else { throw DocumentError.invalidGeometry }
            let scale = document.layers[index].placement.scale * rect.width / bounds.width
            guard scale.isFinite, scale > 0 else { throw DocumentError.invalidScale }
            document.layers[index].placement.scale = scale
            let resized = document.layers[index].documentBounds(assetSize: asset.pixelSize)
            document.layers[index].placement.translation = document.layers[index].placement.translation.offset(
                dx: rect.minX - resized.minX, dy: rect.minY - resized.minY)
        case .mask(let id):
            guard let index = document.masks.firstIndex(where: { $0.id == id }) else { return }
            try setMaskRect(&document, index: index, rect)
        case .obfuscation(let id):
            guard let index = document.obfuscations.firstIndex(where: { $0.id == id }) else { return }
            document.obfuscations[index].rect = rect
        case .callout(let id):
            guard let index = document.callouts.firstIndex(where: { $0.id == id }) else { return }
            switch document.callouts[index].kind {
            case .spotlight(_, let dim): document.callouts[index].kind = .spotlight(rect, dimOpacity: dim)
            case .magnifier(let source, _):
                document.callouts[index].kind = .magnifier(source: source, destination: rect)
            }
        }
    }

    /// Keyboard-editable geometry for the inspector (UX-01).
    public func setFrame(_ rect: Rect<DocumentSpace>, for item: EditorItemID) {
        let isCurve: Bool
        if case .annotation(let id) = item,
            let annotation = document.annotations.first(where: { $0.id == id }),
            case .arrow(_, _, .some) = annotation.kind
        {
            isCurve = true
        } else {
            isCurve = false
        }
        edit("Set Frame") { document in
            do { try Self.setFrame(&document, item: item, to: rect) } catch {
                if isCurve { throw ArrowGeometryFailure.invalid }
                throw error
            }
        }
    }

    /// Moves a magnifier's source rectangle (what it magnifies) without moving the callout.
    public func setMagnifierSource(_ rect: Rect<DocumentSpace>, for id: CalloutID) {
        guard EditorGeometry.isFinite(rect), rect.width > 0, rect.height > 0 else { return }
        edit("Magnifier Source") { document in
            guard let index = document.callouts.firstIndex(where: { $0.id == id }),
                case .magnifier(_, let destination) = document.callouts[index].kind
            else { return }
            document.callouts[index].kind = .magnifier(source: rect, destination: destination)
        }
    }

    // MARK: - Crop and resize

    /// Reversible crop (FR-04), rounded outward to cover selected pixels and clipped to the canvas.
    public func setCrop(_ rect: Rect<DocumentSpace>?) {
        guard let rect else {
            endContinuousChange()
            edit("Reset Crop") { $0.crop = nil }
            return
        }
        guard EditorGeometry.isFinite(rect) else { return }
        let snapped = EditorGeometry.outwardIntegral(rect)
        guard let clipped = snapped.intersection(session.document.canvasRect), clipped.width >= 1, clipped.height >= 1
        else { return }
        endContinuousChange()
        edit("Crop") { $0.crop = clipped == $0.canvasRect ? nil : clipped }
    }

    public static let resizeRange: ClosedRange<Double> = 0.1...4

    /// Reversible output resize (FR-04), on top of the export scale.
    public func setResizeScale(_ scale: Double) {
        guard scale.isFinite else { return }
        let value = min(max(scale, Self.resizeRange.lowerBound), Self.resizeRange.upperBound)
        edit("Resize") { $0.resizeScale = value }
    }
}
