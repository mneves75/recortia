import Domain
import Foundation
import Testing

@Suite("GitHub consent and preference migration")
struct GitHubPreferencesTests {
    @Test("Existing schema-1 settings load with upload off")
    func migrate() throws {
        let original = try JSONEncoder().encode(Preferences())
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json.removeValue(forKey: "githubUpload")
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.githubUpload == nil)
        #expect(!loaded.grantsSideEffects)
    }

    @Test("Unverified settings cannot authorize remote upload")
    func unverifiedConsent() {
        var preferences = Preferences()
        preferences.githubUpload = GitHubUploadPreferences(
            destination: GitHubDestination(owner: "fixture", repository: "captures"), automatic: true)
        #expect(preferences.grantsSideEffects)
        #expect(preferences.withoutSideEffectConsent.githubUpload?.automatic == false)
    }
}
