import Domain
import Imaging

extension EditorModel {
    public func reportCanvasRenderFailure() {
        guard !isClosed, notice != .previewFailed else { return }
        post(.previewFailed)
    }

    public var canSetTextAppearance: Bool { !isClosed && textEditing == nil }

    /// Admission precedes mutations and closing the previous adjustment's undo group.
    @discardableResult
    public func setTextAppearance(_ appearance: TextAppearance) -> Bool {
        guard canSetTextAppearance else { return false }
        var changes: [AnnotationID: Annotation.TextContent] = [:]
        do {
            _ = try TextLayout.nativeFont(for: appearance, size: style.fontSize)
            for annotation in document.annotations where selection.contains(.annotation(annotation.id)) {
                guard case .text(var text) = annotation.kind else { continue }
                text.appearance = appearance
                _ = try TextLayout.metrics(for: text)
                changes[annotation.id] = text
            }
        } catch { return false }
        endContinuousChange()
        if !changes.isEmpty {
            guard
                edit(
                    "Text Style",
                    { document in
                        for index in document.annotations.indices {
                            if let text = changes[document.annotations[index].id] {
                                document.annotations[index].kind = .text(text)
                            }
                        }
                    })
            else { return false }
        }
        style.textAppearance = appearance
        return true
    }

    func loadSelectedTextAppearance() {
        guard selection.count == 1, let item = selection.first, case .annotation(let id) = item,
            let annotation = document.annotations.first(where: { $0.id == id }), case .text(let text) = annotation.kind
        else { return }
        style.textAppearance = text.resolvedAppearance
        style.fontSize = text.fontSize
    }
}
