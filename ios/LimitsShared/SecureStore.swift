import Foundation
import Security

/// Generic-password Keychain items (relay, gateway and Weft credentials, cached snapshots).
///
/// macOS: items live in the data protection keychain (`kSecUseDataProtectionKeychain`). Access there
/// is by team + keychain access group, not by the exact binary, so a rebuilt or re-signed Otto never
/// shows the "wants to use your confidential information … enter the login keychain password" prompt.
/// The gateway and Weft items an older Otto left in the legacy login keychain are moved over once (that
/// legacy read is the only place macOS can still ask, at most once per item, never again after the
/// move is tried). SharedVault doesn't move anything: the app rewrites the relay at launch and the
/// limits snapshot is a cache.
/// Debug Mac builds without keychain entitlements (unsigned, errSecMissingEntitlement) keep the items
/// in a file in the app's own sandbox container instead, so Otto Dev never prompts either.
///
/// iOS / watchOS / tvOS: unchanged plain SecItem calls.
enum SecureStore {
    /// `group` nil = the app's default access group (first `keychain-access-groups` entry).
    /// `migrateLegacy` false = never look in the macOS legacy keychain (for values the app rewrites
    /// or refetches anyway, so moving them isn't worth a possible prompt).
    static func read(service: String, account: String, group: String? = nil, migrateLegacy: Bool = true) -> Data? {
        #if os(macOS)
        var q = query(service, account, group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecMissingEntitlement:
            return fileFallback ? FileVault.read(service, account) : nil
        default:
            if fileFallback, let d = FileVault.read(service, account) { return d }
            // Not in the data protection keychain yet: bring over what an older build left behind.
            guard migrateLegacy else { return nil }
            return moveLegacy(service: service, account: account, group: group)
        }
        #else
        var q = query(service, account, group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
        #endif
    }

    /// Replaces the item (nil deletes it). Returns the SecItemAdd status (errSecSuccess for a delete).
    @discardableResult
    static func write(service: String, account: String, group: String? = nil, data: Data?) -> OSStatus {
        SecItemDelete(query(service, account, group) as CFDictionary)
        #if os(macOS)
        if fileFallback { FileVault.write(service, account, nil) }
        // A deliberate write/delete supersedes anything still in the legacy keychain.
        markLegacyHandled(service, account)
        #endif
        guard let data else { return errSecSuccess }
        var attrs = query(service, account, group)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        #if os(macOS)
        if status == errSecMissingEntitlement, fileFallback {
            FileVault.write(service, account, data)
            return errSecSuccess
        }
        #endif
        return status
    }

    static func delete(service: String, account: String, group: String? = nil) {
        write(service: service, account: account, group: group, data: nil)
    }

    private static func query(_ service: String, _ account: String, _ group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let group { q[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    #if os(macOS)
    /// Debug only: unsigned builds can't reach any keychain without a prompt, so they use a file.
    /// Release builds always use the keychain.
    static var fileFallback: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Which (service, account) pairs have had their one legacy-keychain look. Kept in the app's
    /// own defaults so a denied or failed prompt is never repeated.
    private static let legacyKey = "SecureStore.legacyHandled"

    static func legacyHandled(_ service: String, _ account: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: legacyKey) ?? []).contains("\(service)/\(account)")
    }

    static func markLegacyHandled(_ service: String, _ account: String) {
        var all = UserDefaults.standard.stringArray(forKey: legacyKey) ?? []
        let id = "\(service)/\(account)"
        guard !all.contains(id) else { return }
        all.append(id)
        UserDefaults.standard.set(all, forKey: legacyKey)
    }

    /// Forget the one-time migration marks (tests).
    static func resetLegacyMarks() { UserDefaults.standard.removeObject(forKey: legacyKey) }

    #if DEBUG
    /// Tests turn the legacy move on in Debug to exercise it.
    nonisolated(unsafe) static var migrateInDebug = false
    #endif

    /// One look in the legacy login keychain; on a hit, copy into the data protection keychain and
    /// delete the old item.
    private static func moveLegacy(service: String, account: String, group: String?) -> Data? {
        guard !legacyHandled(service, account) else { return nil }
        markLegacyHandled(service, account)   // before the read: a prompt is shown at most once
        #if DEBUG
        // Otto Dev's old items belong to some earlier scratch binary: reading them is exactly the
        // prompt this avoids. Dev starts clean instead (it re-pairs / re-discovers the relay).
        if !migrateInDebug { return nil }
        #endif
        // Explicit false = the legacy keychain only. (Absent means "both" for an app that has
        // keychain entitlements, and a delete would then remove the new copy too.)
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecUseDataProtectionKeychain as String: false]
        // Is there anything at all? Attributes only: listing never prompts.
        var attrsQ = legacy
        attrsQ[kSecReturnAttributes as String] = true
        attrsQ[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(attrsQ as CFDictionary, &found) == errSecSuccess else { return nil }
        var dataQ = legacy
        dataQ[kSecReturnData as String] = true
        dataQ[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(dataQ as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        var attrs = query(service, account, group)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecMissingEntitlement, fileFallback {
            FileVault.write(service, account, data)
        } else if status != errSecSuccess {
            return data   // still usable this launch; nothing else to do
        }
        SecItemDelete(legacy as CFDictionary)
        return data
    }

    /// Debug-only store: Application Support/SecureStore/<service>/<account>, 0600, in the sandbox
    /// container (so per bundle: Otto Dev never shares it with Otto).
    enum FileVault {
        static var root: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SecureStore", isDirectory: true)
        }

        static func url(_ service: String, _ account: String) -> URL {
            root.appendingPathComponent(safe(service), isDirectory: true)
                .appendingPathComponent(safe(account))
        }

        static func read(_ service: String, _ account: String) -> Data? {
            try? Data(contentsOf: url(service, account))
        }

        static func write(_ service: String, _ account: String, _ data: Data?) {
            let u = url(service, account)
            guard let data else { try? FileManager.default.removeItem(at: u); return }
            let dir = u.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? data.write(to: u, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        }

        private static func safe(_ s: String) -> String {
            String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
        }
    }
    #endif
}
