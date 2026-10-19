import Foundation

/// Talks to the Kanban relay on the Mac (`relay/kanban_relay.py`), published on
/// the tailnet next to the gateway (default: same host, port 8651). Uses the
/// gateway's API key; the relay adds the dashboard token server-side.
final class KanbanClient: Sendable {
    let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    static let defaultPort = 8651
    /// The relay's own port on the Mac (kanban_relay listens on 127.0.0.1:8650).
    static let localPort = 8650

    static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host()?.lowercased() ?? "")
    }

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    /// Gateway `https://host:8642` → relay `https://host:8651`, unless overridden.
    static func relayURL(forGateway gateway: URL, override: String?) -> URL? {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return AppModel.normalizedURL(override)
        }
        guard var comps = URLComponents(url: gateway, resolvingAgainstBaseURL: false) else { return nil }
        // On the Mac itself (or the simulator) the relay listens on its local port; the
        // Tailscale-served HTTPS port (8651) only exists on the tailnet name.
        comps.port = isLoopback(gateway) ? localPort : defaultPort
        comps.path = ""
        comps.query = nil
        return comps.url
    }

    func boards() async throws -> [KanbanBoardInfo] {
        let r: KanbanBoardsResponse = try await get("/kanban/boards")
        return r.boards.filter { $0.archived != true }
    }

    func board(_ slug: String) async throws -> KanbanBoard {
        try await get("/kanban/board", query: ["board": slug])
    }

    func task(_ id: String, board: String) async throws -> KanbanTaskDetail {
        try await get("/kanban/tasks/\(id.pathEscaped)", query: ["board": board])
    }

    func assignees(board: String) async throws -> [String] {
        let r: KanbanAssignees = try await get("/kanban/assignees", query: ["board": board])
        return r.assignees.map(\.name)
    }

    @discardableResult
    func createTask(board: String, title: String, body: String?, assignee: String?, triage: Bool) async throws -> KanbanTaskEnvelope {
        var json: [String: Any] = ["title": title, "triage": triage]
        if let body, !body.isEmpty { json["body"] = body }
        if let assignee, !assignee.isEmpty { json["assignee"] = assignee }
        let data = try await raw("POST", "/kanban/tasks", query: ["board": board],
                                 body: try JSONSerialization.data(withJSONObject: json))
        return try HermesClient.decoder.decode(KanbanTaskEnvelope.self, from: data)
    }

    /// `fields` e.g. ["status": "done"], ["status": "blocked", "block_reason": "…"], ["assignee": "x"].
    func updateTask(_ id: String, board: String, fields: [String: String]) async throws {
        _ = try await raw("PATCH", "/kanban/tasks/\(id.pathEscaped)", query: ["board": board],
                          body: try JSONEncoder().encode(fields))
    }

    /// Edit title / details / priority (priority is an integer, so this takes JSON values).
    func editTask(_ id: String, board: String, title: String, body: String, priority: Int) async throws {
        let json: [String: Any] = ["title": title, "body": body, "priority": priority]
        _ = try await raw("PATCH", "/kanban/tasks/\(id.pathEscaped)", query: ["board": board],
                          body: try JSONSerialization.data(withJSONObject: json))
    }

    /// Permanently deletes the task (and its comments/history) from the board.
    func deleteTask(_ id: String, board: String) async throws {
        _ = try await raw("DELETE", "/kanban/tasks/\(id.pathEscaped)", query: ["board": board])
    }

    /// Stops the worker running this task and releases its claim.
    func reclaimTask(_ id: String, board: String) async throws {
        _ = try await raw("POST", "/kanban/tasks/\(id.pathEscaped)/reclaim", query: ["board": board],
                          body: try JSONEncoder().encode(["reason": "stopped from Hermes iOS"]))
    }

    func comment(_ id: String, board: String, body: String) async throws {
        _ = try await raw("POST", "/kanban/tasks/\(id.pathEscaped)/comments", query: ["board": board],
                          body: try JSONEncoder().encode(["body": body]))
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await raw("GET", path, query: query)
        return try HermesClient.decoder.decode(T.self, from: data)
    }

    private func raw(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw HermesError.badURL }
        comps.percentEncodedPath = path
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw HermesError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw HermesError.unauthorized }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw HermesError.http(http.statusCode, detail)
        }
        return data
    }
}
