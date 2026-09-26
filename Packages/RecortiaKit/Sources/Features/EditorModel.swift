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

    // Preview (EditorModel+Preview.swift)
    public internal(set) var baseImage: CGImage?
    public internal(set) var showsOutputPreview = false
    public internal(set) var outputPreview: CGImage?
    /// Asynchronous results discarded because the document changed meanwhile (diagnostics, tests).
    public internal(set) var droppedResultCount = 0

    // Recognition (EditorModel+Recognition.swift)
    public internal(set) var recognition: EditorRecognitionState = .idle
    public internal(set) var qr: EditorQRState = .idle

    // Pixel tools (EditorModel+PixelTools.swift)
    public internal(set) var inspection: EditorColorSample?
    public internal(set) var pickedColor: EditorColorSample?
    public internal(set) var ruler: EditorMeasurement?

    @ObservationIgnored public let environment: EditorEnvironment
    @ObservationIgnored var gesture: Gesture = .idle
    @ObservationIgnored var knownAssets: Set<AssetID>
    @ObservationIgnored var hasFittedViewport = false
    @ObservationIgnored private var reportedEvictedUndoCount = 0
    @ObservationIgnored var continuousChangeOpen = false

    @ObservationIgnored var baseTask: Task<Void, Never>?
    @ObservationIgnored var installedBaseKey: BaseKey?
    @ObservationIgnored var failedBaseKey: BaseKey?
    @ObservationIgnored var outputTask: Task<Void, Never>?
    @ObservationIgnored var installedOutputKey: OutputKey?
    @ObservationIgnored var failedOutputKey: OutputKey?
    @ObservationIgnored var recognitionRequest: UUID?
    @ObservationIgnored var recognizedResult: OCRResult?
    @ObservationIgnored var qrRequest: UUID?

    enum Gesture {
        case idle
        case create(tool: EditorTool, start: Point<DocumentSpace>, points: [Point<DocumentSpace>])
        case move(items: [EditorItemID], start: Point<DocumentSpace>, original: Document)
        case resize(item: EditorItemID, handle: EditorHandle, frame: Rect<DocumentSpace>, original: Document)
        case marquee(start: Point<DocumentSpace>, initial: Set<EditorItemID>)
        case ruler(start: Point<DocumentSpace>)
        case sample
    }

    public init(session: DocumentSession, environment: EditorEnvironment) {
        self.session = session
        self.environment = environment
        knownAssets = Set(session.document.assets.keys)
        scheduleBaseRender()
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
    public func beginContinuousChange() {
        guard !continuousChangeOpen else { return }
        continuousChangeOpen = true
        session.beginGroup("Adjust")
    }

    public func endContinuousChange() {
        guard continuousChangeOpen else { return }
        continuousChangeOpen = false
        session.endGroup()
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
    @discardableResult
    func edit(_ label: String, _ change: (inout Document) throws -> Void) -> Bool {
        guard !isClosed else { return false }
        let before = session.document
        let epoch = session.privacyEpoch
        do {
            try session.perform(label, change)
        } catch {
            if error is DocumentError { post(.redactionRefused) }
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
        releaseUnreachableAssets()
        // A drag offered for the previous state must not deliver it (RED-03, EXP-02).
        environment.export.invalidatePendingDrag(documentID: session.document.id)
        let existing = Set(allItemIDs)
        selection = selection.filter(existing.contains)
        if session.privacyEpoch != epoch { privacyEpochChanged() }
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
        guard !isClosed, textEditing == nil else { return }
        cancelGesture()
        endContinuousChange()
        let before = session.document, epoch = session.privacyEpoch
        session.undo()
        didChange(from: before, epoch: epoch)
    }

    public func redo() {
        guard !isClosed, textEditing == nil else { return }
        cancelGesture()
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
    public var listItems: [EditorListItem] {
        var counters: [EditorItemKind: Int] = [:]
        var bottomUp: [EditorListItem] = []
        let d = session.document
        // Output order: layers, cosmetic effects, annotations, redactions, callouts.
        for item in allItemIDs {
            guard let kind = kind(of: item), let frame = frame(of: item) else { continue }
            counters[kind, default: 0] += 1
            var step: Int?
            if case .annotation(let id) = item, let annotation = d.annotations.first(where: { $0.id == id }),
                case .step(_, let number) = annotation.kind
            {
                step = number
            }
            bottomUp.append(
                EditorListItem(id: item, kind: kind, ordinal: counters[kind] ?? 1, frame: frame, stepNumber: step))
        }
        return bottomUp.reversed()
    }

    /// The topmost item at `p`, with a hit tolerance of a few view points at the current zoom.
    public func item(at p: Point<DocumentSpace>) -> EditorItemID? {
        guard p.isFinite else { return nil }
        let tolerance = viewport.documentLength(4)
        let d = session.document
        for callout in d.callouts.reversed() {
            if let frame = frame(of: .callout(callout.id)),
                EditorGeometry.containsInclusive(EditorGeometry.expanded(frame, by: tolerance), p)
            {
                return .callout(callout.id)
            }
        }
        for mask in d.masks.reversed()
        where EditorGeometry.containsInclusive(EditorGeometry.expanded(mask.outputRect, by: tolerance), p) {
            return .mask(mask.id)
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
        return nil
    }

    /// Handles of the single selected item, for drawing and hit testing.
    public var selectionHandles: [(handle: EditorHandle, point: Point<DocumentSpace>)] {
        guard selection.count == 1, let item = selection.first else { return [] }
        return handles(for: item).map { (handle: $0.0, point: $0.1) }
    }

    func handles(for item: EditorItemID) -> [(EditorHandle, Point<DocumentSpace>)] {
        let d = session.document
        guard let frame = frame(of: item) else { return [] }
        switch item {
        case .annotation(let id):
            guard let annotation = d.annotations.first(where: { $0.id == id }) else { return [] }
            switch annotation.kind {
            case .arrow(let start, let end): return [(.start, start), (.end, end)]
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

    func handle(at p: Point<DocumentSpace>) -> EditorHandle? {
        let tolerance = viewport.documentLength(6)
        return selectionHandles.first { hypot($0.point.x - p.x, $0.point.y - p.y) <= tolerance }?.handle
    }

    // MARK: - Selection

    public func select(_ item: EditorItemID, extending: Bool = false) {
        guard allItemIDs.contains(item) else { return }
        if extending {
            if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
        } else {
            selection = [item]
        }
    }

    /// Replaces the selection (object list); unknown items are ignored.
    public func setSelection(_ items: Set<EditorItemID>) {
        let existing = Set(allItemIDs)
        selection = items.filter(existing.contains)
    }

    public func selectAll() { selection = Set(allItemIDs) }

    public func clearSelection() { selection = [] }

    public func deleteSelection() {
        let items = selection
        guard !items.isEmpty else { return }
        edit("Delete") { document in
            document.annotations.removeAll { items.contains(.annotation($0.id)) }
            document.layers.removeAll { items.contains(.layer($0.id)) }
            document.masks.removeAll { items.contains(.mask($0.id)) }
            document.obfuscations.removeAll { items.contains(.obfuscation($0.id)) }
            document.callouts.removeAll { items.contains(.callout($0.id)) }
        }
    }

    public static let duplicateOffset = 10.0

    public func duplicateSelection() {
        let items = selection
        guard !items.isEmpty else { return }
        var created: Set<EditorItemID> = []
        let offset = Self.duplicateOffset
        let ok = edit("Duplicate") { document in
            created = []
            for index in document.layers.indices where items.contains(.layer(document.layers[index].id)) {
                var copy = document.layers[index]
                copy.id = LayerID()
                copy.placement.translation = copy.placement.translation.offset(dx: offset, dy: offset)
                document.layers.append(copy)
                created.insert(.layer(copy.id))
            }
            for effect in document.obfuscations where items.contains(.obfuscation(effect.id)) {
                let copy = CosmeticObfuscation(rect: effect.rect.offsetBy(dx: offset, dy: offset), style: effect.style)
                document.obfuscations.append(copy)
                created.insert(.obfuscation(copy.id))
            }
            for annotation in document.annotations where items.contains(.annotation(annotation.id)) {
                var copy = annotation.translated(dx: offset, dy: offset)
                copy.id = AnnotationID()
                document.annotations.append(copy)
                created.insert(.annotation(copy.id))
            }
            for mask in document.masks where items.contains(.mask(mask.id)) {
                let rect = mask.outputRect.offsetBy(dx: offset, dy: offset)
                let copy = SecureMask(
                    outputRect: rect, sourceRegions: try document.sourceRegions(for: rect), fill: mask.fill)
                document.masks.append(copy)
                created.insert(.mask(copy.id))
            }
            for callout in document.callouts where items.contains(.callout(callout.id)) {
                let copy = Callout(kind: Self.translated(callout.kind, dx: offset, dy: offset, movesSource: true))
                document.callouts.append(copy)
                created.insert(.callout(copy.id))
            }
        }
        if ok { selection = created }
    }

    /// Moves the selection by whole document pixels (arrow keys: 1, with Shift: 10).
    public func nudgeSelection(dx: Double, dy: Double) {
        let items = orderedSelection
        guard !items.isEmpty, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        edit("Nudge") { document in try Self.translate(&document, items: items, dx: dx, dy: dy) }
    }

    public func reorderSelection(_ order: EditorZOrder) {
        let items = selection
        guard !items.isEmpty else { return }
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

    /// Translates `items` in `document`. Layers move first so moved masks map onto their new
    /// positions; masks move by whole pixels and re-derive their source regions (FR-06).
    static func translate(_ document: inout Document, items: [EditorItemID], dx: Double, dy: Double) throws {
        let set = Set(items)
        for index in document.layers.indices where set.contains(.layer(document.layers[index].id)) {
            document.layers[index].placement.translation =
                document.layers[index].placement.translation.offset(dx: dx, dy: dy)
        }
        for index in document.obfuscations.indices where set.contains(.obfuscation(document.obfuscations[index].id)) {
            document.obfuscations[index].rect = document.obfuscations[index].rect.offsetBy(dx: dx, dy: dy)
        }
        for index in document.annotations.indices where set.contains(.annotation(document.annotations[index].id)) {
            document.annotations[index] = document.annotations[index].translated(dx: dx, dy: dy)
        }
        for index in document.callouts.indices where set.contains(.callout(document.callouts[index].id)) {
            document.callouts[index].kind = translated(
                document.callouts[index].kind, dx: dx, dy: dy, movesSource: false)
        }
        let mdx = dx.rounded(), mdy = dy.rounded()
        if mdx != 0 || mdy != 0 {
            for index in document.masks.indices where set.contains(.mask(document.masks[index].id)) {
                try setMaskRect(&document, index: index, document.masks[index].outputRect.offsetBy(dx: mdx, dy: mdy))
            }
        }
    }

    static func setMaskRect(_ document: inout Document, index: Int, _ rect: Rect<DocumentSpace>) throws {
        let snapped = EditorGeometry.outwardIntegral(rect)
        guard EditorGeometry.isFinite(snapped), !snapped.isEmpty else { throw DocumentError.invalidGeometry }
        document.masks[index].outputRect = snapped
        document.masks[index].sourceRegions = try document.sourceRegions(for: snapped)
    }

    /// Places `item` into `rect` (resize handles and the inspector's x/y/width/height fields).
    /// Image layers keep their aspect ratio: the width decides the uniform scale.
    static func setFrame(_ document: inout Document, item: EditorItemID, to rect: Rect<DocumentSpace>) throws {
        guard EditorGeometry.isFinite(rect), rect.width > 0, rect.height > 0 else {
            throw DocumentError.invalidGeometry
        }
        switch item {
        case .annotation(let id):
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
            let annotation = document.annotations[index]
            document.annotations[index] = annotation.resized(from: EditorGeometry.frame(of: annotation), to: rect)
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
        edit("Set Frame") { try Self.setFrame(&$0, item: item, to: rect) }
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

    /// Reversible crop (FR-04), snapped to whole document pixels and clipped to the canvas.
    public func setCrop(_ rect: Rect<DocumentSpace>?) {
        guard let rect else {
            edit("Reset Crop") { $0.crop = nil }
            return
        }
        guard EditorGeometry.isFinite(rect) else { return }
        let snapped = Rect<DocumentSpace>(
            spanning: Point(x: rect.minX.rounded(), y: rect.minY.rounded()),
            Point(x: rect.maxX.rounded(), y: rect.maxY.rounded()))
        guard let clipped = snapped.intersection(session.document.canvasRect), clipped.width >= 1, clipped.height >= 1
        else { return }
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
