import Domain
import Foundation
import LocalAuthentication
import Security

/// A GitHub token that passed `GitHubTokenStore.validatedToken`, the one place that admits a
/// token; code that receives one trusts its shape. Its description never contains the token.
public struct GitHubToken: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    let value: String

    fileprivate init(value: String) {
        self.value = value
    }

    public var description: String { "GitHubToken(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// App-scoped, non-synchronizing data-protection Keychain entries. No token in preferences,
/// logs, arguments, URLs, or exported files. No automatic unlock/access prompts.
@MainActor
public final class GitHubTokenStore {
    private let authentication: LAContext = {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }()
    public init() {}

    /// The Keychain account of a destination. GitHub names are case-insensitive, so `Owner/Repo`
    /// and `owner/repo` share one item.
    public nonisolated static func account(for destination: GitHubDestination) -> String {
        "\(destination.owner)/\(destination.repository)".lowercased()
    }

    /// Prefixes GitHub gives classic and fine-grained personal access tokens, the kinds a person
    /// can paste into Settings (docs.github.com, "About authentication to GitHub").
    nonisolated static let personalTokenPrefixes = ["ghp_", "github_pat_"]
    /// Bound on a raw paste or stored item, checked before any trimming or decoding.
    nonisolated static let maximumRawBytes = 8192

    /// Admits a pasted or stored token: surrounding whitespace is trimmed; what remains must be a
    /// personal-token prefix and more, at most 4096 bytes of printable ASCII, so no control
    /// character or space can reach a request header, or a legacy classic token.
    public nonisolated static func validatedToken(_ pasted: String) throws(GitHubUploadFailure) -> GitHubToken {
        guard pasted.utf8.count <= maximumRawBytes else { throw .invalidCredential }
        let token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw .missingCredential }
        let prefixed =
            token.utf8.count <= 4096 && token.utf8.allSatisfy({ (33...126).contains($0) })
            && personalTokenPrefixes.contains(where: { token.hasPrefix($0) && token.count > $0.count })
        guard prefixed || isLegacyClassic(token) else { throw .invalidCredential }
        return GitHubToken(value: token)
    }

    /// A classic token issued before GitHub added prefixes: exactly 40 lowercase hex characters.
    private nonisolated static func isLegacyClassic(_ token: String) -> Bool {
        token.utf8.count == 40 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func query(_ destination: GitHubDestination) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "dev.mvneves.Recortia.github-upload",
            kSecAttrAccount: Self.account(for: destination),
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: false,
            kSecUseAuthenticationContext: authentication,
        ]
    }

    public func store(_ token: GitHubToken, for destination: GitHubDestination) throws(GitHubUploadFailure) {
        guard destination.isValid else { throw .invalidDestination }
        let data = Data(token.value.utf8)
        let update = SecItemUpdate(query(destination) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw .credentialsUnavailable }
        var add = query(destination)
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw .credentialsUnavailable }
    }

    /// A stored item is admitted like a pasted token: one saved by an older build, or altered,
    /// is an invalid credential rather than something to send.
    public func load(for destination: GitHubDestination) throws(GitHubUploadFailure) -> GitHubToken {
        guard destination.isValid else { throw .invalidDestination }
        var request = query(destination)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let resultCode = SecItemCopyMatching(request as CFDictionary, &result)
        if resultCode == errSecItemNotFound { throw .missingCredential }
        guard resultCode == errSecSuccess, let data = result as? Data else { throw .credentialsUnavailable }
        // Retrieved, but too long or not text: not a token to send.
        guard data.count <= Self.maximumRawBytes, let token = String(data: data, encoding: .utf8) else {
            throw .invalidCredential
        }
        return try Self.validatedToken(token)
    }

    public func remove(for destination: GitHubDestination) throws(GitHubUploadFailure) {
        guard destination.isValid else { throw .invalidDestination }
        let result = SecItemDelete(query(destination) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw .credentialsUnavailable }
    }
}
