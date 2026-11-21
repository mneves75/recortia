import Domain
import Imaging

enum ArrowGeometryFailure: Error { case invalid }

extension EditorModel {
    /// Admission for every arrow, straight or curved: one the renderer cannot lay out is refused
    /// here rather than failing or vanishing at export.
    static func validateArrow(_ annotation: Annotation) throws(ArrowGeometryFailure) {
        guard case .arrow = annotation.kind else { return }
        do { _ = try ArrowLayout.make(for: annotation) } catch { throw .invalid }
    }

    public var canSetArrowCurve: Bool { !isClosed && textEditing == nil }

    public var selectedArrowBend: Point<DocumentSpace>? {
        guard selection.count == 1, let item = selection.first, case .annotation(let id) = item,
            let annotation = document.annotations.first(where: { $0.id == id }),
            case .arrow(let start, let end, let control?, _) = annotation.kind
        else { return nil }
        return ArrowCurve.bend(start: start, end: end, control: control)
    }

    @discardableResult
    public func setArrowBend(_ point: Point<DocumentSpace>) -> Bool {
        guard canSetArrowCurve, selection.count == 1,
            let item = selection.first, case .annotation(let id) = item,
            let annotation = document.annotations.first(where: { $0.id == id }),
            case .arrow(let start, let end, .some, let head) = annotation.kind
        else { return false }
        guard point.isFinite else {
            post(.arrowGeometryRefused)
            return false
        }
        var changed = annotation
        changed.kind = .arrow(
            start: start, end: end, control: ArrowCurve.control(start: start, end: end, bend: point), head: head)
        do { try Self.validateArrow(changed) } catch {
            post(.arrowGeometryRefused)
            return false
        }
        endContinuousChange()
        return edit("Arrow Bend") { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
            document.annotations[index] = changed
        }
    }

    /// Changes selected arrows and the local future default only after all geometry is admitted.
    @discardableResult
    public func setArrowCurved(_ curved: Bool) -> Bool {
        guard canSetArrowCurve else { return false }
        var changes: [AnnotationID: Annotation.Kind] = [:]
        do {
            for annotation in document.annotations where selection.contains(.annotation(annotation.id)) {
                guard case .arrow(let start, let end, let control, let head) = annotation.kind else { continue }
                let proposed = curved ? control ?? ArrowCurve.defaultControl(start: start, end: end) : nil
                var changed = annotation
                changed.kind = .arrow(start: start, end: end, control: proposed, head: head)
                try Self.validateArrow(changed)
                if changed.kind != annotation.kind { changes[annotation.id] = changed.kind }
            }
        } catch {
            post(.arrowGeometryRefused)
            return false
        }
        endContinuousChange()
        if !changes.isEmpty {
            guard
                edit(
                    "Arrow Curve",
                    { document in
                        for index in document.annotations.indices {
                            if let kind = changes[document.annotations[index].id] {
                                document.annotations[index].kind = kind
                            }
                        }
                    })
            else { return false }
        }
        style.curvedArrows = curved
        return true
    }

    /// The head the inspector shows as chosen: the selected arrows' common head, nil when they
    /// differ, or the future default when no arrow is selected.
    public var arrowHeadState: Annotation.ArrowHead? {
        let heads = document.annotations.compactMap { annotation -> Annotation.ArrowHead? in
            guard selection.contains(.annotation(annotation.id)), case .arrow(_, _, _, let head) = annotation.kind
            else { return nil }
            return head ?? .filled
        }
        guard let first = heads.first else { return style.arrowHead }
        return heads.allSatisfy { $0 == first } ? first : nil
    }

    /// Changes the head of selected arrows (one Undo step) and the local future default, only
    /// after every changed arrow is admitted. The filled head is stored as nil, its legacy form.
    @discardableResult
    public func setArrowHead(_ head: Annotation.ArrowHead) -> Bool {
        guard canSetArrowCurve else { return false }
        let stored = head == .filled ? nil : head
        var changes: [AnnotationID: Annotation.Kind] = [:]
        do {
            for annotation in document.annotations where selection.contains(.annotation(annotation.id)) {
                guard case .arrow(let start, let end, let control, let current) = annotation.kind,
                    (current ?? .filled) != head
                else { continue }
                var changed = annotation
                changed.kind = .arrow(start: start, end: end, control: control, head: stored)
                try Self.validateArrow(changed)
                changes[annotation.id] = changed.kind
            }
        } catch {
            post(.arrowGeometryRefused)
            return false
        }
        endContinuousChange()
        if !changes.isEmpty {
            guard
                edit(
                    "Arrow Head",
                    { document in
                        for index in document.annotations.indices {
                            if let kind = changes[document.annotations[index].id] {
                                document.annotations[index].kind = kind
                            }
                        }
                    })
            else { return false }
        }
        style.arrowHead = head
        return true
    }

    /// Whether new freehand and highlighter strokes in this editor are smoothed when they end.
    /// Strokes already drawn keep their points.
    public func setStrokeSmoothing(_ smooths: Bool) {
        guard !isClosed else { return }
        style.smoothsStrokes = smooths
    }
}
