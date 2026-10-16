import Domain
import Imaging

enum ArrowGeometryFailure: Error { case invalid }

extension EditorModel {
    static func validateArrowCurve(_ annotation: Annotation) throws(ArrowGeometryFailure) {
        guard case .arrow(_, _, .some) = annotation.kind else { return }
        do { _ = try ArrowLayout.make(for: annotation) } catch { throw .invalid }
    }

    public var canSetArrowCurve: Bool { !isClosed && textEditing == nil }

    public var selectedArrowBend: Point<DocumentSpace>? {
        guard selection.count == 1, let item = selection.first, case .annotation(let id) = item,
            let annotation = document.annotations.first(where: { $0.id == id }),
            case .arrow(let start, let end, let control?) = annotation.kind
        else { return nil }
        return ArrowCurve.bend(start: start, end: end, control: control)
    }

    @discardableResult
    public func setArrowBend(_ point: Point<DocumentSpace>) -> Bool {
        guard canSetArrowCurve, selection.count == 1,
            let item = selection.first, case .annotation(let id) = item,
            let annotation = document.annotations.first(where: { $0.id == id }),
            case .arrow(let start, let end, .some) = annotation.kind
        else { return false }
        guard point.isFinite else {
            post(.arrowGeometryRefused)
            return false
        }
        var changed = annotation
        changed.kind = .arrow(start: start, end: end, control: ArrowCurve.control(start: start, end: end, bend: point))
        do { try Self.validateArrowCurve(changed) } catch {
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
                guard case .arrow(let start, let end, let control) = annotation.kind else { continue }
                let proposed = curved ? control ?? ArrowCurve.defaultControl(start: start, end: end) : nil
                var changed = annotation
                changed.kind = .arrow(start: start, end: end, control: proposed)
                try Self.validateArrowCurve(changed)
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
}
