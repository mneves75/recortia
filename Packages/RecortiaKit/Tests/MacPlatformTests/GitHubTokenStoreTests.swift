import Domain
import Foundation
import Security
import Testing

@testable import MacPlatform

// Token entry rules that run before any Keychain call. No test reads or writes Keychain.
// Nothing to admit is a missing credential; text that fails admission is an invalid one.
@Suite("GitHub token entry: pasted whitespace and Keychain account")
struct GitHubTokenStoreTests {
    // An update writes the same accessibility as an add, so replacing a token stored by an older
    // build never leaves it readable while the Mac is locked or restorable to another device.
    @Test("a save writes the token only with this-device, when-unlocked accessibility")
    func savedAccessibility() throws {
        let value = GitHubTokenStore.storedValue(Data("ghp_abc123".utf8))
        #expect(value[kSecValueData] as? Data == Data("ghp_abc123".utf8))
        let accessible = try #require(value[kSecAttrAccessible] as? String)
        #expect(accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(value.count == 2)
    }

    @Test(
        "surrounding whitespace and newlines from a paste are trimmed before validation",
        arguments: [" ghp_abc123", "ghp_abc123\n", "\t ghp_abc123 \r\n", "\u{00A0}ghp_abc123\u{2003}"])
    func trimsSurroundingWhitespace(pasted: String) throws {
        #expect(try GitHubTokenStore.validatedToken(pasted).value == "ghp_abc123")
    }

    @Test("a token that is empty or only whitespace is a missing credential", arguments: ["", " ", "\n\t \r\n"])
    func rejectsEmpty(pasted: String) {
        #expect(throws: GitHubUploadFailure.missingCredential) { try GitHubTokenStore.validatedToken(pasted) }
    }

    @Test(
        "whitespace inside the token, non-ASCII, and oversize tokens stay rejected",
        arguments: ["ghp abc", "ghp\nabc", "ghp_äbc", "ghp_" + String(repeating: "a", count: 4093)])
    func rejectsMalformed(pasted: String) {
        #expect(throws: GitHubUploadFailure.invalidCredential) { try GitHubTokenStore.validatedToken(pasted) }
    }

    // Synthetic strings only. GitHub starts every token with a prefix naming its type; Settings
    // asks for a personal token, so anything else is a paste of the wrong thing.
    @Test(
        "a token without a personal-token prefix is rejected",
        arguments: [
            "synthetic-token", "gho_abc123", "ghs_abc123", "GHP_abc123", "ghp", "ghp_", "github_pat_", "xghp_abc",
        ])
    func rejectsWrongPrefix(pasted: String) {
        #expect(throws: GitHubUploadFailure.invalidCredential) { try GitHubTokenStore.validatedToken(pasted) }
    }

    @Test(
        "control characters anywhere in the token are rejected, so none can reach a request header",
        arguments: ["ghp_abc\r\nX-Injected: 1", "ghp_abc\u{0}", "ghp_\u{7F}abc", "github_pat_a\u{1B}b", "ghp_a\u{85}b"])
    func rejectsControlCharacters(pasted: String) {
        #expect(throws: GitHubUploadFailure.invalidCredential) { try GitHubTokenStore.validatedToken(pasted) }
    }

    @Test("classic and fine-grained personal tokens are accepted up to the length bound")
    func acceptsPersonalTokens() throws {
        let longest = "github_pat_" + String(repeating: "a", count: 4096 - 11)
        for token in ["ghp_abc123", "github_pat_abc_123", longest] {
            #expect(try GitHubTokenStore.validatedToken(token).value == token)
        }
        #expect(throws: GitHubUploadFailure.invalidCredential) { try GitHubTokenStore.validatedToken(longest + "a") }
    }

    // Classic tokens issued before GitHub added prefixes are 40 lowercase hex characters; people
    // may still hold one, and a stored one must not read as missing.
    static let legacyHex = "0123456789abcdef0123456789abcdef01234567"

    @Test("a legacy classic token of exactly 40 lowercase hex characters is accepted")
    func acceptsLegacyClassicToken() throws {
        #expect(try GitHubTokenStore.validatedToken(Self.legacyHex).value == Self.legacyHex)
        #expect(try GitHubTokenStore.validatedToken(" \(Self.legacyHex)\n").value == Self.legacyHex)
    }

    @Test(
        "only the exact legacy shape is accepted without a prefix",
        arguments: [
            String(legacyHex.dropLast()) + "z",  // 40 characters, not all hex
            legacyHex.uppercased(),  // 40 hex characters, not lowercase
            String(legacyHex.dropLast()),  // 39 hex characters
            legacyHex + "8",  // 41 hex characters
        ])
    func rejectsNearLegacyShapes(pasted: String) {
        #expect(throws: GitHubUploadFailure.invalidCredential) { try GitHubTokenStore.validatedToken(pasted) }
    }

    // R13 (adversarial review of T1a): the length bound applied only after trimming, so a huge
    // whitespace paste was processed in full on the main actor.
    @Test("a paste longer than 8 KB is refused before it is trimmed, even if a token is inside")
    func rejectsOversizeRawPaste() {
        let padded = "ghp_abc123" + String(repeating: " ", count: 9000)
        #expect(throws: GitHubUploadFailure.invalidCredential) { try GitHubTokenStore.validatedToken(padded) }
        let atBound = "ghp_abc123" + String(repeating: " ", count: GitHubTokenStore.maximumRawBytes - 10)
        #expect(throws: Never.self) { try GitHubTokenStore.validatedToken(atBound) }
    }

    @Test("a token's description never contains the token")
    func descriptionIsRedacted() throws {
        let token = try GitHubTokenStore.validatedToken("ghp_syntheticsecret")
        var dumped = ""
        dump(token, to: &dumped)
        for text in [String(describing: token), String(reflecting: token), "\(token)", dumped] {
            #expect(!text.contains("syntheticsecret"))
        }
    }

    @Test("the account ignores case, as GitHub names do")
    func accountIgnoresCase() {
        let lower = GitHubDestination(owner: "fixture", repository: "private-captures")
        let mixed = GitHubDestination(owner: "Fixture", repository: "Private-Captures")
        let other = GitHubDestination(owner: "fixture", repository: "other")
        #expect(GitHubTokenStore.account(for: lower) == GitHubTokenStore.account(for: mixed))
        #expect(GitHubTokenStore.account(for: lower) != GitHubTokenStore.account(for: other))
    }
}
