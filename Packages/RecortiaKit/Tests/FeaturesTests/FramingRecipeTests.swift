import Domain
import Foundation
import Testing

@testable import Features

@Suite("Saved framing recipe admission (FR-13)")
@MainActor
struct FramingRecipeTests {
    @Test("Invalid, duplicate and excess recipes leave the earliest valid named styles")
    func admissionOnLoadAndUpdate() throws {
        let storage = MemoryPreferenceStorage()
        let encoder = JSONEncoder()
        let style = try JSONSerialization.jsonObject(with: encoder.encode(Presentation(padding: 12)))
        let invalidStyle = try JSONSerialization.jsonObject(with: encoder.encode(Presentation(padding: 513)))
        func recipe(_ name: String, id: UUID = UUID(), presentation: Any? = nil) -> [String: Any] {
            ["id": id.uuidString, "name": name, "presentation": presentation ?? style]
        }
        let firstID = UUID()
        var entries: [Any] = [
            7, recipe(" \n "), recipe("Invalid framing", presentation: invalidStyle),
            recipe("  Café  ", id: firstID), recipe("CAFE\u{301}"), recipe("Same ID", id: firstID),
        ]
        entries.append(contentsOf: (1...12).map { recipe("Recipe \($0)") })
        var blob = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(Preferences())) as? [String: Any])
        blob["framingRecipes"] = entries
        storage.values[SettingsStore.storageKey] = try JSONSerialization.data(withJSONObject: blob)

        let store = SettingsStore(storage: storage)
        #expect(store.loadIssue == nil)
        store.update { $0.captureDelaySeconds = 3 }
        let written = try #require(storage.values[SettingsStore.storageKey])
        let persisted = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let saved = try #require(persisted["framingRecipes"] as? [[String: Any]])
        #expect(saved.compactMap { $0["name"] as? String } == ["Café"] + (1...11).map { "Recipe \($0)" })
        #expect(saved.first?["id"] as? String == firstID.uuidString)
        #expect(SettingsStore(storage: storage).preferences == store.preferences)
    }
}
