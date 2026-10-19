import Foundation

/// The phone's copy of Weft's change log: every repo's records keyed by seq, the
/// per-repo high-water mark used to resume (spec §9.4: reconnect with `after=` the highest
/// seq processed, de-duplicate by seq), and the derived views the feed needs
/// (combined order, filters, negotiation threads, candidates, paused agents).
///
/// A plain value type so resume/de-dup logic is unit-testable without sockets.
struct WeftLog: Sendable, Equatable {
    /// Offline cache size per repo.
    static let perRepoLimit = 500

    private(set) var byRepo: [String: [Int: WeftEvent]] = [:]
    /// Highest seq processed per repo. Never decreases (trimming old rows keeps it).
    private(set) var highWater: [String: Int] = [:]
    /// Combined change log, newest first: ordered by (ts, repo, seq) like `/v1/feed`.
    private(set) var combined: [WeftEvent] = []
    /// Lookups the feed rows need in O(1) instead of scanning `combined` per row (that was O(n²) per render).
    private(set) var taskTitles: [String: String] = [:]
    private(set) var agents: [String] = []
    private(set) var tasks: [String] = []
    /// Newest record time per repo (seconds since 2001), for "active in the last 7 days" and
    /// sorting repos by last activity.
    private(set) var lastActivity: [String: Double] = [:]

    init(events: [WeftEvent] = []) {
        _ = ingest(events)
    }

    /// Adds records, ignoring ones already held (same repo + seq). A richer copy (detail
    /// view with `diff`) replaces a list-view copy. Returns only records that were new.
    @discardableResult
    mutating func ingest(_ events: [WeftEvent]) -> [WeftEvent] {
        guard !events.isEmpty else { return [] }
        var added: [WeftEvent] = []
        var touched = Set<String>()
        for e in events {
            var repo = byRepo[e.repo, default: [:]]
            if let old = repo[e.seq] {
                if old.diff == nil, e.diff != nil { repo[e.seq] = e; byRepo[e.repo] = repo; touched.insert(e.repo) }
                continue
            }
            repo[e.seq] = e
            byRepo[e.repo] = repo
            highWater[e.repo] = max(highWater[e.repo] ?? 0, e.seq)
            added.append(e)
            touched.insert(e.repo)
        }
        guard !touched.isEmpty else { return [] }
        var dropped: Set<WeftEventID> = []
        for r in touched { dropped.formUnion(trim(r)) }
        // A few live records into a big log: binary-insert (and drop trimmed rows) instead of
        // re-sorting everything.
        if added.count == events.count, added.count <= 8, combined.count > 64 {
            if !dropped.isEmpty { combined.removeAll { dropped.contains($0.id) } }
            for e in added where !dropped.contains(e.id) { combined.insert(e, at: Self.insertionIndex(of: e, in: combined)) }
            noteLookups(added)
        } else {
            rebuild()
        }
        return added
    }

    /// First index whose element sorts after `e` (newest first).
    static func insertionIndex(of e: WeftEvent, in list: [WeftEvent]) -> Int {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if newestFirst(list[mid], e) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    enum CatchUp: Equatable { case tail, after(Int) }

    /// How to catch a repo up on foreground: page `after=` the high-water mark, or, for a repo
    /// never seen (or so far behind that the 500-row cache would drop most of it), take the
    /// newest page (`tail=1`) and let scroll-back (`before=`) reach older history.
    static func catchUpPlan(highWater: Int, head: Int) -> CatchUp {
        if highWater == 0 || head - highWater > perRepoLimit { return .tail }
        return .after(highWater)
    }

    /// Where to resume a repo's stream / paging (`after=`).
    func resumePoint(_ repo: String) -> Int { highWater[repo] ?? 0 }

    /// Oldest seq held for a repo (for `before=` scroll-back).
    func oldestSeq(_ repo: String) -> Int? { byRepo[repo]?.keys.min() }

    func event(_ id: WeftEventID) -> WeftEvent? { byRepo[id.repo]?[id.seq] }

    func events(repo: String) -> [WeftEvent] {
        (byRepo[repo] ?? [:]).values.sorted { $0.seq < $1.seq }
    }

    var repos: [String] { byRepo.keys.sorted() }

    /// Restores the high-water mark of a repo from a cache written earlier.
    mutating func noteHighWater(_ repo: String, _ seq: Int) {
        highWater[repo] = max(highWater[repo] ?? 0, seq)
    }

    /// Drops a repo's rows (before re-reading its newest page after a long absence, so the
    /// held window stays contiguous and `before=` scroll-back can fill everything below it).
    mutating func reset(repo: String) {
        byRepo[repo] = nil
        highWater[repo] = nil
        rebuild()
    }

    /// Drops the oldest rows past the cache limit; returns their ids.
    @discardableResult
    private mutating func trim(_ repo: String) -> Set<WeftEventID> {
        guard var rows = byRepo[repo], rows.count > Self.perRepoLimit else { return [] }
        var out: Set<WeftEventID> = []
        for seq in rows.keys.sorted().prefix(rows.count - Self.perRepoLimit) {
            rows[seq] = nil
            out.insert(WeftEventID(repo: repo, seq: seq))
        }
        byRepo[repo] = rows
        return out
    }

    private mutating func rebuild() {
        combined = byRepo.values.flatMap(\.values).sorted(by: Self.newestFirst)
        taskTitles = [:]; agents = []; tasks = []; lastActivity = [:]
        noteLookups(combined)
    }

    private mutating func noteLookups(_ events: [WeftEvent]) {
        var a = Set(agents), t = Set(tasks)
        let before = (a.count, t.count)
        for e in events {
            if e.epoch > lastActivity[e.repo] ?? -.infinity { lastActivity[e.repo] = e.epoch }
            if let agent = e.agent { a.insert(agent) }
            if let task = e.task {
                t.insert(task)
                if let title = e.taskTitle, taskTitles[task] == nil { taskTitles[task] = title }
            }
        }
        if a.count != before.0 { agents = a.sorted() }
        if t.count != before.1 { tasks = t.sorted() }
    }

    /// Plain number comparisons only: `epoch` is parsed once at decode.
    static func newestFirst(_ a: WeftEvent, _ b: WeftEvent) -> Bool {
        if a.epoch != b.epoch { return a.epoch > b.epoch }
        if a.repo != b.repo { return a.repo > b.repo }
        return a.seq > b.seq
    }

    // MARK: Derived views

    func filtered(_ f: WeftFilter) -> [WeftEvent] {
        f.isEmpty && f.showSessionEvents ? combined : combined.filter(f.matches)
    }

    /// Repos that have records, most recently active first.
    var reposByActivity: [String] {
        lastActivity.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Repos with a record in the last `days` days, most recent first.
    func activeRepos(days: Double = 7, now: Date = Date()) -> [String] {
        let since = now.timeIntervalSinceReferenceDate - days * 86_400
        return reposByActivity.filter { (lastActivity[$0] ?? 0) >= since }
    }

    func taskTitle(_ task: String) -> String? { taskTitles[task] }

    /// The negotiation an event belongs to: the root `negotiate.propose` and every
    /// counter/accept/reject whose `reply_to` chain reaches it, oldest first.
    func thread(for e: WeftEvent) -> [WeftEvent] {
        guard e.group == .negotiate else { return [] }
        let rows = byRepo[e.repo] ?? [:]
        var root = e
        var guardCount = 0
        while let parent = root.replyTo, let p = rows[parent], guardCount < 100 { root = p; guardCount += 1 }
        var members: Set<Int> = [root.seq]
        var out = [root]
        for r in rows.values.sorted(by: { $0.seq < $1.seq }) where r.seq > root.seq && r.group == .negotiate {
            if let to = r.replyTo, members.contains(to) { members.insert(r.seq); out.append(r) }
        }
        return out
    }

    /// Competing changes for one task (design §3: a task has N candidates).
    func candidates(task: String, repo: String) -> [WeftCandidate] {
        let rows = events(repo: repo)
        var byChange: [String: WeftCandidate] = [:]
        for r in rows where r.task == task {
            guard let change = r.change else { continue }
            var c = byChange[change] ?? WeftCandidate(change: change, agent: r.agent ?? r.actor.id, harness: r.harness, latest: r.id)
            if r.actor.type == "agent" { c.latest = r.id; if c.harness == nil { c.harness = r.harness } }
            if r.kind == "land" { c.landedSeq = r.seq }
            if let ev = r.evidence { c.evidence = ev }
            byChange[change] = c
        }
        // Approvals and reverts point at the change / land without always naming the task.
        for r in rows {
            if r.kind == "control", r.payload?["action"]?.string == "approve",
               let ch = r.payload?["target"]?["change"]?.string, byChange[ch] != nil { byChange[ch]?.approved = true }
            if r.kind == "revert", let target = r.payload?["reverts_seq"]?.int {
                for (k, c) in byChange where c.landedSeq == target { byChange[k]?.reverted = true }
            }
        }
        return byChange.values.sorted { $0.change < $1.change }
    }

    /// Whether a human paused this agent (last `control` pause/resume wins).
    func isPaused(agent: String, repo: String) -> Bool {
        for r in events(repo: repo).reversed() where r.kind == "control" {
            guard r.payload?["target"]?["agent"]?.string == agent else { continue }
            switch r.payload?["action"]?.string {
            case "pause": return true
            case "resume": return false
            default: continue
            }
        }
        return false
    }

    /// The revert that undid a landing, if any.
    func revert(of land: WeftEvent) -> WeftEvent? {
        events(repo: land.repo).first { $0.kind == "revert" && $0.payload?["reverts_seq"]?.int == land.seq }
    }
}

struct WeftCandidate: Hashable, Sendable, Identifiable {
    var change: String
    var agent: String
    var harness: String?
    var latest: WeftEventID
    var landedSeq: Int?
    var approved = false
    var reverted = false
    var evidence: WeftEvidence?
    var id: String { change }
}

/// Feed filters (spec §9.3: kind/agent/task server-side; "only conflicts" client-side).
///
/// By default the feed hides session bookkeeping (join/leave, claim/release, heartbeats): with
/// every Hermes profile streaming into Weft it buried the edits. "Show session events" brings it
/// back; picking one of those kinds explicitly also shows it. Bookkeeping that carries a
/// diagnostic or was blocked is never hidden.
struct WeftFilter: Codable, Equatable, Sendable {
    var repos: Set<String> = []
    var tasks: Set<String> = []
    var agents: Set<String> = []
    var kinds: Set<WeftKindGroup> = []
    var onlyConflicts = false
    var showSessionEvents = false

    init(repos: Set<String> = [], tasks: Set<String> = [], agents: Set<String> = [], kinds: Set<WeftKindGroup> = [],
         onlyConflicts: Bool = false, showSessionEvents: Bool = false) {
        self.repos = repos; self.tasks = tasks; self.agents = agents; self.kinds = kinds
        self.onlyConflicts = onlyConflicts; self.showSessionEvents = showSessionEvents
    }

    /// Filters saved by older builds have no `showSessionEvents`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repos = try c.decodeIfPresent(Set<String>.self, forKey: .repos) ?? []
        tasks = try c.decodeIfPresent(Set<String>.self, forKey: .tasks) ?? []
        agents = try c.decodeIfPresent(Set<String>.self, forKey: .agents) ?? []
        kinds = (try? c.decodeIfPresent(Set<WeftKindGroup>.self, forKey: .kinds)) ?? []
        onlyConflicts = try c.decodeIfPresent(Bool.self, forKey: .onlyConflicts) ?? false
        showSessionEvents = try c.decodeIfPresent(Bool.self, forKey: .showSessionEvents) ?? false
    }

    /// The default view: no chips, session bookkeeping hidden.
    var isEmpty: Bool { repos.isEmpty && tasks.isEmpty && agents.isEmpty && kinds.isEmpty && !onlyConflicts && !showSessionEvents }
    var count: Int { repos.count + tasks.count + agents.count + kinds.count + (onlyConflicts ? 1 : 0) + (showSessionEvents ? 1 : 0) }

    func matches(_ e: WeftEvent) -> Bool {
        if !showSessionEvents, e.isSessionBookkeeping, !kinds.contains(e.group) { return false }
        if !repos.isEmpty, !repos.contains(e.repo) { return false }
        if !tasks.isEmpty, !tasks.contains(e.task ?? "") { return false }
        if !agents.isEmpty, !agents.contains(e.agent ?? e.actor.id) { return false }
        if !kinds.isEmpty, !kinds.contains(e.group) { return false }
        if onlyConflicts, !e.isConflict { return false }
        return true
    }
}
