import Domain
import Foundation
import Testing

@Suite("Text appearance domain metadata (FR-05)")
struct TextAppearanceTests {

    @Test("Nondefault metadata survives coding, translation and resize", arguments: [TextAppearance.roundedBoxed])
    func roundTrip(appearance: TextAppearance) throws {
        let content = Annotation.TextContent(
            origin: Point(x: 10, y: 20), string: "Água🙂", fontSize: 450,
            maxWidth: 90, appearance: appearance)
        let encoded = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode(Annotation.TextContent.self, from: encoded) == content)
        let annotation = Annotation(kind: .text(content), style: .default)
        guard case .text(let moved) = annotation.translated(dx: 3, dy: 4).kind,
            case .text(let resized) = annotation.resized(
                from: Rect(x: 10, y: 20, width: 90, height: 40),
                to: Rect(x: 10, y: 20, width: 180, height: 80)
            ).kind
        else { Issue.record("Expected text"); return }
        #expect(moved.resolvedAppearance == appearance)
        #expect(resized.resolvedAppearance == appearance)
        #expect(resized.fontSize == 900)
    }

}
