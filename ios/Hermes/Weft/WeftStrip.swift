import SwiftUI

// MARK: - Weft strip: every edit Weft records on this workspace's repo, live, in the dashboard
//
// "Every edit visible": each save an agent makes is its own Weft `edit` record, and each one is its
// own row here, newest first, appearing as it lands in the log (WeftStore polls the combined feed
// every few seconds while the strip is on screen). Landings (green), installs/releases (blue) and
// conflicts that aren't edits (amber) are interleaved by time with their own styling. Above the feed,
// "Editing now" keeps the per-card view: each running card's edit count and last-edit time,
// expandable to that card's full trail. Rows open the Weft event detail, whose diff is the point.

/// Pure view model so the strip's rules are unit-tested (HermesTests/WeftStripTests).
struct WeftStripModel: Equatable {
    struct Editing: Identifiable, Equatable {
        var change: String
        var who: String
        var task: String?
        var title: String?
        var files: [String]
        var lastEdit: Date
        var conflicted: Bool
        var latest: WeftEventID
        /// How many edit records the card made since its last landing.
        var count: Int = 0
        /// Those edits, newest first.
        var trail: [WeftEventID] = []
        var id: String { change }
    }

    enum Tone: String, Equatable { case edit, conflict, landed, install }

    /// What Weft said about an edit, shown inline on its row.
    enum Badge: Equatable {
        /// Rejected (enforce mode): the edit was blocked. Label is the diagnostic code.
        case blocked(String)
        /// Accepted with a warning squiggle.
        case warned(String)

        var label: String {
            switch self {
            case .blocked(let s), .warned(let s): s
            }
        }
    }

    struct Item: Identifiable, Equatable {
        var id: WeftEventID
        var tone: Tone
        var title: String
        var detail: String
        var date: Date
        // Edit rows only.
        var files: [String] = []
        var task: String?
        var cardTitle: String?
        var who: String = ""
        var badge: Badge?
        /// This record's identity as a feed row (distinct from the same record in a card's trail).
        var feedKey: RowKey { .feed(id) }
    }

    var editing: [Editing] = []
    /// The live feed, newest first: one row per edit record, plus landings, installs and other conflicts.
    var feed: [Item] = []

    /// Edits older than this with no landing are stale claims, not "editing now".
    nonisolated static let editingWindow: TimeInterval = 3 * 3600
    /// The most rows the feed builds (WeftLog holds at most 500 records per repo anyway).
    nonisolated static let feedLimit = WeftLog.perRepoLimit
    /// Rows shown before "Show older", and how many each tap adds.
    nonisolated static let pageSize = 60

    /// Weft repo for a workspace folder: the project directory's name, sanitized exactly like the
    /// Hermes adapter (`sanitize_repo`): ~/code/hermes-ios -> hermes-ios.
    nonisolated static func repo(forFolder folder: String?) -> String? {
        guard let folder, !folder.isEmpty else { return nil }
        let base = (folder as NSString).lastPathComponent
        var s = base.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        while let f = s.first, "._-".contains(f) { s.removeFirst() }
        s = String(s.prefix(64))
        while s.hasSuffix("-") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// `hermes-default` -> `default`; other harnesses keep their id.
    nonisolated static func shortAgent(_ a: String) -> String {
        a.hasPrefix("hermes-") ? String(a.dropFirst("hermes-".count)) : a
    }

    /// The adapter writes `intent: "<task id>: <card title>"`.
    nonisolated static func title(fromIntent intent: String?, task: String?) -> String? {
        guard let intent, !intent.isEmpty else { return nil }
        if let task, intent.hasPrefix(task + ": ") { return String(intent.dropFirst(task.count + 2)) }
        return intent
    }

    /// Probe runs (scripts/weft_conflict_probe.py) are tests, not work.
    nonisolated static func isProbe(_ e: WeftEvent) -> Bool {
        (e.change ?? "").contains("/weft-probe-") || (e.task ?? "").hasPrefix("weft-probe-")
    }

    nonisolated static func isConflict(_ e: WeftEvent) -> Bool {
        e.isRejected || e.diagnostics.contains { $0.severity == "error" || $0.severity == "warning" }
    }

    nonisolated static func install(_ e: WeftEvent) -> JSONValue? {
        guard e.kind == "checkpoint", e.status == "accepted", let x = e.payload?["x_install"], case .object = x else { return nil }
        return x
    }

    nonisolated static func badge(_ e: WeftEvent) -> Badge? {
        let d = e.diagnostics.first { $0.severity == "error" } ?? e.diagnostics.first { $0.severity == "warning" }
        let code = d.map { $0.code.replacingOccurrences(of: "_", with: " ") }
        if e.isRejected { return .blocked(code ?? "blocked") }
        if let code { return .warned(code) }
        return nil
    }

    /// `src/a/B.swift`, `c.md` -> "B.swift · c.md"; past `max` names, "+N".
    nonisolated static func fileNames(_ files: [String], max: Int = 3) -> String {
        let names = files.prefix(max).map { ($0 as NSString).lastPathComponent }
        let more = files.count > max ? ["+\(files.count - max)"] : []
        return (names + more).joined(separator: " · ")
    }

    /// `events`: one repo's records in any order.
    nonisolated static func make(events raw: [WeftEvent], now: Date = Date()) -> WeftStripModel {
        let events = raw.filter { !isProbe($0) }.sorted { $0.seq < $1.seq }
        var lastLand: [String: Int] = [:]
        var titles: [String: String] = [:]   // change -> card title, from any record of it
        for e in events {
            if e.kind == "land", e.status == "accepted", let c = e.change { lastLand[c] = e.seq }
            // Only "<task>: <title>" intents name the card (a leave's intent is "hermes process exit").
            if let c = e.change, let task = e.task, let intent = e.intent, intent.hasPrefix(task + ": ") {
                titles[c] = String(intent.dropFirst(task.count + 2))
            } else if let c = e.change, let t = e.taskTitle {
                titles[c] = t
            }
        }
        var editing: [String: Editing] = [:]
        for e in events where e.kind == "edit" {
            guard let c = e.change, e.seq > (lastLand[c] ?? 0), now.timeIntervalSince(e.date) < editingWindow else { continue }
            var row = editing[c] ?? Editing(change: c, who: shortAgent(e.who), task: e.task, title: titles[c], files: [],
                                            lastEdit: e.date, conflicted: false, latest: e.id)
            if e.status == "accepted" {
                for f in e.files.reversed() where !row.files.contains(f) { row.files.insert(f, at: 0) }
            }
            row.lastEdit = max(row.lastEdit, e.date)
            row.latest = e.id
            row.conflicted = row.conflicted || isConflict(e)
            row.count += 1
            row.trail.insert(e.id, at: 0)
            editing[c] = row
        }
        var feed: [Item] = []
        // Newest first by time (seq breaks ties), like the Changes feed.
        let byTime = events.sorted { $0.epoch != $1.epoch ? $0.epoch > $1.epoch : $0.seq > $1.seq }
        for e in byTime {
            if feed.count >= feedLimit { break }
            if e.kind == "edit" {
                let cardTitle = e.change.flatMap { titles[$0] } ?? title(fromIntent: e.intent, task: e.task) ?? e.taskTitle
                feed.append(Item(id: e.id, tone: .edit, title: fileNames(e.files), detail: cardTitle ?? e.task ?? "",
                                 date: e.date, files: e.files, task: e.task, cardTitle: cardTitle,
                                 who: shortAgent(e.who), badge: badge(e)))
            } else if let x = install(e) {
                let build = x["build"]?.string ?? x["build"]?.int.map(String.init) ?? "?"
                let target = x["target"]?.string ?? "install"
                let devices = (x["devices"]?.array ?? []).compactMap(\.string)
                feed.append(Item(id: e.id, tone: .install, title: "Build \(build) → \(targetLabel(target))",
                                 detail: devices.isEmpty ? shortSha(e) : devices.joined(separator: ", "), date: e.date))
            } else if e.kind == "land", e.status == "accepted" {
                let who = e.task ?? e.change.map { String($0.split(separator: "/").last ?? "") } ?? "change"
                let what = e.taskTitle ?? e.change.flatMap { titles[$0] } ?? who
                feed.append(Item(id: e.id, tone: .landed, title: "Landed \(what)",
                                 detail: [shortAgent(e.who), shortSha(e)].filter { !$0.isEmpty }.joined(separator: " · "),
                                 date: e.date, task: e.task))
            } else if isConflict(e), e.kind == "land" || e.kind == "intent" {
                let d = e.diagnostics.first { $0.severity == "error" } ?? e.diagnostics.first { $0.severity == "warning" }
                let file = d?.file ?? e.files.first ?? ""
                let code = (d?.code ?? (e.isRejected ? "rejected" : "conflict")).replacingOccurrences(of: "_", with: " ")
                feed.append(Item(id: e.id, tone: .conflict, title: "\(code) · \((file as NSString).lastPathComponent)",
                                 detail: e.isRejected ? "\(shortAgent(e.who)) blocked" : "\(shortAgent(e.who)) warned",
                                 date: e.date, task: e.task))
            }
        }
        return WeftStripModel(editing: editing.values.sorted { $0.lastEdit > $1.lastEdit }, feed: feed)
    }

    /// A card's edit rows, newest first (the "Editing now" expansion).
    func trail(for row: Editing) -> [Item] {
        let ids = Set(row.trail)
        return feed.filter { ids.contains($0.id) }
    }

    /// Identity of a rendered row. A card's trail rows are the same edit records as rows in the feed
    /// below; both lists sit in one stack, so they need distinct identities or SwiftUI collapses the
    /// duplicates and leaves a blank band under "Every edit · live".
    enum RowKey: Hashable {
        case trail(change: String, WeftEventID)
        case feed(WeftEventID)
    }

    struct TrailRow: Identifiable, Equatable {
        var change: String
        var item: Item
        var id: RowKey { .trail(change: change, item.id) }
    }

    /// The expansion under an "Editing now" card, keyed apart from the feed rows.
    func trailRows(for row: Editing) -> [TrailRow] {
        trail(for: row).map { TrailRow(change: row.change, item: $0) }
    }

    /// Every row key the strip renders, top to bottom (tests pin that none repeat).
    func renderedKeys(expanded: Set<String>, shown: Int) -> [RowKey] {
        var keys: [RowKey] = []
        for card in editing where expanded.contains(card.change) { keys += trailRows(for: card).map(\.id) }
        keys += feed.prefix(shown).map { .feed($0.id) }
        return keys
    }

    nonisolated static func targetLabel(_ t: String) -> String {
        switch t {
        case "mac": "Mac"
        case "ios": "iPhone/iPad"
        case "testflight-ios": "TestFlight (iOS)"
        case "testflight-mac": "TestFlight (Mac)"
        default: t
        }
    }

    private nonisolated static func shortSha(_ e: WeftEvent) -> String {
        guard let s = e.payload?["sha"]?.string else { return "" }
        return String(s.prefix(7))
    }
}

/// "Show older": reveal more held rows, then ask the gateway for older records while the repo's
/// held window (WeftLog keeps 500 per repo) has room. Pure, so tests pin it.
enum WeftFeedPaging: Equatable {
    case reveal(Int)
    case fetchOlder
    case end

    nonisolated static func next(shown: Int, total: Int, held: Int, reachedStart: Bool,
                                 page: Int = WeftStripModel.pageSize, cap: Int = WeftLog.perRepoLimit) -> WeftFeedPaging {
        if shown < total { return .reveal(min(total, shown + page)) }
        if reachedStart || held >= cap { return .end }
        return .fetchOlder
    }
}

/// Relative times that tick: "now", "12s", "4m", "2h", "3d". Pure so the tick is testable;
/// `WeftTickingTime` re-renders it on a timer.
enum WeftFeedTime {
    nonisolated static func label(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<5: return "now"
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3600)h"
        default: return "\(s / 86_400)d"
        }
    }

    /// How often the label can change: every second for the first minute, then every 15 s.
    nonisolated static func tick(_ date: Date, now: Date) -> TimeInterval {
        now.timeIntervalSince(date) < 60 ? 1 : 15
    }
}

/// +/- line counts of an edit, from its unified diff (or `payload.x_lines` if a producer sends it).
struct WeftLineStats: Equatable, Sendable {
    var added: Int
    var removed: Int

    nonisolated static func from(diff: String) -> WeftLineStats {
        var a = 0, r = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { a += 1 } else if line.hasPrefix("-") { r += 1 }
        }
        return WeftLineStats(added: a, removed: r)
    }

    nonisolated static func from(payload: JSONValue?) -> WeftLineStats? {
        guard let x = payload?["x_lines"], let a = x["added"]?.int, let r = x["removed"]?.int else { return nil }
        return WeftLineStats(added: a, removed: r)
    }
}

/// What the strip shows above its rows. Pure, so the rules are unit-tested.
enum WeftStripState: Equatable {
    /// Asking the Hermes host for the Weft connection.
    case connecting
    /// Auto-config failed: the reason, and a Connect button (the only place it appears).
    case connect(reason: String)
    /// The workspace has no project folder.
    case noFolder
    /// Connected, but the gateway has no repo for this folder.
    case notTracked(repo: String)
    case ready(repo: String)

    nonisolated static func make(configured: Bool, auto: WeftAutoStatus, repo: String?,
                                 knownRepos: Set<String>?, hasEvents: Bool) -> WeftStripState {
        guard let repo else { return .noFolder }
        guard configured else {
            if case .failed(let f) = auto { return .connect(reason: f.message) }
            return .connecting
        }
        if !hasEvents, let knownRepos, !knownRepos.contains(repo) { return .notTracked(repo: repo) }
        return .ready(repo: repo)
    }
}

extension WeftStripModel.Tone {
    var color: Color {
        switch self {
        case .edit: .accentColor
        case .conflict: .orange
        case .landed: .green
        case .install: .blue
        }
    }
    var symbol: String {
        switch self {
        case .edit: "pencil"
        case .conflict: "exclamationmark.triangle.fill"
        case .landed: "arrow.triangle.merge"
        case .install: "shippingbox.fill"
        }
    }
}

/// A relative time that keeps itself current ("now" → "5s" → "1m"…).
struct WeftTickingTime: View {
    let date: Date

    var body: some View {
        TimelineView(WeftTickSchedule(date: date)) { ctx in
            Text(WeftFeedTime.label(date, now: ctx.date))
                .font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
        }
        .help(date.formatted(date: .abbreviated, time: .standard))
    }
}

/// Every second for a fresh row, every 15 s once it's a minute old.
struct WeftTickSchedule: TimelineSchedule {
    let date: Date
    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        let date = date
        return AnyIterator {
            defer { next = next.addingTimeInterval(WeftFeedTime.tick(date, now: next)) }
            return next
        }
    }
}

/// Opens a kanban card from a Weft row (sheet item).
private struct WeftCardRef: Identifiable, Equatable {
    var task: KanbanTask
    var board: String
    var id: String { task.id }
}

/// The strip: a compact header, "Editing now" per card, then the live feed of every edit.
struct WeftStripPanel: View {
    let workspaceID: String
    var compact = true
    @State private var store = WeftStore.shared
    @State private var workspaces = WorkspaceStore.shared
    @State private var actions = WeftActionRouter()
    @State private var opened: WeftEventID?
    @State private var openedCard: WeftCardRef?
    @State private var showSettings = false
    @State private var expanded: Set<String> = []
    @State private var shown = WeftStripModel.pageSize
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    private var workspace: Workspace? { workspaces.workspace(id: workspaceID) }
    private var repo: String? { WeftStripModel.repo(forFolder: workspace?.folder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .onAppear { store.hold() }
        .task(id: repo) {
            shown = WeftStripModel.pageSize
            expanded = []
            await store.autoConfigure()
            await store.refreshKnownRepos()
            if let repo { await store.ensureRepo(repo) }
            #if DEBUG
            // Unattended screenshots: -weft.expandEditing YES expands every "Editing now" card (its trail),
            // re-checked for 30 s so cards that arrive after the first page are expanded too.
            if UserDefaults.standard.bool(forKey: "weft.expandEditing"), let repo {
                for _ in 0..<30 {
                    let changes = Set(WeftStripModel.make(events: store.log.events(repo: repo)).editing.map(\.change))
                    if !changes.isSubset(of: expanded) { expanded.formUnion(changes) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // Unattended screenshots: -weft.openEdit latest|<seq> opens that edit's detail (diff).
            if let s = UserDefaults.standard.string(forKey: "weft.openEdit"), let repo {
                let d = UserDefaults.standard.double(forKey: "weft.openEditDelay")
                let delay = d > 0 ? d : 4
                try? await Task.sleep(for: .seconds(delay))
                let edits = WeftStripModel.make(events: store.log.events(repo: repo)).feed.filter { $0.tone == .edit }
                opened = Int(s).map { WeftEventID(repo: repo, seq: $0) } ?? edits.first?.id
            }
            #endif
        }
        .onDisappear { store.unhold() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.resume()
                Task { await store.autoConfigure() }
            }
        }
        .onChange(of: store.isConfigured) { _, on in
            if on, let repo { Task { await store.ensureRepo(repo) } }
        }
        .sheet(item: $opened) { id in
            NavigationStack {
                WeftEventDetailView(id: id)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { opened = nil } }
                    }
            }
            .environment(\.weftOpen, WeftOpenAction { opened = $0 })
            .weftActions(actions, store: store)
            #if os(macOS)
            .frame(minWidth: 640, minHeight: 560)
            #endif
        }
        .sheet(item: $openedCard) { ref in
            NavigationStack {
                if let client = app.kanbanClient {
                    TaskDetailView(client: client, board: ref.board, taskID: ref.task.id, initial: ref.task) {}
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { openedCard = nil } }
                        }
                }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 520)
            #endif
        }
        .sheet(isPresented: $showSettings) { WeftSettingsView() }
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            HStack(spacing: 6) {
                DashboardFoldChevron()
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Weft").font(.system(size: 12, weight: .semibold))
                if let repo { Text(repo).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
                if store.isConfigured {
                    Circle().fill(store.isLive(now: ctx.date) ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(store.isLive(now: ctx.date) ? "Live" : "Not live")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .dashboardFoldHeader()
    }

    @ViewBuilder private var content: some View {
        let events = repo.map { store.log.events(repo: $0) } ?? []
        switch WeftStripState.make(configured: store.isConfigured, auto: store.autoStatus, repo: repo,
                                   knownRepos: store.knownRepos, hasEvents: !events.isEmpty) {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to Weft…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .connect(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text("Weft didn't connect: \(reason)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Try Again") { Task { await store.autoConfigure(renew: true) } }.font(.caption)
                    Button("Connect…") { showSettings = true }.font(.caption)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .noFolder:
            Text("This workspace has no project folder, so there's no Weft repo to follow.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        case .notTracked(let repo):
            Text("Weft isn't tracking \(repo) yet.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .ready(let repo):
            let model = WeftStripModel.make(events: events)
            let rows = Array(model.feed.prefix(shown))
            ScrollView {
                // VStack, not LazyVStack: the feed is paged (`shown`), so laziness buys nothing, and a lazy
                // stack on macOS keeps stale placeholder heights when rows animate in above others.
                VStack(alignment: .leading, spacing: 1) {
                    if model.editing.isEmpty && model.feed.isEmpty {
                        Text(store.isLoading ? "Loading…" : "Nothing from Weft on \(repo) yet.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    if !model.editing.isEmpty {
                        sectionLabel("Editing now")
                        ForEach(model.editing) { card in
                            editingRow(card)
                            if expanded.contains(card.change) {
                                ForEach(model.trailRows(for: card)) { row in
                                    feedRow(row.item).padding(.leading, 14)
                                }
                            }
                        }
                    }
                    if !model.feed.isEmpty {
                        sectionLabel("Every edit · live")
                        ForEach(rows, id: \.feedKey) { item in
                            feedRow(item)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }
                        pager(repo: repo, total: model.feed.count, held: events.count)
                    }
                }
                .padding(.vertical, 4)
                .animation(.snappy(duration: 0.3), value: rows.map(\.id))
                .animation(.snappy(duration: 0.25), value: expanded)
            }
        }
    }

    @ViewBuilder private func pager(repo: String, total: Int, held: Int) -> some View {
        let step = WeftFeedPaging.next(shown: shown, total: total, held: held, reachedStart: store.reachedStart.contains(repo))
        switch step {
        case .reveal(let n):
            pagerButton("Show older (\(total - shown) more)") { shown = n }
        case .fetchOlder:
            pagerButton(store.loadingOlder ? "Loading…" : "Load older from Weft") {
                Task {
                    await store.loadOlder(repos: [repo])
                    shown += WeftStripModel.pageSize
                }
            }
            .disabled(store.loadingOlder)
        case .end:
            Text(held >= WeftLog.perRepoLimit ? "Older edits: Changes tab" : "That's everything Weft has for \(repo).")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func pagerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 1)
    }

    private func editingRow(_ row: WeftStripModel.Editing) -> some View {
        let open = expanded.contains(row.change)
        return Button {
            if open { expanded.remove(row.change) } else { expanded.insert(row.change) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 8)
                if row.conflicted {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                } else {
                    PulsingDot(size: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title ?? row.task ?? row.change).font(.system(size: 11.5)).lineLimit(1)
                    Text(([row.who, row.count == 1 ? "1 edit" : "\(row.count) edits"]
                          + [WeftStripModel.fileNames(row.files, max: compact ? 2 : 6)].filter { !$0.isEmpty })
                        .joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                WeftTickingTime(date: row.lastEdit)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide this card's edits" : "Show all \(row.count) edits from this card")
        .accessibilityLabel("\(row.title ?? row.change), \(row.count) edits")
    }

    private func feedRow(_ item: WeftStripModel.Item) -> some View {
        let fresh = store.fresh.contains(item.id)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.tone.symbol).font(.system(size: 9)).foregroundStyle(item.tone.color.opacity(item.tone == .edit ? 0.8 : 1))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.title.isEmpty ? "edit" : item.title)
                        .font(.system(size: 11.5, weight: item.tone == .edit ? .medium : .regular))
                        .foregroundStyle(item.tone == .conflict ? Color.orange : Color.primary)
                        .lineLimit(1)
                        .help(item.files.joined(separator: "\n"))
                    if let badge = item.badge { badgeView(badge) }
                    if item.tone == .edit { WeftLineStatsLabel(id: item.id) }
                }
                if item.tone == .edit {
                    HStack(spacing: 4) {
                        if let task = item.task { cardLink(task) }
                        Text([item.cardTitle, item.who.isEmpty ? nil : item.who].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if !item.detail.isEmpty {
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            WeftTickingTime(date: item.date)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .background(rowBackground(item, fresh: fresh), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { opened = item.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { opened = item.id }
    }

    private func rowBackground(_ item: WeftStripModel.Item, fresh: Bool) -> Color {
        if fresh { return Color.accentColor.opacity(0.16) }
        if item.badge != nil { return Color.orange.opacity(0.08) }
        return item.tone == .edit ? .clear : item.tone.color.opacity(0.07)
    }

    private func badgeView(_ b: WeftStripModel.Badge) -> some View {
        let color: Color = if case .blocked = b { .red } else { .orange }
        return Text(b.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }

    private func cardLink(_ task: String) -> some View {
        Button { openCard(task) } label: {
            Text(task).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Open card \(task)")
    }

    /// The card from the workspace's board (already loaded by the board panel), else fetched.
    private func openCard(_ id: String) {
        for (slug, board) in workspaces.boards {
            if let t = board.columns.flatMap(\.tasks).first(where: { $0.id == id }) {
                openedCard = WeftCardRef(task: t, board: slug)
                return
            }
        }
        guard let client = app.kanbanClient, let slug = workspace?.boardSlug, !slug.isEmpty else { return }
        Task {
            if let d = try? await client.task(id, board: slug) { openedCard = WeftCardRef(task: d.task, board: slug) }
        }
    }
}

/// "+12 −3" for an edit row, loaded lazily from the record's diff when the row first shows.
struct WeftLineStatsLabel: View {
    let id: WeftEventID
    @State private var store = WeftStore.shared

    var body: some View {
        HStack(spacing: 3) {
            if let s = store.lineStats[id] {
                if s.added > 0 { Text("+\(s.added)").foregroundStyle(.green) }
                if s.removed > 0 { Text("−\(s.removed)").foregroundStyle(.red) }
            } else {
                // Something real to hang `.task` on (an empty view never appears, so never loads).
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
        .task(id: id) { await store.loadLineStats(id) }
    }
}
