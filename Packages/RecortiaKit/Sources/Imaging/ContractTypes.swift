import CoreGraphics
import Domain
import Foundation

// Integrator-owned value types shared by Imaging, Features, and the app (module-contracts.md).
// Workers extend these in their own files; they do not edit this one.

/// A decoded image in the canonical v1 format: sRGB, 8 bits per channel, premultiplied RGBA,
/// orientation already applied exactly once.
public struct DecodedImage: Sendable {
    public let image: CGImage

    package init(image: CGImage) {
        self.image = image
    }

    public var pixelSize: PixelSize { PixelSize(width: image.width, height: image.height) }
}

public enum ImportError: Error, Equatable, Sendable {
    case tooManyBytes
    case tooManyPixels
    case invalidDimensions
    case unsupportedFormat
    case multiFrame
    case corrupt
    case unreadable
}

/// Recognized text with boxes in the recognized image's pixel space (top-left origin).
public struct OCRResult: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let text: String
        public let confidence: Float
        public let box: Rect<SourcePixelSpace>

        public init(text: String, confidence: Float, box: Rect<SourcePixelSpace>) {
            self.text = text
            self.confidence = confidence
            self.box = box
        }
    }

    public let lines: [Line]
    /// Vision request revision and languages used, recorded for OCR-01 evidence.
    public let revision: Int
    public let languages: [String]

    public init(lines: [Line], revision: Int, languages: [String]) {
        self.lines = lines
        self.revision = revision
        self.languages = languages
    }

    public var isEmpty: Bool { lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// Text in the requested mode. Never autocorrects: modes only change whitespace (FR-08).
    public func text(mode: OCRTextMode) -> String {
        switch mode {
        case .raw:
            return lines.map(\.text).joined(separator: "\n")
        case .preserveLineBreaks:
            return lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        case .normalizedWhitespace:
            return lines.map(\.text).joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
    }
}

/// A decoded QR payload. Always untrusted data: nothing opens or acts on it automatically.
public struct QRPayload: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        case webURL(URL)
        case otherScheme(String)
        case wifi
        case payment
        case binary
    }

    public let bytes: Data
    public let string: String?
    public let kind: Kind

    public init(bytes: Data, string: String?, kind: Kind) {
        self.bytes = bytes
        self.string = string
        self.kind = kind
    }
}

/// Outcome of offering one viewport frame to the scroll stitcher.
public enum ScrollAppendResult: Sendable, Equatable {
    /// New rows appended; `offset` is the vertical displacement in pixels from the previous frame.
    case accepted(offset: Int)
    /// No movement since the previous frame; nothing appended.
    case stationary
    /// Not appended; the session should pause (FR-10: never fabricate a stitch).
    case ambiguous(ScrollPauseReason)
    /// Not appended; the first reached limit ends collection.
    case limitReached(ScrollLimit)
}
