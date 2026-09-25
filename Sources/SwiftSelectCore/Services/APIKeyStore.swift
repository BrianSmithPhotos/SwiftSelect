import Foundation
import Security

/// Resolves API keys (eBird, OpenRouter, Gemini) from the process environment first, then falls back to
/// the macOS Keychain — replaces the environment-only rule CLAUDE.md used to document, which broke
/// for any GUI-launched process (Xcode's Run button, Finder, Dock all inherit `launchd`'s
/// environment, not a shell's `.zshrc` exports; see `docs/MLX_PROVIDER.md`-adjacent debugging from
/// 2026-07-08). Keychain was chosen over `UserDefaults` because a `UserDefaults`-backed secret is
/// a cleartext plist under `~/Library/Preferences` — not appropriate for API keys.
public enum APIKeyStore {
    /// The `kSecAttrService` lookup key for both stored keys. An opaque string, not derived from the
    /// bundle ID at runtime, so changing it strands every already-saved key and forces re-entry —
    /// which is why it stayed on the old `com.briansmithphotos.*` value long after the app moved to
    /// `photos.briansmith.*` in 2026-07 (the old domain was never owned). Realigned to the current
    /// bundle ID in 2026-07 during a deliberate keychain reset (the re-entry was already happening to
    /// re-own the items under the cert-backed signature), so the name shown in the macOS keychain
    /// prompt now matches the app. Only change it again alongside a reset that re-enters the keys.
    /// Which is why it still says `macphotomaster` after the app became SwiftSelect in 2026-09: the
    /// rename had no reason to strand the keys, so this stayed put. The keychain prompt naming the
    /// old app is the whole cost, and it is a cheap one — realign it the next time the keys are
    /// being re-entered anyway.
    ///
    /// A `var` solely so the tests (`@testable`) can point themselves at a throwaway service. They
    /// used to clear the real items and put them back instead, which re-created them under
    /// `SecItemAdd`'s default ACL — sole owner being whichever process called it, i.e. the test
    /// binary — so the app prompted on its next read, once per suite run. Worse, a `read` that came
    /// back nil made the restoring `save(nil)` a delete, so a test run could silently lose the keys.
    static var service = "photos.briansmith.macphotomaster.apikeys"

    /// Keys sync through iCloud Keychain in this access group, which the Mac and iPad apps both
    /// list in `keychain-access-groups`, so a key entered on one device appears on the other. On
    /// macOS that entitlement only works with the provisioning profile `build-app-bundle.sh` embeds.
    static let accessGroup = "U4UCUZRYBD.photos.briansmith.swiftselect"

    /// A `var` solely so `APIKeyStoreTests` can turn syncing off: `swift test` runs unsigned, with
    /// no entitlements, and the synced keychain refuses every call from it.
    static var synchronizes = true

    /// `envVar` wins when set (keeps `swift run`/terminal-launched debugging simple, matching the
    /// existing test suite's `setenv`/`unsetenv` pattern); otherwise falls back to whatever's saved
    /// in the Keychain under `account` via `SettingsView`.
    public static func resolve(envVar: String, account: String) -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment[envVar], !fromEnv.isEmpty {
            return fromEnv
        }
        return read(account: account)
    }

    /// Keys saved before syncing existed are device-only items. The first read of one copies it
    /// into the synced group and removes the original, so nothing has to be re-entered.
    public static func read(account: String) -> String? {
        if let value = readItem(query(account: account)) { return value }
        guard synchronizes, let legacy = readItem(legacyQuery(account: account)) else { return nil }
        if save(legacy, account: account) {
            SecItemDelete(legacyQuery(account: account) as CFDictionary)
        }
        return legacy
    }

    /// Passing `nil` or an empty string deletes the stored item rather than saving a blank secret.
    @discardableResult
    public static func save(_ value: String?, account: String) -> Bool {
        guard let value, !value.isEmpty else { return delete(account: account) }

        let query = query(account: account)
        let attributes = [kSecValueData as String: Data(value.utf8)]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = Data(value.utf8)
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    /// Removes the legacy item too — otherwise the next read would copy a cleared key back.
    @discardableResult
    public static func delete(account: String) -> Bool {
        let statuses = [query(account: account), legacyQuery(account: account)]
            .map { SecItemDelete($0 as CFDictionary) }
        return statuses.allSatisfy { $0 == errSecSuccess || $0 == errSecItemNotFound }
    }

    private static func readItem(_ query: [String: Any]) -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The synced item. `kSecAttrSynchronizable` also puts it in the data protection keychain on
    /// macOS, the only one iCloud syncs, instead of the file-based login keychain.
    private static func query(account: String) -> [String: Any] {
        guard synchronizes else { return legacyQuery(account: account) }
        var query = legacyQuery(account: account)
        query[kSecAttrSynchronizable as String] = true
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
    }

    /// The device-only item every key lived in before syncing. Leaving `kSecAttrSynchronizable`
    /// out matches non-synced items only.
    private static func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
