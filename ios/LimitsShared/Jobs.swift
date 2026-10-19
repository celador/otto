import Foundation

/// A scheduled job (Hermes cron), trimmed to what widgets and the watch show.
struct JobLite: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String?
    let profile: String?
    let state: String?
    let scheduleDisplay: String?
    let nextRunAt: String?
    let lastRunAt: String?
    let lastStatus: String?
    let lastError: String?
    let deliver: String?
    let enabled: Bool?
    var noAgent: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, profile, state, enabled, deliver
        case noAgent = "no_agent"
        case scheduleDisplay = "schedule_display", nextRunAt = "next_run_at", lastRunAt = "last_run_at"
        case lastStatus = "last_status", lastError = "last_error"
    }

    var title: String { (name?.isEmpty == false ? name! : id) }
    var isPaused: Bool { state == "paused" || enabled == false }
    var nextRun: Date? { nextRunAt.flatMap(Self.date) }
    var lastRun: Date? { lastRunAt.flatMap(Self.date) }
    var lastFailed: Bool { lastStatus == "error" || lastStatus == "failed" }

    /// Where the output goes, in words ("Telegram", "everywhere", "saved only").
    var deliveryLabel: String {
        switch deliver ?? "" {
        case "", "origin": "where it was set up"
        case "local": "saved only"
        case "all": "everywhere"
        case let d where d.hasPrefix("bot-chat:"): "a bot chat"
        case let d: d.split(separator: ":").first.map { $0.capitalized } ?? d
        }
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Python isoformat with microseconds and an offset: trim to milliseconds.
        if let r = s.range(of: #"\.\d{6}"#, options: .regularExpression) {
            var t = s; t.replaceSubrange(r, with: String(s[r].prefix(4)))
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: t)
        }
        return nil
    }
}

private struct JobsEnvelope: Decodable { let jobs: [JobLite] }

/// The relay's automations routes (same allowlist the app's Automations screen uses).
enum JobsAPI {
    static func list(relay: URL, apiKey: String, timeout: TimeInterval = 30) async throws -> [JobLite] {
        let data = try await call("GET", relay, "hermes/automations", query: ["profile": "all"], apiKey: apiKey, timeout: timeout)
        return try JSONDecoder().decode(JobsEnvelope.self, from: data).jobs
    }

    static func run(_ job: JobLite, relay: URL, apiKey: String, timeout: TimeInterval = 30) async throws {
        var q: [String: String] = [:]
        if let p = job.profile, !p.isEmpty { q["profile"] = p }
        _ = try await call("POST", relay, "hermes/automations/\(job.id)/run", query: q, apiKey: apiKey,
                           timeout: timeout, body: Data("{}".utf8))
    }

    /// Jobs worth showing first: agent jobs (briefings, check-ins) by next run, then script-only
    /// watchdogs, paused ones last.
    static func ordered(_ jobs: [JobLite]) -> [JobLite] {
        jobs.sorted { a, b in
            if a.isPaused != b.isPaused { return !a.isPaused }
            if (a.noAgent ?? false) != (b.noAgent ?? false) { return !(a.noAgent ?? false) }
            return (a.nextRun ?? .distantFuture) < (b.nextRun ?? .distantFuture)
        }
    }

    private static func call(_ method: String, _ base: URL, _ path: String, query: [String: String], apiKey: String,
                             timeout: TimeInterval, body: Data? = nil) async throws -> Data {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// "Run now" tapped somewhere (widget, watch): remembered so every surface shows "Running…" until
/// the job's last run moves past the moment it was started.
struct JobKick: Codable, Sendable {
    let jobID: String
    let at: Date
    let previousLastRun: String?

    func finished(in job: JobLite) -> Bool { job.lastRunAt != nil && job.lastRunAt != previousLastRun }
}

extension SharedVault {
    static func saveJobs(_ jobs: [JobLite]) { writeData("jobs", try? JSONEncoder().encode(jobs)) }
    static func jobs() -> [JobLite] { readData("jobs").flatMap { try? JSONDecoder().decode([JobLite].self, from: $0) } ?? [] }

    static func saveKicks(_ k: [JobKick]) { writeData("jobKicks", try? JSONEncoder().encode(k)) }
    /// Kicks younger than 30 minutes (older ones are assumed done or lost).
    static func kicks() -> [JobKick] {
        (readData("jobKicks").flatMap { try? JSONDecoder().decode([JobKick].self, from: $0) } ?? [])
            .filter { Date().timeIntervalSince($0.at) < 1800 }
    }
    static func addKick(_ job: JobLite) {
        saveKicks(kicks().filter { $0.jobID != job.id } + [JobKick(jobID: job.id, at: Date(), previousLastRun: job.lastRunAt)])
    }

    /// The gateway address (for widgets showing the latest reply). Same key as the relay.
    static func saveGateway(_ url: URL?) { writeData("gateway", url.flatMap { $0.absoluteString.data(using: .utf8) }) }
    static func gateway() -> URL? { readData("gateway").flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)) }
}
