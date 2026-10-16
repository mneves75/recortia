import Foundation

/// An editing session over one document: revision tracking, grouped command undo, and the
/// monotonic privacy epoch.
///
/// Undo stores whole `Document` values. Documents hold no pixels (assets are referenced by ID),
/// so a snapshot costs about as much as an inverse command while being impossible to get wrong.
public struct DocumentSession: Sendable {
    private struct Entry: Sendable {
        let label: String
        let before: Document
        /// Estimated unique bytes this entry retains (see `cost(from:to:)`).
        var cost = 0
    }

    public private(set) var document: Document
    /// Increments on every change, including undo and redo, so stale async results are rejected.
    public private(set) var revision: UInt64 = 0
    /// Increments whenever secure masks change. Never decreases, even when undo restores an older
    /// mask set: caches keyed by an older epoch must stay invalid (RED-03).
    public private(set) var privacyEpoch: UInt64 = 0
    public private(set) var evictedUndoCount = 0
    public let undoLimit: Int
    /// Upper bound on the estimated bytes retained by undo history (FR-04: budget undo memory).
    public let undoByteBudget: Int
    public private(set) var retainedUndoByteCost = 0

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var openGroup: Entry?
    private var savedDocument: Document?

    public static let defaultUndoByteBudget = 32 * 1024 * 1024

    public init(document: Document, undoLimit: Int = 200, undoByteBudget: Int = DocumentSession.defaultUndoByteBudget) {
        self.document = document
        self.undoLimit = max(1, undoLimit)
        self.undoByteBudget = max(0, undoByteBudget)
        self.savedDocument = document
    }

    public var canUndo: Bool { !undoStack.isEmpty || openGroup != nil }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Assets the current document or any retained undo or redo step still references; anything
    /// else can no longer come back and its pixels can be released.
    public var referencedAssetIDs: Set<AssetID> {
        var ids = Set(document.assets.keys)
        for entry in undoStack + redoStack + [openGroup].compactMap({ $0 }) {
            ids.formUnion(entry.before.assets.keys)
        }
        return ids
    }
    public var undoCount: Int { undoStack.count }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }
    public var isDirty: Bool { document != savedDocument }
    public var isGrouping: Bool { openGroup != nil }

    /// Applies `change` atomically. A throwing change leaves the session untouched; a no-op
    /// change records nothing.
    public mutating func perform(_ label: String, _ change: (inout Document) throws -> Void) throws {
        var updated = document
        try change(&updated)
        guard updated != document else { return }
        let before = document
        replaceDocument(with: updated)
        if openGroup == nil {
            push(Entry(label: label, before: before, cost: Self.cost(from: before, to: updated)))
            redoStack.removeAll()
        }
    }

    /// Starts a gesture: every `perform` until `endGroup` becomes one undo step.
    public mutating func beginGroup(_ label: String) {
        guard openGroup == nil else { return }
        openGroup = Entry(label: label, before: document)
    }

    public mutating func endGroup() {
        guard let group = openGroup else { return }
        openGroup = nil
        guard group.before != document else { return }
        var entry = group
        entry.cost = Self.cost(from: group.before, to: document)
        push(entry)
        redoStack.removeAll()
    }

    /// Abandons a gesture without adding history or discarding an existing redo path.
    public mutating func cancelGroup() {
        guard let group = openGroup else { return }
        openGroup = nil
        if document != group.before { replaceDocument(with: group.before) }
    }

    public mutating func undo() {
        endGroup()
        guard let entry = undoStack.popLast() else { return }
        retainedUndoByteCost -= entry.cost
        redoStack.append(Entry(label: entry.label, before: document, cost: entry.cost))
        replaceDocument(with: entry.before)
    }

    public mutating func redo() {
        endGroup()
        guard let entry = redoStack.popLast() else { return }
        push(Entry(label: entry.label, before: document, cost: entry.cost))
        replaceDocument(with: entry.before)
    }

    public mutating func markSaved() {
        savedDocument = document
    }

    /// Identity for a new asynchronous request against the current state.
    public func requestIdentity() -> RequestIdentity {
        RequestIdentity(documentID: document.id, revision: revision, privacyEpoch: privacyEpoch)
    }

    /// Whether a result computed for `identity` may still be applied.
    public func accepts(_ identity: RequestIdentity) -> Bool {
        identity.documentID == document.id && identity.revision == revision && identity.privacyEpoch == privacyEpoch
    }

    /// Adds an opaque secure mask over `rect`, bound to the source pixels of every layer it touches.
    @discardableResult
    public mutating func addSecureMask(covering rect: Rect<DocumentSpace>, fill: RGBA = .black) throws -> MaskID {
        guard fill.isOpaque else { throw DocumentError.translucentSecureMask }
        do { try rect.validated() } catch { throw DocumentError.invalidGeometry }
        guard !rect.isEmpty else { throw DocumentError.emptyMask }
        let regions = try document.sourceRegions(for: rect)
        let mask = SecureMask(outputRect: rect, sourceRegions: regions, fill: fill)
        try perform("Redact") { $0.masks.append(mask) }
        return mask.id
    }

    private mutating func push(_ entry: Entry) {
        undoStack.append(entry)
        retainedUndoByteCost += entry.cost
        // Evict the oldest complete entries until both the step and memory budgets hold.
        while !undoStack.isEmpty, undoStack.count > undoLimit || retainedUndoByteCost > undoByteBudget {
            retainedUndoByteCost -= undoStack.removeFirst().cost
            evictedUndoCount += 1
        }
    }

    /// Unique data an undo entry keeps alive: what the step added or removed, plus the element
    /// arrays copied into the snapshot.
    private static func cost(from before: Document, to after: Document) -> Int {
        // Payloads the step replaced or removed stay alive in the undo entry even when the new
        // ones are the same size (moving a stroke), so charge them, not just the net difference.
        let kept = Dictionary(after.annotations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let replaced = before.annotations.reduce(0) { total, annotation in
            kept[annotation.id] == annotation ? total : total + annotation.estimatedByteCost
        }
        return max(abs(before.estimatedByteCost - after.estimatedByteCost), replaced) + before.structuralByteCost
    }

    private mutating func replaceDocument(with updated: Document) {
        // Masks also cover whatever layer lies under them when rendered, so with a mask present a
        // layer or asset change can change what is hidden: derived results must go stale too.
        let coverageMayChange =
            !updated.masks.isEmpty && (updated.layers != document.layers || updated.assets != document.assets)
        if updated.masks != document.masks || coverageMayChange { privacyEpoch += 1 }
        document = updated
        revision += 1
    }
}
