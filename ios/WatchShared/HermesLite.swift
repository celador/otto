import Foundation

/// The few gateway + relay calls a voice turn needs. Shared by the watch app
/// (direct, when it can reach the tailnet itself) and the iPhone's watch
/// bridge (the usual path: watch → phone → Mac).
struct HermesLite: Sendable {
    let gateway: URL
    let relay: URL
    let apiKey: String
    var timeout: TimeInterval = 30

    struct Turn: Codable, Sendable {
        var sessionID: String
        var runID: String
        var transcript: String
        /// The words were a goodbye ("stop", "bye", "that's all") in a hands-free conversation: no run started.
        var ended = false
    }

    struct RunState: Codable, Sendable {
        var status: String
        var output: String?
        var lastEvent: String?
        var isDone: Bool { ["completed", "failed", "cancelled", "interrupted"].contains(status) }
    }

    enum Failure: LocalizedError {
        case http(Int, String?)
        case nothingHeard
        var errorDescription: String? {
            switch self {
            case .http(let c, let d): d ?? "The server returned \(c)"
            case .nothingHeard: "Didn't catch that."
            }
        }
    }

    static let voiceInstructions = """
    This message is a voice transcript from a live spoken conversation on an Apple Watch (it may \
    contain mis-hearings; use the latest intent). Your reply will be read aloud on a small watch: \
    answer in one to three short conversational sentences unless asked for detail, no markdown, no \
    lists, no code, no URLs. Do the work with your tools as usual; only the final facts need to be \
    spoken. Do not claim an action succeeded before it actually did.
    """

    /// Audio (m4a) or text in → a started run on the session (creating one if needed).
    /// `context` can add notes to the run's instructions once the words are known (e.g. health data).
    /// `endsOnGoodbye`: the watch's hands-free loop; a goodbye ends the conversation instead of becoming a turn.
    func ask(audio: Data?, text: String?, sessionID: String?, instructions: String = HermesLite.voiceInstructions,
             endsOnGoodbye: Bool = false,
             context: (@Sendable (String) async -> String?)? = nil) async throws -> Turn {
        var said = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let audio, said.isEmpty { said = try await transcribe(audio) }
        guard !said.isEmpty else { throw Failure.nothingHeard }
        if endsOnGoodbye, WatchTalkLoop.isGoodbye(said) {
            return Turn(sessionID: sessionID ?? "", runID: "", transcript: said, ended: true)
        }
        let sid: String
        if let sessionID, !sessionID.isEmpty { sid = sessionID } else { sid = try await createSession(title: Self.title(for: said)) }
        var notes = instructions
        if let extra = await context?(said), !extra.isEmpty { notes += "\n\n" + extra }
        // Spoken turns (watch, Siri, TV) skip Honcho memory for that run, like the app's voice mode.
        let body: [String: Any] = ["session_id": sid, "input": said, "instructions": notes,
                                   "model_options": ["memory": false]]
        let data = try await call("POST", gateway, "/v1/runs", json: body,
                                  headers: ["Idempotency-Key": UUID().uuidString])
        let runID = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["run_id"] as? String ?? ""
        return Turn(sessionID: sid, runID: runID, transcript: said)
    }

    /// A run with photos (Responses-style `input_image` data URLs, like the app's own composer).
    func startRun(sessionID: String, text: String, jpegs: [Data]) async throws -> String {
        var parts: [[String: Any]] = []
        if !text.isEmpty { parts.append(["type": "input_text", "text": text]) }
        for j in jpegs { parts.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + j.base64EncodedString()]) }
        let body: [String: Any] = ["session_id": sessionID, "input": [["role": "user", "content": parts]]]
        let data = try await call("POST", gateway, "/v1/runs", json: body, headers: ["Idempotency-Key": UUID().uuidString])
        let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["run_id"] as? String ?? ""
        guard !id.isEmpty else { throw Failure.http(500, "The server didn't start the chat.") }
        return id
    }

    func status(runID: String) async throws -> RunState {
        let data = try await call("GET", gateway, "/v1/runs/\(runID)")
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return RunState(status: obj["status"] as? String ?? "running",
                        output: obj["output"] as? String,
                        lastEvent: obj["last_event"] as? String)
    }

    /// Hermes's configured voice (mp3/aac bytes) for a short text; `voice`/`speed` override it.
    func speak(_ text: String, voice: String? = nil, speed: Double = 1.0) async throws -> Data {
        try await call("POST", relay, "/hermes/speak", json: VoiceChoice.speakBody(text, voice: voice, speed: speed))
    }

    /// Edge's voices + the Hermes profile's own voice (relay `GET /hermes/voices`).
    func voices() async throws -> VoicesResponse {
        try VoiceChoice.decodeVoices(try await call("GET", relay, "/hermes/voices"))
    }

    func stop(runID: String) async {
        _ = try? await call("POST", gateway, "/v1/runs/\(runID)/stop", json: [:])
    }

    func transcribe(_ audio: Data) async throws -> String {
        let data = try await call("POST", relay, "/hermes/transcribe",
                                  json: ["audio": audio.base64EncodedString(), "mime_type": "audio/mp4"])
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (obj["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func createSession(title: String) async throws -> String {
        do {
            return try await newSession(title)
        } catch Failure.http(_, let d?) where d.localizedCaseInsensitiveContains("title") {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            return try await newSession("\(title) · \(f.string(from: Date()))")
        }
    }

    private func newSession(_ title: String) async throws -> String {
        let data = try await call("POST", gateway, "/api/sessions", json: ["title": title])
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (obj["session"] as? [String: Any])?["id"] as? String ?? ""
    }

    struct ChatRow: Codable, Sendable, Identifiable, Hashable {
        var id: String
        var title: String
        var lastActive: Double?
        var source: String?
    }

    struct Exchange: Codable, Sendable {
        var asked: String?
        var answer: String?
        var title: String?
    }

    /// Your most recent chats from every device (the same list the iPhone shows).
    func recentChats(limit: Int = 12) async throws -> [ChatRow] {
        let data = try await call("GET", gateway, "/api/sessions", query: ["limit": String(limit)])
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let rows = (obj["data"] as? [[String: Any]]) ?? (obj["sessions"] as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let id = r["id"] as? String, (r["archived"] as? Bool) != true, (r["hidden"] as? Bool) != true,
                  (r["is_internal_child"] as? Bool) != true else { return nil }
            let title = (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (r["preview"] as? String).map { String($0.prefix(40)) } ?? "Chat"
            return ChatRow(id: id, title: title, lastActive: Self.number(r["last_active"]) ?? Self.number(r["started_at"]),
                           source: r["source"] as? String)
        }
    }

    /// The last thing you asked and the last answer in a chat (tool chatter skipped).
    func lastExchange(sessionID: String) async throws -> Exchange {
        let data = try await call("GET", gateway, "/api/sessions/\(sessionID)/messages",
                                  query: ["limit": "60", "order": "latest"])   // the newest 60, oldest first
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let msgs = (obj["data"] as? [[String: Any]]) ?? (obj["messages"] as? [[String: Any]]) ?? []
        var answer: String?, asked: String?
        for m in msgs.reversed() {
            let role = m["role"] as? String, text = Self.text(m["content"])
            if answer == nil, role == "assistant", let text, !text.isEmpty, text != "[SILENT]" { answer = text; continue }
            if answer != nil, role == "user", let text, !text.isEmpty { asked = text; break }
        }
        return Exchange(asked: asked, answer: answer, title: nil)
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// Message content is a string, or a list of parts ({type: text, text: …}).
    private static func text(_ v: Any?) -> String? {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = v as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func title(for said: String, prefix: String = "⌚︎ ") -> String {
        let words = said.split(separator: " ").prefix(8).joined(separator: " ")
        return prefix + String(words.prefix(48))
    }

    private func call(_ method: String, _ base: URL, _ path: String, json: [String: Any]? = nil,
                      query: [String: String] = [:], headers: [String: String] = [:]) async throws -> Data {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (obj?["detail"] as? String) ?? ((obj?["error"] as? [String: Any])?["message"] as? String)
            throw Failure.http(http.statusCode, detail)
        }
        return data
    }
}

/// Watch ↔ phone message keys (WatchConnectivity).
enum WatchWire {
    static let op = "op"
    static let ask = "ask"          // audio: Data? text: String? session: String? loop: Bool → session, run, transcript, ended?
    static let status = "status"    // run: String
    static let stop = "stop"        // run: String
    static let speak = "speak"      // text: String → audio: Data
    static let limits = "limits"    // → limits: Data (LimitsSnapshot JSON)
    static let chats = "chats"      // → chats: Data ([HermesLite.ChatRow] JSON)
    static let chat = "chat"        // session: String → exchange: Data (HermesLite.Exchange JSON)
    static let jobs = "jobs"        // → jobs: Data ([JobLite] JSON)
    static let runJob = "runJob"    // job: Data (JobLite JSON) → ok: true
    // transferCurrentComplicationUserInfo / transferUserInfo phone → watch: "status": Data (LiveStatus JSON), "limits": Data
    // applicationContext pushed phone → watch so the watch can also go direct.
    static let gatewayURL = "gateway"

    /// The answer to an `ask`, for the watch.
    static func reply(_ turn: HermesLite.Turn) -> [String: Any] {
        var out: [String: Any] = ["session": turn.sessionID, "run": turn.runID, "transcript": turn.transcript]
        if turn.ended { out["ended"] = true }
        return out
    }
    static let relayURL = "relay"
    static let apiKey = "key"
}
