import Domain
import Features
import Foundation

/// Locale-aware numbers for measurements and geometry. Pixel values are document pixels; points
/// appear only when the model knows the capture scale (FR-11).
enum EditorFormat {
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func measurement(_ m: EditorMeasurement) -> String {
        let pixels = String(
            localized: "\(number(m.dxPixels)) × \(number(m.dyPixels)) px, distance \(number(m.distancePixels)) px",
            table: "Editor")
        guard let dx = m.dxPoints, let dy = m.dyPoints else { return pixels }
        let points = String(localized: "\(number(dx)) × \(number(dy)) pt", table: "Editor")
        return pixels + " (" + points + ")"
    }

    static func frame(_ rect: Rect<DocumentSpace>) -> String {
        String(
            localized:
                "x \(number(rect.minX)), y \(number(rect.minY)), \(number(rect.width)) × \(number(rect.height)) px",
            table: "Editor")
    }

    static func size(_ size: Size<DocumentSpace>) -> String {
        String(localized: "\(number(size.width)) × \(number(size.height)) px", table: "Editor")
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
