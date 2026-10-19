import Foundation
import Observation
import SwiftUI

/// Keeps the phone's copy of Weft's change log current.
///
/// Same discipline as `ChatModel`: the log lives on the gateway, the phone holds a window of it.
/// One poll of the combined feed (`GET /v1/feed?after=<cursor>`, spec §9.5) every few seconds
/// while the Changes screen is on screen and the app is in the foreground, instead of one
/// WebSocket per repo: with every Hermes profile streaming into Weft there are ~100 repos, and
/// URLSession's per-host connection cap left most sockets connecting forever. The cursor is the
/// gateway's opaque per-repo high-water vector; it is saved with the log, so the feed opens
/// instantly, reads offline and resumes exactly where it stopped (records de-duplicate by seq).
@MainActor
@Observable
final class WeftStore {
    static let shared = WeftStore()

    private(set) var config: WeftConfig?
    private(set) var log = WeftLog()
    /// Records that arrived since the screen opened; rows highlight briefly.
    private(set) var fresh: Set<WeftEventID> = []
    private(set) var isLoading = false
    private(set) var loadingOlder = false
    private(set) var reachedStart: Set<String> = []
    /// When the last feed poll succeeded. The header is "Live" while this is recent.
    private(set) var lastPollOK: Date?
    private(set) var isPolling = false
    var errorMessage: String?

    private var client: WeftClient?
    private var cursor: String?
    private var active = false
    private var pollLoop: Task<Void, Never>?
    private var inFlight: Task<Int, Never>?
    private var saveTask: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var idlePolls = 0

    /// Reading + decoding the saved log (hundreds of records with payloads) happens off the main
    /// thread; `start()` waits for it so the resume cursor is right.
    private var cacheLoad: Task<Void, Never>?

    init(config: WeftConfig? = nil, useCache: Bool = true) {
        let cfg = config ?? Self.launchConfig() ?? WeftKeychain.load()
        apply(cfg)
        if useCache, cfg != nil {
            cacheLoad = Task { [weak self] in
                let (log, cursor) = await Task.detached(priority: .userInitiated) { () -> (WeftLog, String?) in
                    let repos = WeftCache.loadRepos()
                    var events: [WeftEvent] = []
                    var marks: [(String, Int)] = []
                    for repo in repos.map(\.repo) {
                        let cached = WeftCache.load(repo: repo)
                        events += cached.events
                        marks.append((repo, cached.highWater))
                    }
                    var log = WeftLog(events: events)   // one sort for everything
                    for (r, hw) in marks { log.noteHighWater(r, hw) }
                    // A cursor without the records it points past would skip them: start over.
                    return (log, log.combined.isEmpty ? nil : WeftCache.loadCursor())
                }.value
                guard let self else { return }
                // Anything that arrived while the cache was loading wins.
                guard self.log.combined.isEmpty, self.cursor == nil else { return }
                self.log = log
                self.cursor = cursor
            }
        }
    }

    var isConfigured: Bool { config != nil }

    // MARK: Auto-config (WeftAutoConfig.swift)

    /// How the last ask to the Hermes host went.
    private(set) var autoStatus: WeftAutoStatus = .idle
    /// Repos the gateway lists for this token (`/v1/repos`); nil until loaded.
    private(set) var knownRepos: Set<String>?
    /// Set by AppModel whenever it has a relay client; the strip retries through it.
    var autoSource: (@MainActor () -> CompanionClient?)?
    private var autoCheckedAt: Date?
    private var autoTask: Task<Void, Never>?

    /// Ask the Hermes host for the Weft gateway + token and save it (unless a manual config is set).
    /// Cheap to call often: once it succeeded it doesn't ask again this launch unless `renew`.
    func autoConfigure(renew: Bool = false) async {
        if config?.source == .manual { return }
        if let autoTask { return await autoTask.value }
        if !renew, config != nil, case .ok = autoStatus { return }
        if !renew, let at = autoCheckedAt, Date().timeIntervalSince(at) < 20 { return }
        guard let client = autoSource?() else {
            if config == nil { autoStatus = .failed(.notConnected) }
            return
        }
        let task = Task { @MainActor in
            autoStatus = .fetching
            autoCheckedAt = Date()
            do {
                let offered = try await client.weftConfig(renew: renew)
                if let next = WeftAutoConfig.resolve(current: config, offered: offered) {
                    try? WeftKeychain.save(next)
                    let changed = next.baseURL != config?.baseURL || next.token != config?.token
                    if changed && config != nil { resetLocal() }
                    let wasActive = active
                    detach()
                    apply(next)
                    knownRepos = nil
                    if wasActive || holders > 0 { start() }
                    NSLog("WEFT auto-config: %@ token from the Hermes host", offered.scope)
                }
                autoStatus = .ok(scope: offered.scope)
                await refreshKnownRepos()
            } catch {
                let failure = WeftAutoFailure.from(error)
                autoStatus = .failed(failure)
                NSLog("WEFT auto-config failed: %@", failure.message)
            }
        }
        autoTask = task
        await task.value
        autoTask = nil
    }

    /// Repos visible to the token, so the strip can say "Weft isn't tracking X yet".
    private var reposCheckedAt: Date?
    func refreshKnownRepos(force: Bool = false) async {
        guard let client else { return }
        if !force, let at = reposCheckedAt, Date().timeIntervalSince(at) < 60 { return }
        reposCheckedAt = Date()
        if let repos = try? await client.repos() { knownRepos = Set(repos.map(\.repo)) }
    }

    /// Settings → "Use automatic connection": drop the typed-in config and ask the host again.
    func useAutomatic() async {
        detach()
        WeftKeychain.clear()
        resetLocal()
        apply(nil)
        autoStatus = .idle
        autoCheckedAt = nil
        await autoConfigure()
        if holders > 0 { start() }
    }

    /// Green "Live": the last poll succeeded within ~15 s.
    func isLive(now: Date = Date()) -> Bool {
        guard let lastPollOK else { return false }
        return now.timeIntervalSince(lastPollOK) < WeftPollPolicy.liveWindow
    }

    /// Repos with records in the last 7 days, most recently active first (the header counts these,
    /// not every repo the gateway knows).
    func activeRepos(now: Date = Date()) -> [String] { log.activeRepos(days: 7, now: now) }

    /// Repos that have records, most recently active first (filters, scroll-back).
    var repoNames: [String] { log.reposByActivity }

    private func apply(_ cfg: WeftConfig?) {
        config = cfg
        client = cfg.map(WeftClient.init(config:))
    }

    #if DEBUG
    private static func launchConfig() -> WeftConfig? {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: "weft.url"), let url = WeftClient.normalizedURL(raw) else { return nil }
        return WeftConfig(baseURL: url, token: d.string(forKey: "weft.token") ?? "")
    }
    #else
    private static func launchConfig() -> WeftConfig? { nil }
    #endif

    // MARK: Settings

    /// Checks the address + token against `/v1/repos`, then saves them to the Keychain.
    func connect(url raw: String, token: String) async throws {
        guard let url = WeftClient.normalizedURL(raw) else { throw WeftError.badURL }
        let cfg = WeftConfig(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let repos = try await WeftClient(config: cfg).repos()
        try WeftKeychain.save(cfg)
        if cfg.baseURL != config?.baseURL || cfg.token != config?.token { resetLocal() }
        detach()
        apply(cfg)
        knownRepos = Set(repos.map(\.repo))
        start()
    }

    func disconnect() {
        detach()
        WeftKeychain.clear()
        resetLocal()
        apply(nil)
    }

    private func resetLocal() {
        WeftCache.clear()
        seededRepos = []
        log = WeftLog()
        cursor = nil
        reachedStart = []
        lastPollOK = nil
    }

    // MARK: Lifecycle

    /// Feed on screen / app in the foreground: poll the combined feed until `detach()`.
    func start() {
        guard client != nil, !active else { return }
        active = true
        generation += 1
        let gen = generation
        idlePolls = 0
        pollLoop = Task { [weak self] in
            await self?.cacheLoad?.value
            while let self, self.active, gen == self.generation, !Task.isCancelled {
                let added = await self.poll()
                guard self.active, gen == self.generation else { return }
                self.idlePolls = added > 0 ? 0 : self.idlePolls + 1
                let wait = WeftPollPolicy.interval(idlePolls: self.idlePolls, failures: self.failures)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Feed off screen / app in the background: stop polling. The saved cursor resumes it.
    func detach() {
        active = false
        generation += 1
        pollLoop?.cancel(); pollLoop = nil
    }

    func resume() {
        detach()
        start()
    }

    /// Several Weft views can be on screen at once (Changes, the dashboard's Weft strip): each
    /// holds the poll while visible; it stops when the last one goes away.
    private var holders = 0
    func hold() {
        holders += 1
        start()
    }
    func unhold() {
        holders = max(0, holders - 1)
        if holders == 0 { detach() }
    }

    /// Pull-to-refresh: one poll now (joins a poll already in flight), then keep polling.
    func reload() async {
        await cacheLoad?.value
        idlePolls = 0
        _ = await poll()
        if !active { start() }
    }

    /// One round trip (plus follow-up pages while the gateway has more). Returns how many new
    /// records arrived. Concurrent callers share the request so the cursor never goes backwards.
    @discardableResult
    func poll() async -> Int {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.fetchFeed() }
        inFlight = task
        let n = await task.value
        inFlight = nil
        return n
    }

    private func fetchFeed() async -> Int {
        guard let client else { return 0 }
        isPolling = true
        defer { isPolling = false }
        let firstLoad = log.combined.isEmpty
        if firstLoad { isLoading = true }
        defer { if firstLoad { isLoading = false } }
        do {
            var added: [WeftEvent] = []
            if cursor == nil {
                // First open (or after a reset): the newest records across every repo, with a
                // cursor at every repo's head. Older history comes from scroll-back.
                let page = try await client.feed(after: nil, tail: true, limit: WeftPollPolicy.tailLimit)
                added = ingest(page)
            } else {
                var pages = 0
                while true {
                    let page = try await client.feed(after: cursor, limit: WeftPollPolicy.pageLimit)
                    added += ingest(page)
                    pages += 1
                    if !page.hasMore { break }
                    if pages >= WeftPollPolicy.maxCatchUpPages {
                        // Gone for ages: crawling thousands of records would leave a gap the
                        // per-repo scroll-back can't see. Restart from the newest records instead.
                        NSLog("WEFT feed: far behind after %d pages, restarting from the tail", pages)
                        log = WeftLog()
                        reachedStart = []
                        let tail = try await client.feed(after: nil, tail: true, limit: WeftPollPolicy.tailLimit)
                        added = ingest(tail)
                        break
                    }
                }
            }
            lastPollOK = Date()
            failures = 0
            errorMessage = nil
            if !firstLoad { markFresh(added) }
            if !added.isEmpty { scheduleSave() } else { saveCursorSoon() }
            return added.count
        } catch is CancellationError {
            return 0
        } catch let e as URLError where e.code == .cancelled {
            return 0
        } catch {
            failures += 1
            errorMessage = Self.describe(error)
            if case WeftError.unauthorized = error {
                detach()   // revoked token: stop until reconnected
                // A token the host handed out: ask it for a fresh one.
                if config?.isAuto == true { Task { await self.autoConfigure(renew: true) } }
            }
            NSLog("WEFT feed poll failed (%d): %@", failures, String(describing: error))
            return 0
        }
    }

    private func ingest(_ page: WeftFeedPage) -> [WeftEvent] {
        cursor = page.cursor
        guard !page.events.isEmpty else { return [] }
        let animate = !log.combined.isEmpty && page.events.count <= 8
        let added = animate ? withAnimation(.snappy(duration: 0.35)) { log.ingest(page.events) } : log.ingest(page.events)
        return added
    }

    private func markFresh(_ added: [WeftEvent]) {
        guard !added.isEmpty else { return }
        let ids = added.map(\.id)
        fresh.formUnion(ids)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.6)) { self?.fresh.subtract(ids) }
        }
    }

    // MARK: Reading

    /// Full record (diff, payload) for the detail screen; also fetches records the cache dropped.
    @discardableResult
    func loadDetail(_ id: WeftEventID) async -> WeftEvent? {
        // List views carry everything but `diff` (spec §9.3).
        if let e = log.event(id), e.diff != nil || e.hasDiff != true { return e }
        guard let client else { return log.event(id) }
        do {
            let full = try await client.event(repo: id.repo, seq: id.seq)
            log.ingest([full])
            return log.event(id) ?? full
        } catch {
            if log.event(id) == nil { errorMessage = Self.describe(error) }
            return log.event(id)
        }
    }

    /// +/- line counts per edit row (the strip). List records carry no diff, so a row asks once
    /// when it first shows; only the counts are kept, not the diff, so the saved log stays small.
    private(set) var lineStats: [WeftEventID: WeftLineStats] = [:]
    private var statsInFlight: Set<WeftEventID> = []
    private var statsFailed: Set<WeftEventID> = []

    func loadLineStats(_ id: WeftEventID) async {
        guard lineStats[id] == nil, !statsInFlight.contains(id), !statsFailed.contains(id) else { return }
        let held = log.event(id)
        if let s = WeftLineStats.from(payload: held?.payload) ?? held?.diff.map(WeftLineStats.from(diff:)) {
            lineStats[id] = s
            return
        }
        guard held?.hasDiff != false, let client else { return }
        statsInFlight.insert(id)
        defer { statsInFlight.remove(id) }
        do {
            let full = try await client.event(repo: id.repo, seq: id.seq)
            if lineStats.count > 2000 { lineStats.removeAll(keepingCapacity: true) }
            lineStats[id] = full.diff.map(WeftLineStats.from(diff:)) ?? WeftLineStats(added: 0, removed: 0)
        } catch {
            statsFailed.insert(id)   // don't hammer the gateway; the detail screen still loads it
        }
    }

    /// The dashboard's Weft strip follows one repo: the combined feed's tail can be all other repos
    /// (a busy one fills the newest 300), so fetch this repo's newest records once if none are held.
    private var seededRepos: Set<String> = []
    func ensureRepo(_ repo: String) async {
        await cacheLoad?.value
        guard let client, !seededRepos.contains(repo) else { return }
        seededRepos.insert(repo)
        guard log.events(repo: repo).count < 20 else { return }
        do {
            let page = try await client.events(repo: repo, tail: true, limit: 200)
            if !log.ingest(page.events).isEmpty { scheduleSave() }
        } catch {
            seededRepos.remove(repo)   // try again next time the strip appears
            NSLog("WEFT strip: %@ tail failed: %@", repo, String(describing: error))
        }
    }

    /// Scroll-back past the held window (`before=`), per repo.
    func loadOlder(repos only: Set<String>) async {
        guard let client, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        for repo in repoNames where (only.isEmpty || only.contains(repo)) && !reachedStart.contains(repo) {
            guard let oldest = log.oldestSeq(repo), oldest > 1 else { reachedStart.insert(repo); continue }
            if let page = try? await client.events(repo: repo, before: oldest, limit: 100) {
                if page.events.isEmpty { reachedStart.insert(repo) }
                log.ingest(page.events)
            }
        }
    }

    // MARK: Human actions (spec §9.6)

    @discardableResult
    func perform(_ action: WeftAction, repo: String) async throws -> WeftEvent {
        guard let client else { throw WeftError.badURL }
        let result = try await client.act(repo: repo, action)
        let added = withAnimation(.snappy) { log.ingest([result.record]) }
        markFresh(added)
        scheduleSave()
        return result.record
    }

    // MARK: Cache

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = log
        let cursor = cursor
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            for repo in snapshot.repos {
                WeftCache.save(repo: repo, events: snapshot.events(repo: repo), highWater: snapshot.resumePoint(repo))
            }
            WeftCache.saveRepos(snapshot.repos.map { WeftRepo(repo: $0, headSeq: snapshot.resumePoint($0)) })
            WeftCache.saveCursor(cursor)
        }
    }

    /// Empty polls only move the cursor (new repos join it); save that cheaply, at most every 30 s.
    private var cursorSavedAt = Date.distantPast
    private func saveCursorSoon() {
        guard Date().timeIntervalSince(cursorSavedAt) > 30 else { return }
        cursorSavedAt = Date()
        let cursor = cursor
        Task.detached(priority: .utility) { WeftCache.saveCursor(cursor) }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? WeftError { return e.localizedDescription }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Offline. Showing the last saved changes."
            case .cannotFindHost, .cannotConnectToHost, .timedOut: return "Can't reach Weft. Showing the last saved changes."
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// How often to poll the combined feed. Pure, so tests can pin it.
enum WeftPollPolicy {
    /// The header shows "Live" while the last successful poll is younger than this.
    nonisolated static let liveWindow: TimeInterval = 15
    nonisolated static let tailLimit = 300
    nonisolated static let pageLimit = 500
    nonisolated static let maxCatchUpPages = 6

    /// 4 s while things are happening, easing to 10 s after a quiet minute (still inside the 15 s
    /// live window with a ~3 s round trip); failures back off 2, 4, 8… up to 30 s.
    nonisolated static func interval(idlePolls: Int, failures: Int) -> Double {
        if failures > 0 { return Double(min(30, 1 << min(failures, 5))) }
        switch idlePolls {
        case ..<15: return 4
        case ..<45: return 7
        default: return 10
        }
    }
}

/// Last 500 records per repo in Caches, so the feed opens instantly and reads offline.
enum WeftCache {
    struct Snapshot: Codable { var highWater: Int; var events: [WeftEvent] }

    private static var dir: URL {
        let base = AppDirs.caches
        let d = base.appendingPathComponent("hermes/weft", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(_ repo: String) -> URL {
        dir.appendingPathComponent("repo-" + repo.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    static func save(repo: String, events: [WeftEvent], highWater: Int) {
        let snap = Snapshot(highWater: highWater, events: Array(events.suffix(WeftLog.perRepoLimit)))
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: file(repo), options: .atomic)
    }

    static func load(repo: String) -> Snapshot {
        guard let data = try? Data(contentsOf: file(repo)),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot(highWater: 0, events: []) }
        return snap
    }

    static func saveRepos(_ repos: [WeftRepo]) {
        guard let data = try? JSONEncoder().encode(repos) else { return }
        try? data.write(to: dir.appendingPathComponent("repos.json"), options: .atomic)
    }

    static func loadRepos() -> [WeftRepo] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("repos.json")) else { return [] }
        return (try? JSONDecoder().decode([WeftRepo].self, from: data)) ?? []
    }

    static func saveCursor(_ cursor: String?) {
        let f = dir.appendingPathComponent("feed-cursor.txt")
        if let cursor { try? Data(cursor.utf8).write(to: f, options: .atomic) } else { try? FileManager.default.removeItem(at: f) }
    }

    static func loadCursor() -> String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("feed-cursor.txt")),
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}

/// What to do when an observer stream closes (spec §9.4 close codes). Pure, so tests can pin it.
enum WeftStreamPolicy {
    enum Action: Equatable { case stop, ignore, pageThenReconnect, backoff }

    nonisolated static func onClose(code: Int) -> Action {
        switch code {
        case 4401, 4403: .stop               // token revoked / out of scope
        case 4404: .ignore                   // repo gone
        case 4413: .pageThenReconnect        // replay cap: page over HTTPS, then reconnect
        default: .backoff                    // network, 1001 going away, 1006, 4500…
        }
    }

    nonisolated static func backoffSeconds(attempt n: Int) -> Int { min(30, 1 << min(max(n, 1), 5)) }
}
