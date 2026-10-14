import Domain
import Foundation
import Testing

@Suite("Text appearance domain metadata (FR-05)")
struct TextAppearanceTests {
    @Test("Missing and explicit standard metadata preserve the same legacy value")
    func legacyDefaults() throws {
        let legacy = Data(#"{"origin":{"x":10,"y":20},"string":"Legacy","fontSize":24,"maxWidth":90}"#.utf8)
        let explicit = Data(
            #"{"origin":{"x":10,"y":20},"string":"Legacy","fontSize":24,"maxWidth":90,"appearance":"standard"}"#.utf8)
        let decoded = try JSONDecoder().decode(Annotation.TextContent.self, from: legacy)
        let standard = try JSONDecoder().decode(Annotation.TextContent.self, from: explicit)
        #expect(decoded == standard)
        #expect(decoded.resolvedAppearance == .standard)
        #expect(standard.appearance == nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(standard)) as? [String: Any])
        #expect(object["appearance"] == nil)
    }

    @Test("Nondefault metadata survives coding, translation and resize", arguments: TextAppearance.allCases)
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

    @Test("Unknown metadata rejects explicitly")
    func unknownMetadata() {
        let unknown = Data(#"{"origin":{"x":0,"y":0},"string":"x","fontSize":24,"appearance":"future"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Annotation.TextContent.self, from: unknown) }
    }
}
