import Foundation

/// HTTP client for one Hermes API server (`gateway.api_server`).
///
/// Concrete type on purpose: no protocol + extension defaults, which have
/// silently swallowed calls in John's other apps (see ~/code/ficha/AGENTS.md §2).
final class HermesClient: Sendable {
    let config: HermesConfig
    private let session: URLSession
    private let streamSession: URLSession

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(config: HermesConfig) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
        // SSE: the server sends `: keepalive` every 10s, so a 60s idle timeout is safe.
        let s = URLSessionConfiguration.default
        s.timeoutIntervalForRequest = 60
        s.timeoutIntervalForResource = 60 * 60 * 6
        streamSession = URLSession(configuration: s)
    }

    // MARK: Connection

    func health() async throws -> Health {
        try await get("/health", authorized: false)
    }

    func capabilities() async throws -> Capabilities {
        try await get("/v1/capabilities")
    }

    // MARK: Sessions

    func sessions(limit: Int = 50, offset: Int = 0) async throws -> SessionList {
        try await get("/api/sessions", query: ["limit": "\(limit)", "offset": "\(offset)"])
    }

    func createSession(title: String? = nil) async throws -> SessionSummary {
        var body: [String: String] = [:]
        if let title { body["title"] = title }
        let env: SessionEnvelope = try await send("POST", "/api/sessions", json: body)
        return env.session
    }

    /// Branches a chat: the new session gets a copy of the history.
    func forkSession(id: String) async throws -> SessionSummary {
        let env: SessionEnvelope = try await send("POST", "/api/sessions/\(id.pathEscaped)/fork", json: [:])
        return env.session
    }

    func deleteSession(id: String) async throws {
        _ = try await raw("DELETE", "/api/sessions/\(id.pathEscaped)")
    }

    func messages(sessionID: String) async throws -> [StoredMessage] {
        let list: MessageList = try await get(
            "/api/sessions/\(sessionID.pathEscaped)/messages",
            query: ["inline_images": "false"])
        return list.data
    }

    // MARK: Runs

    /// Starts a turn. Idempotent: a retry with the same key returns the same run.
    func startRun(sessionID: String, message: OutgoingMessage, model: ModelChoice?, fast: Bool? = nil,
                  voiceFast: Bool = false, idempotencyKey: String) async throws -> RunAccepted {
        let body = Self.runBody(sessionID: sessionID, message: message, model: model, fast: fast, voiceFast: voiceFast)
        let data = try await raw("POST", "/v1/runs", body: try JSONSerialization.data(withJSONObject: body),
                                 headers: ["Idempotency-Key": idempotencyKey])
        return try Self.decoder.decode(RunAccepted.self, from: data)
    }

    /// Request body for `POST /v1/runs`. Images go as Responses-style
    /// `input_image` data URLs (verified live against Hermes 0.21.5).
    /// `fast`: nil = leave Hermes's own setting alone; true/false = this run's Fast Mode.
    /// Voice turns (`message.voice`) always run on `VoiceTurn.model` with low reasoning effort and
    /// no Honcho memory (`"memory": false`: no prefetch wait, nothing synced), for that run only (the chat's own model choice is untouched); `voiceFast` adds Fast Mode when the
    /// gateway offers it for that model.
    nonisolated static func runBody(sessionID: String, message: OutgoingMessage, model: ModelChoice?,
                                    fast: Bool? = nil, voiceFast: Bool = false) -> [String: Any] {
        var body: [String: Any] = ["session_id": sessionID]
        if message.images.isEmpty {
            body["input"] = message.text
        } else {
            var parts: [[String: Any]] = []
            if !message.text.isEmpty { parts.append(["type": "input_text", "text": message.text]) }
            for jpeg in message.images {
                parts.append(["type": "input_image",
                              "image_url": "data:image/jpeg;base64," + jpeg.base64EncodedString()])
            }
            body["input"] = [["role": "user", "content": parts]]
        }
        if let model = message.voice ? VoiceTurn.model : model {
            body["model"] = model.model
            body["provider"] = model.provider
        }
        let notes = [message.voice ? VoiceTurn.instructions : nil, message.context].compactMap { $0 }
        if !notes.isEmpty { body["instructions"] = notes.joined(separator: "\n\n") }
        if message.voice {
            var options: [String: Any] = ["reasoning_effort": VoiceTurn.reasoningEffort,
                                          "memory": VoiceTurn.memory]
            if voiceFast { options["fast"] = true }
            body["model_options"] = options
        } else if let fast {
            body["model_options"] = ["fast": fast]
        }
        return body
    }

    /// Injects guidance into the running turn (appears to the agent after its current tool).
    func steer(runID: String, text: String) async throws {
        _ = try await raw("POST", "/v1/runs/\(runID.pathEscaped)/steer",
                          body: try JSONEncoder().encode(["input": text]))
    }

    /// `refresh` makes the gateway re-probe provider catalogs instead of serving its disk
    /// cache (a stale cache once hid Sonnet/Haiku 5.5).
    func modelOptions(refresh: Bool = false) async throws -> ModelOptions {
        try await get("/api/model/options", query: refresh ? ["refresh": "1"] : [:])
    }

    /// `fields` is pre-encoded JSON (keeps non-Sendable dictionaries off actor hops).
    func updateSession(id: String, json: Data) async throws {
        _ = try await raw("PATCH", "/api/sessions/\(id.pathEscaped)", body: json)
    }

    func runStatus(id: String) async throws -> RunStatus {
        try await get("/v1/runs/\(id.pathEscaped)")
    }

    func stopRun(id: String) async throws {
        _ = try await raw("POST", "/v1/runs/\(id.pathEscaped)/stop", body: Data("{}".utf8))
    }

    func respondToApproval(runID: String, choice: String, requestID: String?) async throws {
        var body = ["choice": choice]
        if let requestID { body["request_id"] = requestID }
        _ = try await raw("POST", "/v1/runs/\(runID.pathEscaped)/approval",
                          body: try JSONEncoder().encode(body))
    }

    /// Streams run events. Detaching (cancel, backgrounding) does NOT stop the
    /// run; reattach with `lastSeq` to replay what was missed.
    func runEvents(runID: String, lastSeq: Int?) -> AsyncThrowingStream<RunEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try makeRequest("GET", "/v1/runs/\(runID.pathEscaped)/events")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastSeq { request.setValue(String(lastSeq), forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, response) = try await streamSession.bytes(for: request)
                    try Self.check(response, body: nil)
                    var parser = SSEParser()
                    for try await byte in bytes {
                        guard let message = parser.feed(byte: byte) else { continue }
                        guard let data = message.data.data(using: .utf8),
                              let event = try? Self.decoder.decode(RunEvent.self, from: data)
                        else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Automations (cron jobs)

    func jobs() async throws -> [CronJob] {
        let list: JobList = try await get("/api/jobs", query: ["include_disabled": "true"])
        return list.jobs
    }

    func runJob(id: String) async throws {
        _ = try await raw("POST", "/api/jobs/\(id.pathEscaped)/run", body: Data("{}".utf8))
    }

    func pauseJob(id: String) async throws {
        _ = try await raw("POST", "/api/jobs/\(id.pathEscaped)/pause", body: Data("{}".utf8))
    }

    func resumeJob(id: String) async throws {
        _ = try await raw("POST", "/api/jobs/\(id.pathEscaped)/resume", body: Data("{}".utf8))
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:],
                                   authorized: Bool = true) async throws -> T {
        let data = try await raw("GET", path, query: query, authorized: authorized)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, json: [String: String],
                                    headers: [String: String] = [:]) async throws -> T {
        let data = try await raw(method, path, body: try JSONEncoder().encode(json), headers: headers)
        return try Self.decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func raw(_ method: String, _ path: String, query: [String: String] = [:],
                     body: Data? = nil, headers: [String: String] = [:],
                     authorized: Bool = true) async throws -> Data {
        var request = try makeRequest(method, path, query: query, authorized: authorized)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return data
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String] = [:],
                             authorized: Bool = true) throws -> URLRequest {
        guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw HermesError.badURL
        }
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.percentEncodedPath = basePath + path
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw HermesError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if authorized { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw HermesError.unauthorized
        default:
            let message = body.flatMap { try? decoder.decode(APIErrorBody.self, from: $0) }?.error?.message
            throw HermesError.http(http.statusCode, message)
        }
    }
}

extension String {
    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? self
    }
}
