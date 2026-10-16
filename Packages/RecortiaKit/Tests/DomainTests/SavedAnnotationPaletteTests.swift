import Domain
import Foundation
import Testing

@Suite("Saved annotation palette (FR-05, FR-14)")
struct SavedAnnotationPaletteTests {

    @Test("Decoded saved colors normalize opacity and RGB duplicates, then reload unchanged")
    func decodingAndReload() throws {
        let data = Data(
            """
            [{"r":229,"g":57,"b":53,"a":10},
             {"r":229,"g":57,"b":53,"a":200},
             {"r":255,"g":214,"b":0,"a":0}]
            """.utf8)
        let palette = try JSONDecoder().decode(SavedAnnotationPalette.self, from: data)
        #expect(palette.colors == [.red, .yellow])
        let encoded = try JSONEncoder().encode(palette)
        #expect(try JSONDecoder().decode(SavedAnnotationPalette.self, from: encoded) == palette)
    }

    @Test(
        "Oversized arrays fail on their size before even a malformed thirteenth color is decoded",
        arguments: ["{\"r\":1,\"g\":2,\"b\":3,\"a\":255}"])
    func oversizedArray(_ lastColor: String) {
        let repeated = Array(repeating: "{\"r\":0,\"g\":0,\"b\":0,\"a\":255}", count: 12)
        let data = Data(("[" + repeated.joined(separator: ",") + "," + lastColor + "]").utf8)
        do {
            _ = try JSONDecoder().decode(SavedAnnotationPalette.self, from: data)
            Issue.record("An array with more than 12 entries must be refused")
        } catch DecodingError.dataCorrupted {
            // Size validation runs before any entry, even when RGB values would deduplicate.
        } catch {
            Issue.record("The size must be refused before decoding malformed entries: \(error)")
        }
    }

}
