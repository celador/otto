import Foundation
import Security

/// The TV's connection (gateway URL, relay URL, key), stored in the TV's own keychain.
struct TVConfig: Codable, Sendable, Equatable {
    var gateway: URL
    var relay: URL
    var apiKey: String

    var lite: HermesLite { HermesLite(gateway: gateway, relay: relay, apiKey: apiKey, timeout: 60) }
}

enum TVKeychain {
    private static let service = "ai.elier.hermes.tv"
    private static let account = "connection"

    static func load() -> TVConfig? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(TVConfig.self, from: data)
    }

    static func save(_ c: TVConfig?) {
        SecItemDelete(base() as CFDictionary)
        guard let c, let data = try? JSONEncoder().encode(c) else { return }
        var q = base()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly  // never restored onto another device
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// Pairing against the relay: show a code, wait for an iPhone/iPad to approve it.
struct TVPairingClient: Sendable {
    let relay: URL

    struct Start: Decodable, Sendable { let id: String; let code: String; let expires_in: Int }
    struct Poll: Decodable, Sendable { let status: String; let gateway: String?; let relay: String?; let api_key: String? }

    func start() async throws -> Start {
        var req = URLRequest(url: relay.appending(path: "tvpair/start"), timeoutInterval: 20)
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try JSONDecoder().decode(Start.self, from: data)
    }

    func poll(_ id: String) async throws -> Poll {
        var c = URLComponents(url: relay.appending(path: "tvpair/poll"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: c.url!, timeoutInterval: 20))
        try check(resp, data)
        return try JSONDecoder().decode(Poll.self, from: data)
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw HermesLite.Failure.http((resp as? HTTPURLResponse)?.statusCode ?? 0, detail)
        }
    }

    /// "nano.tailnet.ts.net", "nano.tailnet.ts.net:8651" or a full URL → relay URL (port 8651 by default).
    static func relayURL(from input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
        if c.port == nil { c.port = 8651 }
        c.path = ""
        return c.url
    }
}
