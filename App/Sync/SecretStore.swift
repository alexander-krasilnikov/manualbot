import Foundation
import Security

/// Where a secret is kept. The password of the sync account is the only one.
protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    /// Stores `value`, or removes the secret when it is `nil` or empty. `false` when it could not be stored or removed.
    @discardableResult
    func setSecret(_ value: String?, for account: String) -> Bool
}

/// Keeps secrets in the Keychain, available after the first unlock, on this device only.
struct KeychainSecretStore: SecretStore {
    var service = "com.manualbot.app.sync"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func secret(for account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ value: String?, for account: String) -> Bool {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Keeps secrets in memory only: for tests and UI-test launches, which must not touch the real Keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func secret(for account: String) -> String? { lock.withLock { secrets[account] } }

    func setSecret(_ value: String?, for account: String) -> Bool {
        lock.withLock { secrets[account] = (value?.isEmpty ?? true) ? nil : value }
        return true
    }
}
