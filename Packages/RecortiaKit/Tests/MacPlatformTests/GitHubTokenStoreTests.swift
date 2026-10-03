import Domain
import Foundation
import Testing

@testable import MacPlatform

// Token entry rules that run before any Keychain call. No test reads or writes Keychain.
@Suite("GitHub token entry: pasted whitespace and Keychain account")
struct GitHubTokenStoreTests {
    @Test(
        "surrounding whitespace and newlines from a paste are trimmed before validation",
        arguments: [" ghp_abc123", "ghp_abc123\n", "\t ghp_abc123 \r\n", "\u{00A0}ghp_abc123\u{2003}"])
    func trimsSurroundingWhitespace(pasted: String) throws {
        #expect(try GitHubTokenStore.validatedToken(pasted) == "ghp_abc123")
    }

    @Test("a token that is empty or only whitespace is a missing credential", arguments: ["", " ", "\n\t \r\n"])
    func rejectsEmpty(pasted: String) {
        #expect(throws: GitHubUploadFailure.missingCredential) { try GitHubTokenStore.validatedToken(pasted) }
    }

    @Test(
        "whitespace inside the token, non-ASCII, and oversize tokens stay rejected",
        arguments: ["ghp abc", "ghp\nabc", "ghp_äbc", String(repeating: "a", count: 4097)])
    func rejectsMalformed(pasted: String) {
        #expect(throws: GitHubUploadFailure.missingCredential) { try GitHubTokenStore.validatedToken(pasted) }
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
