import Domain
import Foundation
import LocalAuthentication
import Security

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

    private func query(_ destination: GitHubDestination) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "dev.mvneves.Recortia.github-upload",
            kSecAttrAccount: "\(destination.owner)/\(destination.repository)".lowercased(),
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: false,
            kSecUseAuthenticationContext: authentication,
        ]
    }

    public func store(_ token: String, for destination: GitHubDestination) throws(GitHubUploadFailure) {
        guard destination.isValid else { throw .invalidDestination }
        guard !token.isEmpty, token.utf8.count <= 4096, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw .missingCredential
        }
        let data = Data(token.utf8)
        let update = SecItemUpdate(query(destination) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw .credentialsUnavailable }
        var add = query(destination)
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw .credentialsUnavailable }
    }

    public func load(for destination: GitHubDestination) throws(GitHubUploadFailure) -> String {
        guard destination.isValid else { throw .invalidDestination }
        var request = query(destination)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let resultCode = SecItemCopyMatching(request as CFDictionary, &result)
        if resultCode == errSecItemNotFound { throw .missingCredential }
        guard resultCode == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8)
        else { throw .credentialsUnavailable }
        return token
    }

    public func remove(for destination: GitHubDestination) throws(GitHubUploadFailure) {
        guard destination.isValid else { throw .invalidDestination }
        let result = SecItemDelete(query(destination) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw .credentialsUnavailable }
    }
}
