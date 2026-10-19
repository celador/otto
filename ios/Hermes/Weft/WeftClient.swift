import Foundation
import Security

/// Where the Weft gateway is and the token that reads it. The token is an observer token
/// (read-only) or a human token (also allows approve / undo / pause / message, spec §3).
struct WeftConfig: Codable, Equatable, Sendable {
    var baseURL: URL
    var token: String
    /// Where it came from. Items saved before auto-config have none: they were typed in (manual).
    enum Source: String, Codable, Sendable { case manual, auto }
    var source: Source?
    /// "human" / "observe" when the Hermes host said so (auto-config).
    var scope: String?

    init(baseURL: URL, token: String, source: Source? = .manual, scope: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.source = source
        self.scope = scope
    }

    var isAuto: Bool { source == .auto }
}

/// Weft settings live in their own Keychain item (device-only, never synced).
/// On macOS that's the data protection keychain (SecureStore): no login-keychain password prompts.
enum WeftKeychain {
    private static let service = "ai.elier.hermes.weft"
    private static let account = "default"

    static func load() -> WeftConfig? {
        guard let data = SecureStore.read(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(WeftConfig.self, from: data)
    }

    static func save(_ config: WeftConfig) throws {
        let data = try JSONEncoder().encode(config)
        let status = SecureStore.write(service: service, account: account, data: data)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func clear() {
        SecureStore.delete(service: service, account: account)
    }
}

enum WeftError: LocalizedError, Equatable {
    case badURL
    case unauthorized
    case readOnly
    case protocolError(code: String, message: String, status: Int)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: "That Weft address isn't valid."
        case .unauthorized: "Weft rejected the token."
        case .readOnly: "This token can only read. Approve, undo, pause and messages need a human token."
        case .protocolError(_, let message, _): message
        case .http(let s): "Weft answered HTTP \(s)."
        }
    }
}

/// HTTPS + WebSocket client for the WCP observer and human API (spec §9).
final class WeftClient: Sendable {
    static let protocolVersion = "0.1"
    let config: WeftConfig
    private let session: URLSession

    init(config: WeftConfig) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    // MARK: Observer API

    func repos() async throws -> [WeftRepo] {
        let list: WeftRepoList = try await get("/v1/repos")
        return list.repos
    }

    /// `after` mode (ascending, resume), `tail` (newest `limit`), or `before` (scroll-back).
    func events(repo: String, after: Int? = nil, before: Int? = nil, tail: Bool = false, limit: Int = 200) async throws -> WeftEventPage {
        var q: [String: String] = ["limit": String(limit)]
        if let after { q["after"] = String(after) }
        if let before { q["before"] = String(before) }
        if tail { q["tail"] = "1" }
        return try await get("/v1/repos/\(repo.weftEscaped)/events", query: q)
    }

    /// Combined change log across every repo the token can see (spec §9.5): one request instead
    /// of a socket per repo. `tail` returns the newest `limit` records with a cursor at every
    /// repo's head; otherwise the records after the opaque per-repo cursor, oldest first.
    func feed(after cursor: String?, tail: Bool = false, limit: Int = 300) async throws -> WeftFeedPage {
        var q: [String: String] = ["limit": String(limit)]
        if tail { q["tail"] = "1" } else if let cursor { q["after"] = cursor }
        return try await get("/v1/feed", query: q)
    }

    /// Full record: diff, payload, transcript pointer.
    func event(repo: String, seq: Int) async throws -> WeftEvent {
        try await get("/v1/repos/\(repo.weftEscaped)/events/\(seq)")
    }

    func streamURL(repo: String, after: Int) -> URL? {
        guard var c = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.percentEncodedPath = c.percentEncodedPath + "/v1/repos/\(repo.weftEscaped)/stream"
        c.queryItems = [URLQueryItem(name: "after", value: String(after))]
        return c.url
    }

    /// Observer stream (spec §9.4). Auth goes in the upgrade request, never the URL.
    func openStream(repo: String, after: Int) -> URLSessionWebSocketTask? {
        guard let url = streamURL(repo: repo, after: after) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.protocolVersion, forHTTPHeaderField: "WCP-Version")
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = 4 * 1024 * 1024
        return task
    }

    // MARK: Human API (spec §9.6)

    func act(repo: String, _ action: WeftAction) async throws -> WeftActionResult {
        let body = try JSONSerialization.data(withJSONObject: action.json)
        let data = try await raw("POST", "/v1/repos/\(repo.weftEscaped)/actions", body: body, isAction: true)
        return try JSONDecoder().decode(WeftActionResult.self, from: data)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await raw("GET", path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func raw(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, isAction: Bool = false) async throws -> Data {
        guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else { throw WeftError.badURL }
        comps.percentEncodedPath = comps.percentEncodedPath + path
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw WeftError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "WCP-Version")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw WeftError.unauthorized }
            if http.statusCode == 403, isAction { throw WeftError.readOnly }
            if let e = try? JSONDecoder().decode(WeftErrorBody.self, from: data) {
                throw WeftError.protocolError(code: e.error.code, message: e.error.message, status: http.statusCode)
            }
            throw WeftError.http(http.statusCode)
        }
        return data
    }
}

extension String {
    /// Path segment escaping for repo names.
    var weftEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}
