import Foundation

/// A Keychain call failed. `status` is the raw `OSStatus` from the Security framework.
import Security

/// Stores small secrets as generic-password Keychain items.
///
/// Items are readable after the first unlock and never leave this device.
/// Never log the values stored here.
struct KeychainError: Error, Equatable, CustomStringConvertible {
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}
struct KeychainStore: Sendable {
    /// The keys the app uses.
    enum Key {
        static let apiId = "tg.apiId"
        static let apiHash = "tg.apiHash"
        static let dbKey = "tg.dbKey"
    }

    static let defaultService = "io.github.alinurmi.telegramphotos"
    static let shared = KeychainStore()

    let service: String

    /// - Parameter service: Groups the items. Tests pass their own so they never touch real secrets.
    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// Returns the stored bytes, or `nil` if the key has no item.
    func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Saves the bytes for the key, replacing any existing item. Passing `nil` deletes the item.
    func set(_ data: Data?, for key: String) throws {
        guard let data else {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(for: key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    /// Returns the stored UTF-8 string, or `nil` if the key has no item or it isn't text.
    func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the string as UTF-8. Passing `nil` deletes the item.
    func setString(_ value: String?, for key: String) throws {
        try set(value.map { Data($0.utf8) }, for: key)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
