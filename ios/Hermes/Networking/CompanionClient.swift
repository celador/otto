import Foundation

/// Profiles, skills, memory, status and usage, via the companion routes on the
/// relay (`relay/companion.py`, same host/port/key as the board).
final class CompanionClient: Sendable {
    let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 45
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    func profiles() async throws -> ProfilesResponse { try await get("/hermes/profiles") }

    /// Writes model.default/provider into that agent's config.yaml (takes effect on its next run).
    func setProfileModel(_ profile: String, choice: ModelChoice) async throws {
        _ = try await raw("PUT", "/hermes/profiles/\(profile.pathEscaped)/model",
                          body: try JSONEncoder().encode(["provider": choice.provider, "model": choice.model]))
    }

    func skills(profile: String) async throws -> [HermesSkill] {
        let r: SkillsResponse = try await get("/hermes/skills", query: ["profile": profile])
        return r.skills
    }

    func skillContent(_ name: String, profile: String) async throws -> String {
        let r: SkillContent = try await get("/hermes/skills/content", query: ["name": name, "profile": profile])
        return r.content
    }

    func setSkill(_ name: String, enabled: Bool, profile: String) async throws {
        _ = try await raw("PUT", "/hermes/skills/toggle", query: ["profile": profile],
                          body: try JSONSerialization.data(withJSONObject: ["name": name, "enabled": enabled]))
    }

    func memory(profile: String) async throws -> MemoryState { try await get("/hermes/memory", query: ["profile": profile]) }

    /// op: add (content) · replace (oldText → content) · remove (oldText).
    func editMemory(op: String, target: MemoryTarget, content: String? = nil, oldText: String? = nil,
                    profile: String) async throws -> MemoryState {
        var json: [String: Any] = ["op": op, "target": target.rawValue]
        if let content { json["content"] = content }
        if let oldText { json["old_text"] = oldText }
        let data = try await raw("POST", "/hermes/memory", query: ["profile": profile],
                                 body: try JSONSerialization.data(withJSONObject: json))
        return try HermesClient.decoder.decode(MemoryState.self, from: data)
    }

    func status() async throws -> HermesStatus { try await get("/hermes/status") }

    /// Weft gateway URL + token from the Hermes host (WeftAutoConfig.swift). `renew` asks the host to
    /// replace a token the gateway no longer accepts.
    func weftConfig(renew: Bool = false) async throws -> WeftAutoConfig {
        try await get("/hermes/weft/config", query: renew ? ["renew": "1"] : [:])
    }

    func usage(days: Int, profile: String? = nil) async throws -> UsageResponse {
        var q = ["days": String(days)]
        if let profile { q["profile"] = profile }
        return try await get("/hermes/usage", query: q)
    }

    /// Codex / Claude / … subscription limits, read by CodexBar on the Mac.
    func limits(refresh: Bool = false) async throws -> LimitsSnapshot {
        try await LimitsAPI.fetch(relay: baseURL, apiKey: apiKey, refresh: refresh)
    }

    /// The desktop app's provider catalog (dashboard `model/options?explicit_only=true`).
    func modelOptions(refresh: Bool = false) async throws -> ModelOptions {
        try await get("/hermes/model-options", query: refresh ? ["refresh": "1"] : [:])
    }

    /// The desktop app's Edit Models shortlist, favorites and custom models (read from its storage on the Mac).
    /// Archived chats (the gateway's own list leaves them out; the relay reads the dashboard's).
    func archivedSessions(limit: Int = 100, offset: Int = 0) async throws -> SessionList {
        try await get("/hermes/sessions/archived", query: ["limit": "\(limit)", "offset": "\(offset)"])
    }

    func modelVisibility(refresh: Bool = false) async throws -> DesktopModelVisibility {
        try await get("/hermes/model-visibility", query: refresh ? ["refresh": "1"] : [:])
    }

    // MARK: Voice

    /// Hermes's configured voice (tts.provider on the Mac), as audio bytes. `voice` (an Edge
    /// ShortName) and `speed` override it; nil/1.0 keep the profile's own.
    func speak(_ text: String, profile: String, voice: String? = nil, speed: Double = 1.0) async throws -> Data {
        try await raw("POST", "/hermes/speak", query: ["profile": profile],
                      body: try JSONSerialization.data(withJSONObject: VoiceChoice.speakBody(text, voice: voice, speed: speed)))
    }

    /// Edge's voices + the profile's own voice. `CompanionError.relayOutdated` on a relay without the route.
    func voices(profile: String = "default") async throws -> VoicesResponse {
        try VoiceChoice.decodeVoices(try await raw("GET", "/hermes/voices", query: ["profile": profile]))
    }

    /// The same voice streamed as MP3 chunks while it's generated (`/hermes/speak/stream`), so playback
    /// can start before the sentence is fully synthesized. Throws `CompanionError.relayOutdated` on an
    /// old relay (404) and `HermesError.http(409, …)` when the Mac's voice isn't Edge.
    func speakStream(_ text: String, profile: String, voice: String? = nil,
                     speed: Double = 1.0) -> AsyncThrowingStream<Data, Error> {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.percentEncodedPath = "/hermes/speak/stream"
        comps?.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let url = comps?.url,
              let body = try? JSONSerialization.data(withJSONObject: VoiceChoice.speakBody(text, voice: voice, speed: speed)) else {
            return AsyncThrowingStream { $0.finish(throwing: HermesError.badURL) }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = self.session
        return AsyncThrowingStream { continuation in
            let delegate = StreamingDataDelegate(continuation)
            let task = session.dataTask(with: request)
            task.delegate = delegate
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    // MARK: Automations

    func automations() async throws -> [CronJob] {
        let r: CompanionJobs = try await get("/hermes/automations", query: ["profile": "all"])
        return r.jobs
    }

    func runs(job: CronJob, limit: Int = 20) async throws -> [JobRun] {
        let r: JobRuns = try await get("/hermes/automations/\(job.id.pathEscaped)/runs",
                                       query: q(job.profile, ["limit": String(limit)]))
        return r.runs
    }

    func runOutput(job: CronJob, run: JobRun) async throws -> RunOutput {
        try await get("/hermes/automations/\(job.id.pathEscaped)/output", query: q(job.profile, ["run": run.id]))
    }

    /// action: run · pause · resume
    func act(_ action: String, job: CronJob) async throws {
        _ = try await raw("POST", "/hermes/automations/\(job.id.pathEscaped)/\(action)", query: q(job.profile), body: Data("{}".utf8))
    }

    @discardableResult
    func updateJob(_ job: CronJob, fields: [String: String]) async throws -> CronJob {
        let data = try await raw("PATCH", "/hermes/automations/\(job.id.pathEscaped)", query: q(job.profile),
                                 body: try JSONEncoder().encode(fields))
        return try HermesClient.decoder.decode(CronJob.self, from: data)
    }

    func deleteJob(_ job: CronJob) async throws {
        _ = try await raw("DELETE", "/hermes/automations/\(job.id.pathEscaped)", query: q(job.profile))
    }

    func deliveryTargets(profile: String) async throws -> [DeliveryTarget] {
        let r: DeliveryTargets = try await get("/hermes/automations/targets", query: ["profile": profile])
        return r.targets
    }

    func blueprints(profile: String) async throws -> [Blueprint] {
        let r: Blueprints = try await get("/hermes/automations/blueprints", query: ["profile": profile])
        return r.blueprints
    }

    @discardableResult
    func createFromBlueprint(_ key: String, values: [String: String], profile: String) async throws -> CronJob {
        let data = try await raw("POST", "/hermes/automations/blueprints", query: ["profile": profile],
                                 body: try JSONSerialization.data(withJSONObject: ["blueprint": key, "values": values]))
        return try HermesClient.decoder.decode(CronJob.self, from: data)
    }

    // MARK: Messaging access

    func pairing(profile: String) async throws -> PairingState {
        try await get("/hermes/pairing", query: ["profile": profile])
    }

    func approve(_ p: PairingState.Pending, profile: String) async throws {
        _ = try await raw("POST", "/hermes/pairing/approve", query: ["profile": profile],
                          body: try JSONEncoder().encode(["platform": p.platform, "request_id": p.requestId]))
    }

    func revoke(_ a: PairingState.Approved, profile: String) async throws {
        _ = try await raw("POST", "/hermes/pairing/revoke", query: ["profile": profile],
                          body: try JSONEncoder().encode(["platform": a.platform, "user_id": a.userId]))
    }

    private func q(_ profile: String?, _ extra: [String: String] = [:]) -> [String: String] {
        var out = extra
        if let profile, !profile.isEmpty { out["profile"] = profile }
        return out
    }

    // MARK: Slash commands

    func slashCommands(refresh: Bool = false) async throws -> [SlashCommand] {
        let c: SlashCatalog = try await get("/hermes/commands", query: refresh ? ["refresh": "1"] : [:])
        return c.commands
    }

    /// Runs on the Mac; compress/btw can take a couple of minutes.
    func slash(sessionID: String?, command: String) async throws -> SlashReply {
        let body = try JSONSerialization.data(withJSONObject: ["session_id": sessionID ?? "", "command": command])
        let data = try await raw("POST", "/hermes/slash", body: body, timeout: 200)
        return try HermesClient.decoder.decode(SlashReply.self, from: data)
    }

    func uploadVoiceDiag(_ text: String, device: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "device": device])
        _ = try await raw("POST", "/hermes/voice-diag", body: body)
    }

    // MARK: Plumbing

    /// For extensions in other files (e.g. artifacts).
    func rawRequest(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        try await raw(method, path, query: query, body: body)
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await raw("GET", path, query: query)
        return try HermesClient.decoder.decode(T.self, from: data)
    }

    private func raw(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                     timeout: TimeInterval? = nil) async throws -> Data {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw HermesError.badURL }
        comps.percentEncodedPath = path
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw HermesError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw HermesError.unauthorized }
            if http.statusCode == 404, path.hasPrefix("/hermes/") { throw CompanionError.relayOutdated }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw HermesError.http(http.statusCode, detail)
        }
        return data
    }
}

/// Hands a streaming response's body to an AsyncThrowingStream as it arrives.
private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var failed = false
    private var errorBody = Data()
    private var status = 0

    init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        failed = !(200..<300).contains(status)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if failed { errorBody.append(data) } else { continuation.yield(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation.finish(throwing: error); return }
        guard failed else { continuation.finish(); return }
        switch status {
        case 401, 403: continuation.finish(throwing: HermesError.unauthorized)
        case 404: continuation.finish(throwing: CompanionError.relayOutdated)
        default:
            let detail = (try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any])?["detail"] as? String
            continuation.finish(throwing: HermesError.http(status, detail))
        }
    }
}

enum CompanionError: LocalizedError {
    case relayOutdated
    var errorDescription: String? {
        "The relay on your Mac needs restarting to show this. Restart it, then pull to refresh."
    }
}
