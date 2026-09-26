import CryptoKit
import Foundation
import OSLog
import Security

/// The seal secret and the generation of the latest sealed preferences blob.
public struct SealSecret: Equatable, Sendable {
    public var key: Data
    public var generation: UInt64

    public init(key: Data, generation: UInt64) {
        self.key = key
        self.generation = generation
    }
}

/// Where the seal secret lives. Production: `DataProtectionSealStore`.
@MainActor
public protocol SealSecretStore: AnyObject {
    func load() -> SealSecret?
    /// Returns false when the secret could not be stored.
    func save(_ secret: SealSecret) -> Bool
}

/// HMAC-SHA256 over the generation and the preferences blob. Each seal advances the generation
/// kept with the secret, so only the latest blob verifies: an older sealed blob restored by
/// another process (a replay of consent the user since turned off) fails. A missing or replaced
/// secret fails closed.
@MainActor
public final class PreferenceSeal {
    private let store: any SealSecretStore

    public init(store: any SealSecretStore) {
        self.store = store
    }

    /// Creates the secret if it does not exist yet.
    public func prepare() {
        guard store.load() == nil else { return }
        _ = store.save(SealSecret(key: Self.newKey(), generation: 0))
    }

    public func seal(_ data: Data) -> Data? {
        let current = store.load() ?? SealSecret(key: Self.newKey(), generation: 0)
        let next = SealSecret(key: current.key, generation: current.generation &+ 1)
        guard store.save(next) else { return nil }
        return Self.mac(next, data)
    }

    public func verify(_ data: Data, seal: Data) -> Bool {
        guard let secret = store.load(), secret.key.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            seal, authenticating: Self.message(secret.generation, data), using: SymmetricKey(data: secret.key))
    }

    private static func mac(_ secret: SealSecret, _ data: Data) -> Data {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: message(secret.generation, data), using: SymmetricKey(data: secret.key)))
    }

    private static func message(_ generation: UInt64, _ data: Data) -> Data {
        withUnsafeBytes(of: generation.bigEndian) { Data($0) } + data
    }

    private static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// The seal secret in the data-protection keychain. Its items belong to the app's keychain access
/// group, which only code signed with Recortia's provisioned entitlement can create, read, change,
/// or delete; another same-user process cannot plant, replace, or roll back the secret. Without the
/// entitlement (Debug builds) every call fails, so consent then lasts only for the session.
@MainActor
public final class DataProtectionSealStore: SealSecretStore {
    private static let service = "dev.mvneves.Recortia.preferences-seal"
    private static let account = "hmac-sha256+generation"

    public init() {}

    private var base: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: Self.account,
            kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: false,
        ]
    }

    public func load() -> SealSecret? {
        var query = base
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let bytes = result as? Data,
            bytes.count == 40
        else { return nil }
        let generation = bytes.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return SealSecret(key: bytes.prefix(32), generation: generation)
    }

    public func save(_ secret: SealSecret) -> Bool {
        guard secret.key.count == 32 else { return false }
        let bytes = secret.key + withUnsafeBytes(of: secret.generation.bigEndian) { Data($0) }
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData: bytes] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            Self.log.error("preferences seal: update failed, status \(update, privacy: .public)")
            return false
        }
        var add = base
        add[kSecValueData] = bytes
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel] = "Recortia preferences seal"
        let status = SecItemAdd(add as CFDictionary, nil)
        // Content-free: only whether the protected store works on this build.
        if status == errSecSuccess {
            Self.log.notice("preferences seal: secret created in the data-protection keychain")
        } else {
            Self.log.error("preferences seal: create failed, status \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    private static let log = Logger(subsystem: "dev.mvneves.Recortia", category: "preferences")
}

/// The app's preferences integrity: `PreferenceSeal` over `DataProtectionSealStore`.
@MainActor
public final class KeychainPreferenceIntegrity {
    private let preferenceSeal = PreferenceSeal(store: DataProtectionSealStore())

    public init() {}

    /// Creates the secret if needed and removes the 0.9.0-beta1/beta2 file-based keychain item,
    /// which another process could replace. Call it at a normal launch, never from E2E runs.
    public func prepare() {
        preferenceSeal.prepare()
        let legacy: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "dev.mvneves.Recortia.preferences-seal",
            kSecAttrAccount: "hmac-sha256",
        ]
        SecItemDelete(legacy as CFDictionary)
    }

    public func seal(_ data: Data) -> Data? { preferenceSeal.seal(data) }

    public func verify(_ data: Data, seal: Data) -> Bool { preferenceSeal.verify(data, seal: seal) }
}
