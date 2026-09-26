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
    }

    public private(set) var document: Document
    /// Increments on every change, including undo and redo, so stale async results are rejected.
    public private(set) var revision: UInt64 = 0
    /// Increments whenever secure masks change. Never decreases, even when undo restores an older
    /// mask set: caches keyed by an older epoch must stay invalid (RED-03).
    public private(set) var privacyEpoch: UInt64 = 0
    public private(set) var evictedUndoCount = 0
    public let undoLimit: Int

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var openGroup: Entry?
    private var savedDocument: Document?

    public init(document: Document, undoLimit: Int = 200) {
        self.document = document
        self.undoLimit = max(1, undoLimit)
        self.savedDocument = document
    }

    public var canUndo: Bool { !undoStack.isEmpty || openGroup != nil }
    public var canRedo: Bool { !redoStack.isEmpty }
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
        if openGroup == nil {
            push(Entry(label: label, before: document))
            redoStack.removeAll()
        }
        replaceDocument(with: updated)
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
        push(group)
        redoStack.removeAll()
    }

    public mutating func undo() {
        endGroup()
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(Entry(label: entry.label, before: document))
        replaceDocument(with: entry.before)
    }

    public mutating func redo() {
        endGroup()
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(Entry(label: entry.label, before: document))
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
        if undoStack.count > undoLimit {
            let overflow = undoStack.count - undoLimit
            undoStack.removeFirst(overflow)
            evictedUndoCount += overflow
        }
    }

    private mutating func replaceDocument(with updated: Document) {
        if updated.masks != document.masks { privacyEpoch += 1 }
        document = updated
        revision += 1
    }
}
