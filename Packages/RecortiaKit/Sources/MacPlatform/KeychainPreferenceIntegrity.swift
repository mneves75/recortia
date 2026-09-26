import CryptoKit
import Foundation
import Security

/// HMAC-SHA256 seal for the preferences blob, keyed by a random secret in the login keychain.
/// The item's access list names the app that created it, so another process cannot read the
/// secret without a user prompt; deleting the item only turns automatic export off again.
@MainActor
public final class KeychainPreferenceIntegrity {
    private static let service = "dev.mvneves.Recortia.preferences-seal"
    private static let account = "hmac-sha256"
    private var cachedKey: SymmetricKey?

    public init() {}

    public func seal(_ data: Data) -> Data? {
        guard let key = key(createIfMissing: true) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    public func verify(_ data: Data, seal: Data) -> Bool {
        guard let key = key(createIfMissing: false) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(seal, authenticating: data, using: key)
    }

    private func key(createIfMissing: Bool) -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: Self.account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 {
            cachedKey = SymmetricKey(data: bytes)
            return cachedKey
        }
        // Any other failure (a denied prompt, a locked keychain) leaves consent unsealed: fail closed.
        guard status == errSecItemNotFound, createIfMissing else { return nil }
        let secret = SymmetricKey(size: .bits256)
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: Self.account,
            kSecAttrLabel: "Recortia preferences seal", kSecValueData: secret.withUnsafeBytes { Data($0) },
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        cachedKey = secret
        return secret
    }
}
