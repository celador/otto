import Foundation

// MARK: - What a running card is doing (relay GET /hermes/kanban-live, relay/card_live.py)
//
// "I find myself constantly wondering what's that task doing, what's taking so long." Every kanban
// worker run is a Hermes session; the relay links the card's current run to it and reads the newest
// tool calls into a plain-language "Now" step, a short trail of milestones and the time of the last
// real activity. The app turns that into the Now line, the stall signal and the watch view.

struct CardLiveResponse: Decodable, Sendable {
    let board: String?
    let now: Double?
    let cards: [String: CardLive]

    /// Card ids are dictionary keys: decode without the shared snake_case conversion (it would turn
    /// "t_2ede9e2d" into "t2ede9e2d"), with explicit keys instead.
    static func decode(_ data: Data) throws -> CardLiveResponse {
        try JSONDecoder().decode(CardLiveResponse.self, from: data)
    }
}

struct CardLive: Decodable, Hashable, Sendable {
    struct Step: Decodable, Hashable, Sendable {
        let phrase: String
        let tool: String?
        let summary: String?
        /// "apple" / "network" / "wait": expected waiting. "long": builds and tests (quiet for minutes).
        let wait: String?
        let running: Bool
        /// Start of the run of same-kind calls this step belongs to (what "· 4m" counts from).
        let since: Double?
        let startedAt: Double?

        enum CodingKeys: String, CodingKey {
            case phrase, tool, summary, wait, running, since
            case startedAt = "started_at"
        }
    }

    struct TrailStep: Decodable, Hashable, Sendable {
        let phrase: String
        /// done / running / failed
        let state: String
        let at: Double?
    }

    struct Said: Decodable, Hashable, Sendable {
        let text: String
        let at: Double?
    }

    var runId: Int? = nil
    var runStartedAt: Double? = nil
    var heartbeatAt: Double? = nil
    /// nil = unknown (no pid recorded).
    var workerAlive: Bool? = nil
    var sessionId: String? = nil
    var now: Step? = nil
    var trail: [TrailStep] = []
    var said: Said? = nil
    /// Newest tool call, result or text in the worker's transcript (a heartbeat doesn't count).
    var lastActivityAt: Double? = nil

    enum CodingKeys: String, CodingKey {
        case now, trail, said
        case runId = "run_id", runStartedAt = "run_started_at", heartbeatAt = "heartbeat_at"
        case workerAlive = "worker_alive", sessionId = "session_id", lastActivityAt = "last_activity_at"
    }

    init(runId: Int? = nil, runStartedAt: Double? = nil, heartbeatAt: Double? = nil, workerAlive: Bool? = nil,
         sessionId: String? = nil, now: Step? = nil, trail: [TrailStep] = [], said: Said? = nil,
         lastActivityAt: Double? = nil) {
        self.runId = runId; self.runStartedAt = runStartedAt; self.heartbeatAt = heartbeatAt
        self.workerAlive = workerAlive; self.sessionId = sessionId; self.now = now; self.trail = trail
        self.said = said; self.lastActivityAt = lastActivityAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try? c.decodeIfPresent(Int.self, forKey: .runId)
        runStartedAt = try? c.decodeIfPresent(Double.self, forKey: .runStartedAt)
        heartbeatAt = try? c.decodeIfPresent(Double.self, forKey: .heartbeatAt)
        workerAlive = try? c.decodeIfPresent(Bool.self, forKey: .workerAlive)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        now = try? c.decodeIfPresent(Step.self, forKey: .now)
        trail = (try? c.decodeIfPresent([TrailStep].self, forKey: .trail)) ?? []
        said = try? c.decodeIfPresent(Said.self, forKey: .said)
        lastActivityAt = try? c.decodeIfPresent(Double.self, forKey: .lastActivityAt)
    }
}

// MARK: - The Now line

struct CardNow: Equatable {
    let phrase: String
    let since: Date

    /// When the last call finished this long ago with nothing new, the agent is thinking, not "Running tests".
    static let thinkingAfter: TimeInterval = 45

    static func of(_ live: CardLive?, now: Date) -> CardNow? {
        guard let live else { return nil }
        guard let step = live.now else {
            // Linked but nothing called yet: the worker is reading the card.
            guard live.sessionId != nil, let start = live.runStartedAt else { return nil }
            return CardNow(phrase: "Starting", since: Date(timeIntervalSince1970: start))
        }
        let since = Date(timeIntervalSince1970: step.since ?? step.startedAt ?? live.runStartedAt ?? now.timeIntervalSince1970)
        if !step.running, let last = live.lastActivityAt, now.timeIntervalSince1970 - last > thinkingAfter {
            return CardNow(phrase: "Thinking", since: Date(timeIntervalSince1970: last))
        }
        return CardNow(phrase: step.phrase, since: since)
    }

    func label(now: Date) -> String { phrase + " · " + CardTime.elapsed(now.timeIntervalSince(since)) }
}

// MARK: - Slow / stuck signals (quiet: at most one small badge)

enum CardSignal: Equatable {
    case none
    /// Expected waiting (Apple processing, the network, a sleep loop) that has gone on a while: grey.
    case waiting(String)
    /// No new tool call, output or text for a while: amber.
    case quiet(minutes: Int)
    /// The worker process is gone but the card still says running: red.
    case stopped

    /// No activity for longer than this is worth an amber badge…
    static let quietAfter: TimeInterval = 5 * 60
    /// …except during a build/test/install, which can run this long without writing anything.
    static let longStepQuietAfter: TimeInterval = 20 * 60

    static func of(_ live: CardLive?, now: Date) -> CardSignal {
        guard let live else { return .none }
        if live.workerAlive == false { return .stopped }
        guard let last = live.lastActivityAt ?? live.runStartedAt else { return .none }
        let idle = now.timeIntervalSince1970 - last
        let step = live.now
        if let step, step.running, let wait = step.wait, ["apple", "network", "wait"].contains(wait) {
            return idle > quietAfter ? .waiting(waitLabel(wait)) : .none
        }
        let limit = (step?.running == true && step?.wait == "long") ? longStepQuietAfter : quietAfter
        return idle > limit ? .quiet(minutes: Int(idle / 60)) : .none
    }

    static func waitLabel(_ kind: String) -> String {
        switch kind {
        case "apple": "Waiting on Apple"
        case "network": "Waiting on network"
        default: "Waiting"
        }
    }

    var label: String? {
        switch self {
        case .none: nil
        case .waiting(let s): s
        case .quiet(let m): "No activity for \(m)m"
        case .stopped: "Worker stopped"
        }
    }
}

// MARK: - Step trail ("Merging ✓ · Running tests ✓ · Building the Mac app …")

enum CardTrail {
    static func mark(_ state: String) -> String {
        switch state {
        case "done": "✓"
        case "failed": "✗"
        default: "…"
        }
    }

    static func text(_ trail: [CardLive.TrailStep]) -> String? {
        guard !trail.isEmpty else { return nil }
        return trail.map { "\($0.phrase) \(mark($0.state))" }.joined(separator: " · ")
    }
}

// MARK: - Watching a card's worker session

struct WatchTarget: Hashable, Identifiable, Sendable {
    let taskID: String
    let title: String
    let board: String
    let sessionID: String
    var id: String { taskID + "/" + sessionID }
}

/// Live state for running cards, shared by the board, the dashboard and the watch view.
@MainActor
@Observable
final class CardLiveStore {
    static let shared = CardLiveStore()
    private(set) var cards: [String: CardLive] = [:]
    private(set) var loadedAt: [String: Date] = [:]
    /// The relay predates /hermes/kanban-live: stop asking until the app restarts.
    private(set) var unsupported = false
    private var inFlight: Set<String> = []

    func live(_ taskID: String) -> CardLive? { cards[taskID] }

    /// The watch target for a running card, when its worker session is known.
    func watchTarget(_ task: KanbanTask, board: String) -> WatchTarget? {
        guard task.status == "running", let sid = cards[task.id]?.sessionId else { return nil }
        return WatchTarget(taskID: task.id, title: task.title, board: board, sessionID: sid)
    }

    /// Refresh one board's running cards. Cheap when nothing runs (no request).
    func load(board: String, running: [String], companion: CompanionClient?) async {
        guard let companion, !unsupported, !inFlight.contains(board) else { return }
        if running.isEmpty {
            for (id, b) in boardOf where b == board { cards[id] = nil; boardOf[id] = nil }
            return
        }
        inFlight.insert(board)
        defer { inFlight.remove(board) }
        do {
            let data = try await companion.rawRequest("GET", "/hermes/kanban-live", query: ["board": board])
            apply(try CardLiveResponse.decode(data), board: board)
        } catch HermesError.http(404, let detail) where detail == nil || detail == "not found" {
            unsupported = true
        } catch {
            // Keep the last answer; the next board poll tries again.
        }
    }

    private var boardOf: [String: String] = [:]

    func apply(_ response: CardLiveResponse, board: String) {
        for (id, b) in boardOf where b == board && response.cards[id] == nil { cards[id] = nil; boardOf[id] = nil }
        for (id, card) in response.cards where cards[id] != card {
            cards[id] = card
            boardOf[id] = board
        }
        loadedAt[board] = .now
    }
}

extension Notification.Name {
    /// Mac: open a running card's worker session in the chat pane (object: WatchTarget).
    static let watchCard = Notification.Name("otto.watchCard")
}

/// Screenshot runs launch Otto Dev behind John's windows, where scenePhase reads `.background` and the
/// board panel stops polling. `-hermes.forceActive YES` (DEBUG only) keeps it polling.
enum DebugFlags {
    static var forceActive: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "hermes.forceActive")
        #else
        false
        #endif
    }
}
