import Foundation
import Security

/// Where session secrets live. One protocol, two impls: Keychain for real use,
/// in-memory for tests.
public protocol AmazonSecretStoring: Sendable {
    func read() -> AmazonSessionSecrets?
    func write(secrets: AmazonSessionSecrets)
    func clear()
}

/// Test double. Not for production — holds secrets in process memory only.
public final class InMemoryAmazonSecretStore: AmazonSecretStoring, @unchecked Sendable {
    private var stored: AmazonSessionSecrets?
    public init() {}
    public func read() -> AmazonSessionSecrets? { stored }
    public func write(secrets: AmazonSessionSecrets) { stored = secrets }
    public func clear() { stored = nil }
}

/// Keychain-backed store (a single generic-password item).
///
/// Why the Keychain: the cookies are account bearer tokens, so they get the OS's
/// encrypted, access-controlled store rather than a file. The item is keyed by
/// service name only (single account per machine), so `write` deletes any prior
/// item first to avoid duplicates.
public final class KeychainAmazonSecretStore: AmazonSecretStoring, @unchecked Sendable {
    public static let defaultServiceName = "io.respawn.AmazonOrderExport"
    public static let defaultAccount = "amazon-session"
    private let serviceName: String
    private let account: String

    public init(
        serviceName: String = KeychainAmazonSecretStore.defaultServiceName,
        account: String = KeychainAmazonSecretStore.defaultAccount
    ) {
        self.serviceName = serviceName
        self.account = account
    }

    public func read() -> AmazonSessionSecrets? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return try? AmazonSessionSecrets.decoded(from: data)
    }

    public func write(secrets: AmazonSessionSecrets) {
        guard let data = try? secrets.encoded() else { return }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword, kSecAttrService: serviceName,
            kSecAttrAccount: account,
        ]
    }
}
