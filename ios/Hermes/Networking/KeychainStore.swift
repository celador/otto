import Foundation
import Security

/// Stores the gateway URL + API key in the Keychain (device-only, never synced).
/// On macOS that's the data protection keychain (SecureStore): no login-keychain password prompts.
enum KeychainStore {
    private static let service = "ai.elier.hermes.gateway"
    private static let account = "default"

    static func load() -> HermesConfig? {
        guard let data = SecureStore.read(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(HermesConfig.self, from: data)
    }

    static func save(_ config: HermesConfig) throws {
        let data = try JSONEncoder().encode(config)
        let status = SecureStore.write(service: service, account: account, data: data)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear() {
        SecureStore.delete(service: service, account: account)
    }
}
