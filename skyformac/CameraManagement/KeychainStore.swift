import Foundation
import Security

/// A minimal generic-password store — used for API keys (`AppSettings.anthropicAPIKey`/
/// `geminiAPIKey`/`geminiVertexServiceAccountJSON`) specifically, which don't belong in
/// `UserDefaults`'s own plist (readable by anything with access to the user's home folder) the
/// way a plain server URL or model name does. Two backends, chosen at compile time:
///
/// - **Release** (`#else` below): the real macOS Keychain, via `SecItem*`.
/// - **Debug** (local development builds, this file's own `#if DEBUG` branch): a plain,
///   user-only-readable JSON file instead. A local dev build is ad-hoc signed with no stable Team
///   ID (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""` in the project's own build settings)
///   — every `xcodebuild`/Xcode rebuild produces a binary with a *different* code-signing
///   identity, and the Keychain's own access-control list is tied to that identity, so it can
///   never remember "Always Allow" across a rebuild; confirmed live, it re-prompts on every single
///   relaunch after any rebuild no matter how many times that's clicked. Storing to a plain file
///   instead sidesteps that entirely for local iteration. This is a deliberate trade of the
///   Keychain's OS-level encryption for dev convenience — real distributed builds (properly
///   signed, built via the `Release` configuration this app's own "Ad-hoc manual releases"
///   process — see `docs/distribution.md` — actually ships) keep using the real Keychain
///   unchanged.
enum KeychainStore {
    #if DEBUG
    private static let credentialsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skyformac", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return base
    }()

    /// Not named anything with "keychain" in it — this deliberately is *not* one, and a stray
    /// glance at `~/Library/Application Support/Skyformac` shouldn't suggest otherwise.
    private static var credentialsFileURL: URL {
        credentialsDirectory.appendingPathComponent("dev-credentials.json")
    }

    /// Guards every read-modify-write against the shared file — real `SecItem*` calls are already
    /// atomic per-key, but a plain "load the whole file, mutate one key, write the whole file
    /// back" isn't: two concurrent `set(_:forKey:)` calls (confirmed live via the test suite's own
    /// parallel test execution — one call's write was silently lost, clobbered by another call's
    /// stale in-memory copy saving over it) can race without this.
    private static let lock = NSLock()

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: credentialsFileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveAll(_ credentials: [String: String]) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? data.write(to: credentialsFileURL, options: .atomic)
        // `.atomic` writes create a fresh file each time (via a temp-file-then-rename), which
        // doesn't inherit any permissions set on a previous version — set them explicitly on
        // every save rather than only once at file creation.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFileURL.path)
    }

    static func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[key]
    }

    static func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var credentials = loadAll()
        if let value, !value.isEmpty {
            credentials[key] = value
        } else {
            credentials.removeValue(forKey: key)
        }
        saveAll(credentials)
    }
    #else
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
    #endif
}
