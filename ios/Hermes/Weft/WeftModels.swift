import Foundation

// Wire types for the Weft Coordination Protocol (WCP v0.1), observer + human roles
// (spec §9, ~/github/weft/docs/protocol/wcp-v0.md). Receivers must ignore unknown
// fields and show unknown kinds generically, so every optional field decodes leniently.
// Explicit CodingKeys (no convertFromSnakeCase): `payload` is free-form JSON and its keys
// (`reply_to`, `reverts_seq`) must stay as sent.

// MARK: - Free-form JSON (event payloads)

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

// MARK: - Records

struct WeftActor: Codable, Hashable, Sendable {
    var type: String          // agent | human | system
    var id: String
    var harness: String?
}

struct WeftWrite: Codable, Hashable, Sendable {
    var key: String
    var kind: String          // signature | body | new | deleted
}

struct WeftPosition: Codable, Hashable, Sendable { var line: Int; var character: Int }
struct WeftRange: Codable, Hashable, Sendable { var start: WeftPosition; var end: WeftPosition }

struct WeftDiagnostic: Codable, Hashable, Sendable {
    var severity: String      // info | warning | error
    var code: String
    var file: String?
    var range: WeftRange?
    var symbol: String
    var message: String
    var causedBySeq: Int
    var causedByAgent: String
    var causedByTask: String?
    var suggestion: String?

    enum CodingKeys: String, CodingKey {
        case severity, code, file, range, symbol, message, suggestion
        case causedBySeq = "caused_by_seq", causedByAgent = "caused_by_agent", causedByTask = "caused_by_task"
    }
}

struct WeftToolRef: Codable, Hashable, Sendable {
    var name: String
    var callId: String?
    var harnessEvent: String?
    enum CodingKeys: String, CodingKey { case name, callId = "call_id", harnessEvent = "harness_event" }
}

struct WeftTranscriptRef: Codable, Hashable, Sendable {
    var uri: String
    var offset: Int?
}

/// Evidence for a candidate (design §3). Not part of WCP v0.1: the gateway attaches it as
/// the vendor extension `x_evidence` on records of that change (see docs/weft.md).
struct WeftEvidence: Codable, Hashable, Sendable {
    struct Tests: Codable, Hashable, Sendable { var passed: Int?; var failed: Int?; var total: Int? }
    struct Review: Codable, Hashable, Sendable { var verdict: String?; var summary: String? }
    var previewURL: String?
    var tests: Tests?
    var screenshots: [String]?
    var review: Review?
    var costUSD: Double?
    enum CodingKeys: String, CodingKey {
        case tests, screenshots, review
        case previewURL = "preview_url", costUSD = "cost_usd"
    }

    init(previewURL: String? = nil, tests: Tests? = nil, screenshots: [String]? = nil, review: Review? = nil, costUSD: Double? = nil) {
        self.previewURL = previewURL; self.tests = tests; self.screenshots = screenshots; self.review = review; self.costUSD = costUSD
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL).map(Self.fixLegacyURL)
        tests = try c.decodeIfPresent(Tests.self, forKey: .tests)
        screenshots = try c.decodeIfPresent([String].self, forKey: .screenshots)?.map(Self.fixLegacyURL)
        review = try c.decodeIfPresent(Review.self, forKey: .review)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
    }

    /// Records written before weft-previews moved to its elier.ai custom domain carry the
    /// account's `*.workers.dev` origin. That host is disabled and its subdomain must never be
    /// shown, and the log is append-only, so map it here. The capability signatures cover
    /// repo+sha / object key, not the host, so the rewritten URL stays valid. The subdomain is
    /// matched generically, never spelled out.
    static func fixLegacyURL(_ s: String) -> String {
        guard s.contains(".workers.dev/"),
              let re = try? NSRegularExpression(pattern: #"^https://weft-previews(-preview)?\.[a-z0-9-]+\.workers\.dev/"#)
        else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "https://weft-previews$1.elier.ai/")
    }
}

/// `EventRecord` (spec §4.2). List views omit `diff` and set `has_diff`.
struct WeftEvent: Codable, Hashable, Sendable, Identifiable {
    var seq: Int
    var repo: String
    var status: String
    var kind: String
    var ts: String
    var actor: WeftActor
    var agent: String?
    var task: String?
    var change: String?
    var session: String?
    var baseSeq: Int?
    var mode: String?
    var files: [String]
    var reads: [String]
    var writes: [WeftWrite]
    var diff: String?
    var intent: String?
    var summary: String
    var diagnostics: [WeftDiagnostic]
    var payload: JSONValue?
    var tool: WeftToolRef?
    var transcript: WeftTranscriptRef?
    var hasDiff: Bool?
    // Vendor extensions (spec §10: `x_` prefix).
    var taskTitle: String?
    var evidence: WeftEvidence?
    /// `ts` parsed once at decode (seconds since 2001, like `timeIntervalSinceReferenceDate`). Sorting and "2m ago" read this instead of
    /// re-parsing the string: ISO8601DateFormatter on every sort comparison froze the feed.
    var epoch: Double = 0

    enum CodingKeys: String, CodingKey {
        case seq, repo, status, kind, ts, actor, agent, task, change, session, mode, files, reads, writes
        case diff, intent, summary, diagnostics, payload, tool, transcript
        case baseSeq = "base_seq", hasDiff = "has_diff", taskTitle = "x_task_title", evidence = "x_evidence"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        repo = try c.decode(String.self, forKey: .repo)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "accepted"
        kind = try c.decode(String.self, forKey: .kind)
        ts = try c.decode(String.self, forKey: .ts)
        epoch = WeftTime.epoch(ts) ?? 0
        actor = try c.decode(WeftActor.self, forKey: .actor)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        change = try c.decodeIfPresent(String.self, forKey: .change)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        baseSeq = try c.decodeIfPresent(Int.self, forKey: .baseSeq)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        reads = try c.decodeIfPresent([String].self, forKey: .reads) ?? []
        writes = try c.decodeIfPresent([WeftWrite].self, forKey: .writes) ?? []
        diff = try c.decodeIfPresent(String.self, forKey: .diff)
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? kind
        diagnostics = (try? c.decodeIfPresent([WeftDiagnostic].self, forKey: .diagnostics)) ?? []
        payload = try c.decodeIfPresent(JSONValue.self, forKey: .payload)
        tool = try? c.decodeIfPresent(WeftToolRef.self, forKey: .tool)
        transcript = try? c.decodeIfPresent(WeftTranscriptRef.self, forKey: .transcript)
        hasDiff = try c.decodeIfPresent(Bool.self, forKey: .hasDiff)
        taskTitle = try? c.decodeIfPresent(String.self, forKey: .taskTitle)
        evidence = try? c.decodeIfPresent(WeftEvidence.self, forKey: .evidence)
        // The deployed weft-gateway (B2) keeps an agent's `payload` verbatim but drops unknown
        // top-level fields, so producers can also carry the extensions inside `payload`.
        if taskTitle == nil || evidence == nil, let p = try? c.nestedContainer(keyedBy: VendorKeys.self, forKey: .payload) {
            if taskTitle == nil { taskTitle = try? p.decodeIfPresent(String.self, forKey: .taskTitle) }
            if evidence == nil { evidence = try? p.decodeIfPresent(WeftEvidence.self, forKey: .evidence) }
        }
    }

    private enum VendorKeys: String, CodingKey { case taskTitle = "x_task_title", evidence = "x_evidence" }

    var id: WeftEventID { WeftEventID(repo: repo, seq: seq) }
    var date: Date { epoch != 0 ? Date(timeIntervalSinceReferenceDate: epoch) : .distantPast }
    var isRejected: Bool { status == "rejected" }
    /// "Only conflicts": rejected submissions plus anything carrying a squiggle (spec §9.3).
    var isConflict: Bool { isRejected || !diagnostics.isEmpty }
    var group: WeftKindGroup { WeftKindGroup(kind: kind) }
    /// Session bookkeeping (join/leave, claim/release, heartbeats) rather than work. Hidden from
    /// the feed by default unless it carries a squiggle or was blocked.
    var isSessionBookkeeping: Bool {
        guard diagnostics.isEmpty, !isRejected else { return false }
        if group == .presence || group == .claim { return true }
        return kind == "heartbeat" || kind == "ping" || kind.hasPrefix("session.")
    }
    /// Whose change this is: the agent for agent work and for system records about an agent's
    /// change (land, revert); otherwise the actor (a human, or a system workflow).
    var who: String {
        switch actor.type {
        case "agent": agent ?? actor.id
        case "system": agent ?? actor.id
        default: actor.id
        }
    }
    var harness: String? { actor.harness }
    var mayHaveDiff: Bool { diff != nil || hasDiff == true }
    var replyTo: Int? { payload?["reply_to"]?.int }
    var symbols: [String] {
        var out: [String] = []
        for k in writes.map(\.key) + reads where !out.contains(k) { out.append(k) }
        return out
    }
}

struct WeftEventID: Hashable, Codable, Sendable, CustomStringConvertible, Identifiable {
    var id: String { description }
    var repo: String
    var seq: Int
    var description: String { "\(repo)#\(seq)" }
}

// MARK: - Pages and frames (spec §9)

struct WeftRepo: Codable, Hashable, Sendable, Identifiable {
    var repo: String
    var headSeq: Int
    var activeAgents: Int?
    var activeChanges: Int?
    var openConflicts: Int?
    var lastEventAt: String?
    var id: String { repo }
    enum CodingKeys: String, CodingKey {
        case repo
        case headSeq = "head_seq", activeAgents = "active_agents", activeChanges = "active_changes"
        case openConflicts = "open_conflicts", lastEventAt = "last_event_at"
    }
}

struct WeftRepoList: Codable, Sendable { var repos: [WeftRepo] }

struct WeftEventPage: Codable, Sendable {
    var repo: String
    var events: [WeftEvent]
    var headSeq: Int
    var nextAfter: Int
    var hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case repo, events
        case headSeq = "head_seq", nextAfter = "next_after", hasMore = "has_more"
    }
}

struct WeftFeedPage: Codable, Sendable {
    var events: [WeftEvent]
    var cursor: String
    var hasMore: Bool
    enum CodingKeys: String, CodingKey { case events, cursor, hasMore = "has_more" }
}

enum WeftStreamFrame: Sendable, Equatable {
    case event(WeftEvent)
    case replayDone(headSeq: Int)
    case ping(headSeq: Int)
    case other(String)

    static func decode(_ data: Data) throws -> WeftStreamFrame {
        struct Head: Decodable { var type: String; var event: WeftEvent?; var head_seq: Int? }
        let h = try JSONDecoder().decode(Head.self, from: data)
        switch h.type {
        case "event": if let e = h.event { return .event(e) }
        case "replay.done": return .replayDone(headSeq: h.head_seq ?? 0)
        case "ping": return .ping(headSeq: h.head_seq ?? 0)
        default: break
        }
        return .other(h.type)
    }
}

struct WeftActionResult: Codable, Sendable {
    var seq: Int
    var record: WeftEvent
}

struct WeftErrorBody: Codable, Sendable {
    struct Inner: Codable, Sendable { var code: String; var message: String; var retryable: Bool? }
    var error: Inner
}

/// Human actions (spec §9.6). Encodes to the exact `HumanAction` wire shape.
enum WeftAction: Sendable, Equatable {
    case approve(change: String, task: String?, note: String?)
    case undo(seq: Int, reason: String)
    case pause(agent: String, reason: String?)
    case resume(agent: String)
    case message(agent: String, text: String, intent: String)

    var json: [String: Any] {
        var j: [String: Any] = ["type": "action"]
        switch self {
        case .approve(let change, let task, let note):
            j["action"] = "approve"; j["change"] = change
            if let task { j["task"] = task }
            if let note, !note.isEmpty { j["note"] = note }
        case .undo(let seq, let reason):
            j["action"] = "undo"; j["seq"] = seq; j["reason"] = reason
        case .pause(let agent, let reason):
            j["action"] = "pause"; j["agent"] = agent
            if let reason, !reason.isEmpty { j["reason"] = reason }
        case .resume(let agent):
            j["action"] = "resume"; j["agent"] = agent
        case .message(let agent, let text, let intent):
            j["action"] = "message"; j["to"] = ["agent": agent]; j["text"] = text; j["intent"] = intent
        }
        return j
    }
}

// MARK: - Presentation helpers

/// The feed's kind badges. Unknown kinds fall into `.other` and show their raw name.
enum WeftKindGroup: String, CaseIterable, Hashable, Sendable, Codable {
    case intent, edit, checkpoint, claim, negotiate, message, control, land, revert, presence, other

    init(kind: String) {
        switch kind {
        case "intent": self = .intent
        case "edit": self = .edit
        case "checkpoint": self = .checkpoint
        case "claim", "release": self = .claim
        case "message": self = .message
        case "control": self = .control
        case "land": self = .land
        case "revert": self = .revert
        case "join", "leave": self = .presence
        default: self = kind.hasPrefix("negotiate.") ? .negotiate : .other
        }
    }

    var label: String {
        switch self {
        case .presence: "join/leave"
        case .control: "human"
        default: rawValue
        }
    }

    /// Kinds offered in the filter sheet, in the order a reader thinks about them.
    static let filterable: [WeftKindGroup] = [.intent, .edit, .checkpoint, .negotiate, .land, .revert, .claim, .message, .control, .presence]
}

enum WeftTime {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    nonisolated private static let lock = NSLock()

    nonisolated static func parse(_ s: String) -> Date? {
        epoch(s).map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    /// Seconds since 2001 (reference date) for an RFC 3339 timestamp. Hand-rolled fast path for the shapes Weft
    /// emits (`2026-10-04T03:54:21.005Z`, `…+00:00`): no ICU, no lock, safe off the main thread.
    /// Anything unusual falls back to ISO8601DateFormatter.
    nonisolated static func epoch(_ s: String) -> Double? {
        if let fast = fastEpoch(s) { return fast }
        lock.lock(); defer { lock.unlock() }
        return (fractional.date(from: s) ?? plain.date(from: s))?.timeIntervalSinceReferenceDate
    }

    nonisolated static func fastEpoch(_ s: String) -> Double? {
        let b = Array(s.utf8)
        guard b.count >= 20, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116 || b[10] == 32,
              b[13] == 58, b[16] == 58 else { return nil }
        func num(_ i: Int, _ n: Int) -> Int? {
            var v = 0
            for k in i..<(i + n) { let d = Int(b[k]) - 48; guard d >= 0, d <= 9 else { return nil }; v = v * 10 + d }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
              let sec = num(17, 2), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        var i = 19
        var fracDigits = 0, fracValue = 0
        if i < b.count, b[i] == 46 {   // .fraction (formatter precision: milliseconds)
            i += 1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                if fracDigits < 3 { fracValue = fracValue * 10 + Int(b[i] - 48); fracDigits += 1 }
                i += 1
            }
            while fracDigits < 3 { fracValue *= 10; fracDigits += 1 }
        }
        guard i < b.count else { return nil }
        var offset = 0
        if b[i] == 90 || b[i] == 122 {   // Z
            guard i == b.count - 1 else { return nil }
        } else if b[i] == 43 || b[i] == 45, b.count == i + 6, b[i + 3] == 58, let oh = num(i + 1, 2), let om = num(i + 4, 2) {
            offset = (oh * 3600 + om * 60) * (b[i] == 43 ? 1 : -1)
        } else { return nil }
        // Days from civil (Howard Hinnant), proleptic Gregorian.
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        // Same arithmetic as ICU (milliseconds since 1970 → reference date) so Dates compare equal.
        let ms = (days * 86400 + h * 3600 + mi * 60 + sec - offset) * 1000 + fracValue
        return Double(ms) / 1000.0 - 978_307_200
    }
}

enum WeftSymbol {
    /// `src/auth/session.ts#SessionStore.get` → `SessionStore.get`.
    nonisolated static func name(_ key: String) -> String {
        guard let i = key.firstIndex(of: "#") else { return key }
        return String(key[key.index(after: i)...])
    }
    /// `src/auth/session.ts#refreshToken` → `src/auth/session.ts`.
    nonisolated static func file(_ key: String) -> String {
        guard let i = key.firstIndex(of: "#") else { return "" }
        return String(key[..<i])
    }
    /// `README.md#*`: the whole-file key the analyzer uses for files it doesn't parse
    /// (md, json, swift, py…). Never show the "*"; show the file.
    nonisolated static func isWholeFile(_ key: String) -> Bool { name(key) == "*" }
    /// `docs/try-it.md`, `try-it.md` → `try-it.md`.
    nonisolated static func baseName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
    /// What a reader sees for a key: the symbol, or the file's name for a whole-file key.
    nonisolated static func display(_ key: String) -> String {
        isWholeFile(key) ? baseName(file(key)) : name(key)
    }
}
