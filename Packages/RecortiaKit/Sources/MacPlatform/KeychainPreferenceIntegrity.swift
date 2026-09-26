import CryptoKit
import Foundation
import Security

/// HMAC-SHA256 seal for the preferences blob, keyed by a random secret in the login keychain.
/// The item's access list names the app that created it, so another process cannot read the
/// secret without a user prompt; deleting the item only turns automatic export off again.
///
/// Residual (THREAT_MODEL.md): the file-based keychain cannot say who created an item, so a
/// process that plants an item under this service before Recortia creates its own can seal
/// forged consent. The app therefore calls `prepare()` at the first launch, not at the first
/// settings change. Closing the gap needs the data-protection keychain, whose access groups
/// require a Developer ID provisioning profile (TN3137).
@MainActor
public final class KeychainPreferenceIntegrity {
    private static let service = "dev.mvneves.Recortia.preferences-seal"
    private static let account = "hmac-sha256"
    private var cachedKey: SymmetricKey?

    public init() {}

    /// Creates the secret if it does not exist yet. Call it at a normal launch, not in `init`:
    /// the DEBUG-only E2E run builds the live model too and must never create keychain items.
    public func prepare() {
        _ = key(createIfMissing: true)
    }

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
