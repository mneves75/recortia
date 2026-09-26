import CoreGraphics
import Domain
import Foundation
import Imaging

// MARK: - Tools

/// Editor tools (FR-04, FR-05, FR-06, FR-11, FR-13). The raw value is a stable identifier for
/// accessibility and tests; user-visible names live in the app's string catalog.
public enum EditorTool: String, CaseIterable, Hashable, Sendable {
    case select
    case hand
    case crop
    case text
    case arrow
    case rectangle
    case ellipse
    case freehand
    case highlighter
    case step
    /// Secure, solid redaction: replaces source pixels with an opaque fill (FR-06).
    case redact
    /// Cosmetic blur. Never secure (RED-04).
    case blur
    /// Cosmetic pixelation. Never secure: pixelation can keep recoverable text (RED-04).
    case pixelate
    case spotlight
    case magnifier
    case loupe
    case ruler
    case colorPicker

    /// Single-key shortcut, active only while no text is being edited.
    public var shortcutKey: Character {
        switch self {
        case .select: "v"
        case .hand: "h"
        case .crop: "c"
        case .text: "t"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .freehand: "p"
        case .highlighter: "m"
        case .step: "n"
        case .redact: "x"
        case .blur: "b"
        case .pixelate: "k"
        case .spotlight: "s"
        case .magnifier: "g"
        case .loupe: "l"
        case .ruler: "u"
        case .colorPicker: "i"
        }
    }

    public static func forShortcut(_ key: Character) -> EditorTool? {
        let lowered = Character(key.lowercased())
        return allCases.first { $0.shortcutKey == lowered }
    }

    /// True only for the tool that performs secure source-pixel replacement.
    public var isSecureRedaction: Bool { self == .redact }

    /// Blur and pixelation: obfuscation that must always be labeled as not secure.
    public var isCosmeticObfuscation: Bool { self == .blur || self == .pixelate }

    /// Tools whose drag creates a new object in the document.
    public var createsObject: Bool {
        switch self {
        case .text, .arrow, .rectangle, .ellipse, .freehand, .highlighter, .step, .redact, .blur, .pixelate,
            .spotlight, .magnifier:
            true
        case .select, .hand, .crop, .loupe, .ruler, .colorPicker:
            false
        }
    }

    /// Whether the tool uses stroke/fill/width/opacity style controls.
    public var usesStyle: Bool {
        switch self {
        case .text, .arrow, .rectangle, .ellipse, .freehand, .highlighter, .step, .select: true
        default: false
        }
    }
}

// MARK: - Items and selection

/// Any selectable object in the document.
public enum EditorItemID: Hashable, Sendable {
    case annotation(AnnotationID)
    case layer(LayerID)
    case mask(MaskID)
    case obfuscation(MaskID)
    case callout(CalloutID)
}

/// What an item is, for list labels, accessibility roles, and the inspector.
public enum EditorItemKind: String, Hashable, Sendable, CaseIterable {
    case text
    case arrow
    case rectangle
    case ellipse
    case freehand
    case highlighter
    case step
    case image
    case redaction
    case blur
    case pixelate
    case spotlight
    case magnifier

    /// Only a redaction is secure; blur and pixelate are cosmetic (RED-04).
    public var isSecure: Bool { self == .redaction }
    public var isCosmetic: Bool { self == .blur || self == .pixelate }

    init(_ kind: Annotation.Kind) {
        switch kind {
        case .text: self = .text
        case .arrow: self = .arrow
        case .rectangle: self = .rectangle
        case .ellipse: self = .ellipse
        case .freehand: self = .freehand
        case .highlighter: self = .highlighter
        case .step: self = .step
        }
    }
}

/// One row of the accessible object list: every annotation, image layer, redaction, cosmetic
/// effect, and callout, topmost first.
public struct EditorListItem: Hashable, Sendable, Identifiable {
    public let id: EditorItemID
    public let kind: EditorItemKind
    /// 1-based index among items of the same kind, bottom to top ("Arrow 2").
    public let ordinal: Int
    public let frame: Rect<DocumentSpace>
    /// Step number for numbered steps.
    public let stepNumber: Int?
}

/// Selection handles; `start`/`end` are arrow endpoints.
public enum EditorHandle: Hashable, Sendable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end

    public var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
}

public struct EditorModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Constrains shapes to squares and resizes to the original aspect ratio; extends selection.
    public static let shift = EditorModifiers(rawValue: 1 << 0)
    public static let option = EditorModifiers(rawValue: 1 << 1)
    public static let command = EditorModifiers(rawValue: 1 << 2)
}

public enum EditorAlignment: String, Hashable, Sendable, CaseIterable {
    case left, horizontalCenter, right, top, verticalCenter, bottom
}

public enum EditorZOrder: Hashable, Sendable {
    case forward, backward, front, back
}

// MARK: - Style

/// Style applied to new annotations and, when changed, to selected ones.
public struct EditorStyle: Hashable, Sendable {
    public var stroke: RGBA
    public var fill: RGBA?
    public var lineWidth: Double
    public var opacity: Double
    public var fontSize: Double

    public init(
        stroke: RGBA = .red, fill: RGBA? = nil, lineWidth: Double = 4, opacity: Double = 1, fontSize: Double = 24
    ) {
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.fontSize = fontSize
    }

    public static let lineWidthRange: ClosedRange<Double> = 1...40
    public static let opacityRange: ClosedRange<Double> = 0.1...1
    public static let fontSizeRange: ClosedRange<Double> = 8...200

    var annotationStyle: Annotation.Style {
        Annotation.Style(stroke: stroke, fill: fill, lineWidth: lineWidth, opacity: opacity)
    }

    /// Highlighter strokes are wide and translucent, derived from the same color.
    var highlighterStyle: Annotation.Style {
        Annotation.Style(stroke: stroke, fill: nil, lineWidth: max(lineWidth * 4, 12), opacity: min(opacity, 0.5))
    }
}

// MARK: - Live gesture feedback

/// What the canvas previews while a creation gesture is in progress. Not part of the document
/// until the gesture ends.
public enum EditorDraft: Hashable, Sendable {
    case annotation(Annotation)
    /// A rectangle for crop, redaction, blur, pixelate, spotlight, magnifier, or marquee selection.
    case region(EditorTool, Rect<DocumentSpace>)
    case marquee(Rect<DocumentSpace>)
}

/// A text annotation being edited in the canvas's native text view.
public struct EditorTextEditing: Hashable, Sendable {
    /// Nil for a new annotation.
    public let annotationID: AnnotationID?
    public let origin: Point<DocumentSpace>
    public let initialString: String
    public let fontSize: Double
    public let color: RGBA
    public let maxWidth: Double?
}

// MARK: - Recognition, pixel tools, notices

public struct EditorOCRLine: Hashable, Sendable {
    public let text: String
    public let confidence: Float
    /// The line's box in document space.
    public let box: Rect<DocumentSpace>
}

public enum EditorRecognitionState: Hashable, Sendable {
    case idle
    case running
    case recognized(lines: [EditorOCRLine], languages: [String])
    /// Finished without text; the clipboard is untouched.
    case noText
    case failed
}

public enum EditorQRState: Equatable, Sendable {
    case idle
    case running
    /// Decoded payloads, always untrusted data.
    case decoded([QRPayload])
    case noCode
    case failed
}

/// A sampled document pixel, in canonical sRGB (FR-11).
public struct EditorColorSample: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let color: RGBA

    public var hex: String { color.hex }
    /// "R G B" decimal components, e.g. "26 43 60".
    public var rgbText: String { "\(color.r) \(color.g) \(color.b)" }
}

/// Ruler measurement between two anchors, in document pixels; points only when the document is a
/// single capture with a known point-to-pixel scale (imported images never get one).
public struct EditorMeasurement: Hashable, Sendable {
    public let start: Point<DocumentSpace>
    public let end: Point<DocumentSpace>
    public let pointPixelScale: Double?

    public var dxPixels: Double { abs(end.x - start.x) }
    public var dyPixels: Double { abs(end.y - start.y) }
    public var distancePixels: Double { (dxPixels * dxPixels + dyPixels * dyPixels).squareRoot() }
    public var dxPoints: Double? { pointPixelScale.map { dxPixels / $0 } }
    public var dyPoints: Double? { pointPixelScale.map { dyPixels / $0 } }
    public var distancePoints: Double? { pointPixelScale.map { distancePixels / $0 } }
}

/// Nearest-neighbor loupe pixels: an exact crop of the sanitized base, never interpolated.
public struct EditorLoupe: Sendable {
    public let image: CGImage
    /// Document pixel of the image's top-left pixel.
    public let originX: Int
    public let originY: Int
    public let centerX: Int
    public let centerY: Int
}

/// Nonblocking, content-free status the window shows as text (UX-01, PRIV-01).
public enum EditorNotice: Hashable, Sendable {
    case noTextFound
    /// English or Portuguese recognition is not available on this Mac; other languages were used.
    case recognitionLanguagesUnavailable
    case textCopied
    case copyFailed
    case recognitionFailed
    /// The document changed while recognizing; the result was discarded.
    case recognitionDiscarded
    /// A redaction changed after recognition; results were cleared.
    case recognitionInvalidated
    case noQRCodeFound
    case payloadCopied
    /// The payload is not an http(s) link; nothing was opened.
    case linkNotAllowed
    case colorCopied
    /// The sanitized preview is not current yet; try again in a moment.
    case previewNotReady
    case previewFailed
    case redactionRefused
    case importFailed(ImportFailure)
    case pinned
    case pinFailed(PinError)
    /// Pins made before a redaction change were closed.
    case pinsInvalidated(Int)
    case exported(ExportOutcome)
    case noPreferredFolder
    /// The oldest undo steps were discarded to stay within the undo budget (FR-04).
    case undoHistoryTrimmed
}
