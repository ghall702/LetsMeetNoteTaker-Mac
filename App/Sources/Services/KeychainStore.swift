import Foundation
import Security

/// API keys live only in the macOS Keychain (never UserDefaults, files or logs).
enum KeychainStore {
    static let service = "com.georgehalltuition.lessonnotes"

    enum Account: String {
        case website = "letsmeet-api-key"
        case openAI = "openai-api-key"
    }

    enum KeychainError: LocalizedError {
        case unexpected(OSStatus)
        var errorDescription: String? {
            if case .unexpected(let s) = self {
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "status \(s)"
                return "Keychain error: \(msg)"
            }
            return nil
        }
    }

    private static func baseQuery(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.rawValue]
    }

    /// Saves the key, overwriting any existing item (never appends).
    static func set(_ value: String, for account: Account) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { delete(account); return }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw KeychainError.unexpected(status) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Lesson Notes – \(account == .website ? "Let's Meet API key" : "OpenAI API key")"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpected(addStatus) }
    }

    static func get(_ account: Account) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: Account) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
