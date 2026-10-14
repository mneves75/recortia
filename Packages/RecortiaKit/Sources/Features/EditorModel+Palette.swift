import Domain

extension EditorModel {
    public var savedAnnotationColors: [RGBA] {
        annotationPalette.colors
    }

    public var canSaveStrokeColor: Bool {
        canChangeAnnotationPalette && annotationPalette.colors.count < SavedAnnotationPalette.maxColors
            && !annotationPalette.contains(style.stroke)
    }

    @discardableResult
    public func saveCurrentStrokeColor() -> Bool {
        guard canSaveStrokeColor else { return false }
        var palette = annotationPalette
        guard palette.insert(style.stroke) else { return false }
        environment.settings.update { $0.annotationPalette = palette }
        return true
    }

    @discardableResult
    public func removeSavedColor(_ color: RGBA) -> Bool {
        guard canChangeAnnotationPalette else { return false }
        var palette = annotationPalette
        guard palette.remove(color) else { return false }
        environment.settings.update { $0.annotationPalette = palette }
        return true
    }

    @discardableResult
    public func applySavedColor(_ color: RGBA) -> Bool {
        guard canChangeAnnotationPalette, annotationPalette.contains(color) else { return false }
        setStrokeColor(color.withAlpha(255))
        return true
    }

    private var annotationPalette: SavedAnnotationPalette {
        environment.settings.preferences.annotationPalette ?? SavedAnnotationPalette()
    }

    private var canChangeAnnotationPalette: Bool {
        guard !isClosed else { return false }
        if case .unsupportedSchema = environment.settings.loadIssue { return false }
        return true
    }
}
