import Foundation
import Security

/// Generic-password items under the app's own service name.
enum Keychain {
    static let groqKey = "groq-api-key"
    private static let service = "com.slava.rozmova"

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Empty or nil removes the item.
    static func set(_ value: String?, for account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = baseQuery(account)
        item[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            Log.info("Keychain save failed: \(status)")
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
