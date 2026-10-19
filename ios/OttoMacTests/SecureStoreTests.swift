import Foundation
import Security
import Testing
@testable import Otto

/// SecureStore on macOS: data protection keychain (no login-keychain prompts), the one-time move of
/// legacy login-keychain items, and the Debug file fallback for builds without keychain entitlements.
@Suite(.serialized)
struct SecureStoreTests {
    private let service = "ai.elier.hermes.tests.securestore"

    @Test func sharedVaultRoundTrip() {
        let account = "test-\(UUID().uuidString)"
        let payload = Data("relay-\(UUID().uuidString)".utf8)
        SharedVault.writeData(account, payload)
        #expect(SharedVault.readData(account) == payload)
        let next = Data("second".utf8)
        SharedVault.writeData(account, next)
        #expect(SharedVault.readData(account) == next)
        SharedVault.writeData(account, nil)
        #expect(SharedVault.readData(account) == nil)
    }

    @Test func relayRoundTrip() throws {
        let before = SharedVault.relay()
        defer { SharedVault.saveRelay(before) }
        let r = SharedVault.Relay(relay: URL(string: "http://127.0.0.1:8650")!, apiKey: "k-\(UUID().uuidString)")
        SharedVault.saveRelay(r)
        let back = try #require(SharedVault.relay())
        #expect(back.relay == r.relay)
        #expect(back.apiKey == r.apiKey)
    }

    /// Written values land in the data protection keychain when the build carries the
    /// keychain-access-groups entitlement, else (Debug, unsigned) in the sandbox file vault.
    /// Either way never in the legacy login keychain.
    @Test func writesNeverTouchLegacyKeychain() {
        let account = "dp-\(UUID().uuidString)"
        SecureStore.write(service: service, account: account, data: Data("x".utf8))
        defer { SecureStore.delete(service: service, account: account) }
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecUseDataProtectionKeychain as String: false,   // legacy only
                                     kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(legacy as CFDictionary, &out) == errSecItemNotFound)
        #expect(SecureStore.read(service: service, account: account) == Data("x".utf8))
    }

    @Test func fileVaultRoundTrip() throws {
        let account = "file/\(UUID().uuidString)"
        let url = SecureStore.FileVault.url(service, account)
        SecureStore.FileVault.write(service, account, Data("secret".utf8))
        #expect(SecureStore.FileVault.read(service, account) == Data("secret".utf8))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        // Inside this app's own container, not a shared location.
        #expect(url.path.contains("/Library/"))
        SecureStore.FileVault.write(service, account, nil)
        #expect(SecureStore.FileVault.read(service, account) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// An item an older build left in the legacy login keychain moves over once and is deleted there.
    /// (This test binary created the legacy item, so its ACL trusts us: no prompt.)
    @Test func legacyItemMigratesOnce() {
        let account = "legacy-\(UUID().uuidString)"
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecUseDataProtectionKeychain as String: false]   // legacy only
        var add = legacy
        add[kSecValueData as String] = Data("old".utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            return   // no legacy keychain available to this test host (e.g. CI without a login keychain)
        }
        SecureStore.migrateInDebug = true
        defer {
            SecureStore.migrateInDebug = false
            SecItemDelete(legacy as CFDictionary)
            SecureStore.delete(service: service, account: account)
        }
        #expect(SecureStore.read(service: service, account: account) == Data("old".utf8))
        var q = legacy
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecItemNotFound)
        // Now served from the new store.
        #expect(SecureStore.read(service: service, account: account) == Data("old".utf8))
        #expect(SecureStore.legacyHandled(service, account))
    }

    /// The legacy keychain gets exactly one look per item: a second miss never reads it again.
    @Test func legacyLookHappensOnce() {
        let account = "once-\(UUID().uuidString)"
        SecureStore.migrateInDebug = true
        defer { SecureStore.migrateInDebug = false }
        #expect(SecureStore.read(service: service, account: account) == nil)
        #expect(SecureStore.legacyHandled(service, account))
        // Put something in the legacy keychain after the look: it is ignored.
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecUseDataProtectionKeychain as String: false]   // legacy only
        var add = legacy
        add[kSecValueData as String] = Data("late".utf8)
        let added = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        defer { if added { SecItemDelete(legacy as CFDictionary) } }
        #expect(SecureStore.read(service: service, account: account) == nil)
    }
}
