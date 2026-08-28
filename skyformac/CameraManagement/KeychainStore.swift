import Foundation
import Security

/// A minimal generic-password Keychain wrapper — used for API keys (`AppSettings.anthropicAPIKey`/
/// `geminiAPIKey`) specifically, which don't belong in `UserDefaults`'s own plist (readable by
/// anything with access to the user's home folder) the way a plain server URL or model name does.
enum KeychainStore {
    /// `nil` if nothing is stored yet, or the Keychain read itself fails for any reason (a
    /// deliberately silent fallback — the caller just treats it as "not configured," the same as
    /// if the user had never entered a key at all, rather than surfacing a Keychain-specific error
    /// for what's ultimately an optional feature).
    static func string(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `nil`/empty deletes any existing entry instead of storing an empty string — "clear the API
    /// key field" should actually forget it, not save a blank secret.
    static func set(_ value: String?, forKey key: String) {
        guard let value, !value.isEmpty else {
            SecItemDelete(baseQuery(forKey: key) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        var query = baseQuery(forKey: key)
        query[kSecValueData as String] = data
        // Try adding first; a second save for the same key needs an update instead, since
        // `SecItemAdd` fails with `errSecDuplicateItem` if an entry already exists.
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else { return }
        let updateQuery = baseQuery(forKey: key)
        SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.giulioroggero.skyformac.ai",
            kSecAttrAccount as String: key,
        ]
    }
}
