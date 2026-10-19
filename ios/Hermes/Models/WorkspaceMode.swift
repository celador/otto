import Foundation
import Observation

// MARK: - Workspace mode: "enter" a workspace and work inside it
//
// Wide layouts (Mac, iPad regular width): the sidebar shows only that workspace's chats, with a
// back arrow; the detail is a dashboard (chat + the workspace's live board + live usage).
// Compact (iPhone): the drawer list is filtered the same way, with Board / Usage buttons.

/// Which workspace the window is "in", persisted so a relaunch lands back inside it.
@MainActor
@Observable
final class WorkspaceMode {
    /// Mac and iPad keep separate keys (both apps can run on one Mac via the same defaults domain in tests).
    #if os(macOS)
    static let defaultKey = "mac.activeWorkspace"
    #else
    static let defaultKey = "activeWorkspace"
    #endif

    private let defaults: UserDefaults
    private let key: String

    /// The workspace being worked in; nil = the normal all-chats sidebar.
    private(set) var activeID: String?
    /// Where the window was before entering (an `openChat`-style string), restored on exit.
    private(set) var returnTo: String?

    init(defaults: UserDefaults = .standard, key: String = WorkspaceMode.defaultKey) {
        self.defaults = defaults
        self.key = key
        let raw = defaults.string(forKey: key) ?? ""
        activeID = raw.isEmpty ? nil : raw
        returnTo = defaults.string(forKey: key + ".return")
    }

    var isActive: Bool { activeID != nil }

    /// Enter `id`. `from` is the screen to come back to; entering another workspace keeps the
    /// original return point (exit goes back to where you were before the first enter).
    func enter(_ id: String, from current: String?) {
        if activeID == nil { returnTo = current }
        activeID = id
        save()
    }

    /// Leave the workspace; returns where to go back to.
    @discardableResult
    func exit() -> String? {
        let back = returnTo
        activeID = nil
        returnTo = nil
        save()
        return back
    }

    /// Drop a workspace that's gone (archived/deleted) so the app doesn't relaunch into nothing.
    func validate(known ids: [String]) {
        guard let activeID, !ids.isEmpty, !ids.contains(activeID) else { return }
        exit()
    }

    private func save() {
        defaults.set(activeID ?? "", forKey: key)
        if let returnTo { defaults.set(returnTo, forKey: key + ".return") } else { defaults.removeObject(forKey: key + ".return") }
    }
}

enum WorkspaceRouting {
    /// Cmd+N: the workspace a new chat starts in. An explicit "New chat in X" wins; otherwise the
    /// workspace you're in; outside any workspace, nil (an ordinary chat).
    static func newChatWorkspace(explicit: String?, active: String?) -> String? {
        explicit ?? active
    }

    /// The sidebar inside a workspace: only its chats, not archived, newest first.
    static func sidebarRows(_ rows: [WorkspaceSession]) -> [WorkspaceSession] {
        var seen = Set<String>()
        return rows.filter { !($0.archived ?? false) && seen.insert($0.id).inserted }
            .sorted { $0.recency > $1.recency }
    }

    /// Whether a chat on screen belongs in the workspace being entered (else the dashboard opens
    /// on an empty new chat there).
    static func keepsChat(_ sessionID: String?, in rows: [WorkspaceSession]) -> Bool {
        guard let sessionID else { return false }
        return rows.contains { $0.id == sessionID }
    }
}

// MARK: - Dragging chats onto workspaces

/// The drag payload for a chat row ("otto-chat:<id>[,<id>…]"), so a drop only accepts our own rows
/// and a workspace being reordered (its plain id) isn't mistaken for a chat.
enum ChatDragPayload {
    static let prefix = "otto-chat:"

    static func encode(_ ids: [String]) -> String { prefix + ids.joined(separator: ",") }

    static func decode(_ raw: String?) -> [String] {
        guard let raw, raw.hasPrefix(prefix) else { return [] }
        return raw.dropFirst(prefix.count).split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}

/// What's being dragged in the sidebar right now (drop targets highlight only for chats).
@MainActor
enum SidebarDrag {
    static var chats: [String] = []
}

@MainActor
enum ChatDrop {
    /// Moves every dropped chat that isn't already in `target` (nil = out of any workspace).
    /// Returns the ids it moved. `owner` answers which workspace a chat is in now.
    @discardableResult
    static func perform(_ ids: [String], onto target: String?, owner: (String) -> String?,
                        move: (String, String?) async -> Void) async -> [String] {
        var moved: [String] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted && owner(id) != target {
            await move(id, target)
            moved.append(id)
        }
        return moved
    }
}

// MARK: - Live board: which cards are new

struct BoardSnapshot: Equatable {
    /// task id -> status
    var statuses: [String: String]

    init(_ board: KanbanBoard?) {
        var s: [String: String] = [:]
        for c in board?.columns ?? [] { for t in c.tasks { s[t.id] = t.status } }
        statuses = s
    }

    init(statuses: [String: String]) { self.statuses = statuses }

    /// Cards that weren't there last time. The first load (no previous snapshot) marks nothing new,
    /// so opening a workspace doesn't flash every card.
    static func newCards(previous: BoardSnapshot?, current: BoardSnapshot) -> Set<String> {
        guard let previous else { return [] }
        return Set(current.statuses.keys).subtracting(previous.statuses.keys)
    }

    /// A card was added, removed or changed column since last time (usage refreshes on this).
    static func changed(previous: BoardSnapshot?, current: BoardSnapshot) -> Bool {
        guard let previous else { return false }
        return previous != current
    }
}

/// New-card highlight: each id glows for `duration` after it first appears.
struct NewCardHighlights {
    var duration: TimeInterval = 6
    private(set) var since: [String: Date] = [:]

    init(duration: TimeInterval = 6) { self.duration = duration }

    mutating func mark(_ ids: Set<String>, at now: Date = .now) {
        for id in ids where since[id] == nil { since[id] = now }
    }

    func isNew(_ id: String, at now: Date = .now) -> Bool {
        guard let t = since[id] else { return false }
        return now.timeIntervalSince(t) < duration
    }

    mutating func prune(at now: Date = .now) {
        since = since.filter { now.timeIntervalSince($0.value) < duration }
    }
}

// MARK: - Live usage: when to refresh

enum UsageRefreshPolicy {
    /// Poll interval while the panel is visible.
    static let interval: TimeInterval = 12
    /// Board poll interval while visible.
    static let boardInterval: TimeInterval = 5

    /// A run finished: some chat that was working isn't any more.
    static func runFinished(previous: Set<String>, current: Set<String>) -> Bool {
        !previous.subtracting(current).isEmpty
    }

    /// Time for the periodic refresh.
    static func due(last: Date?, now: Date = .now, interval: TimeInterval = UsageRefreshPolicy.interval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Refresh now? Periodic, after a run finishes, or after a card moves.
    static func shouldRefresh(last: Date?, now: Date = .now, previousRunning: Set<String>, running: Set<String>,
                              boardChanged: Bool) -> Bool {
        due(last: last, now: now) || runFinished(previous: previousRunning, current: running) || boardChanged
    }

    /// Tokens for a day (input + output + cache reads), 0 when there's no row.
    nonisolated static func tokens(_ d: UsageResponse.Day?) -> Int {
        guard let d else { return 0 }
        return (d.inputTokens ?? 0) + (d.outputTokens ?? 0) + (d.cacheReadTokens ?? 0)
    }

    /// Today's spend from the daily series (local day), 0 when the server has no row yet.
    static func today(_ days: [UsageResponse.Day], now: Date = .now, calendar: Calendar = .current) -> UsageResponse.Day? {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        let key = f.string(from: now)
        return days.first { $0.day == key }
    }
}

// MARK: - Dashboard pane sizes (remembered)

/// The sections of the dashboard's right column, top to bottom.
enum DashboardSection: String, CaseIterable, Codable, Sendable {
    case board, usage, weft

    /// Height of the section's header row: what's left of it when folded.
    var headerHeight: Double {
        switch self {
        case .board: 35
        case .usage, .weft: 31
        }
    }
}

/// How the right column is shared: one weight per section (relative, normalized over whatever is
/// visible and open, so hiding or folding a section keeps the others' proportions) + which are folded.
struct DashboardSections: Codable, Equatable, Sendable {
    var board: Double
    var usage: Double
    var weft: Double
    var folded: [DashboardSection] = []

    /// Board 45 % / usage 20 % / Weft 35 %: Weft is a real section, not the leftover.
    static let defaults = DashboardSections(board: 0.45, usage: 0.20, weft: 0.35)

    subscript(_ s: DashboardSection) -> Double {
        get {
            switch s {
            case .board: board
            case .usage: usage
            case .weft: weft
            }
        }
        set {
            let v = newValue.isFinite ? max(newValue, 0.0001) : 0.0001
            switch s {
            case .board: board = v
            case .usage: usage = v
            case .weft: weft = v
            }
        }
    }

    func isFolded(_ s: DashboardSection) -> Bool { folded.contains(s) }

    /// Fold to the header row / unfold. The weight is kept, so unfolding restores the old size.
    func togglingFold(_ s: DashboardSection) -> DashboardSections {
        var c = self
        if let i = c.folded.firstIndex(of: s) { c.folded.remove(at: i) } else { c.folded.append(s) }
        return c
    }

    /// Stored as one JSON string in UserDefaults (`dashboard.sections`).
    var raw: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }

    /// The stored value, or (first launch of this layout) one converted from the old keys: the old
    /// board/usage split is kept inside 65 % of the column, and Weft gets 35 % — the old fixed
    /// 176–280 pt Weft strip was what made it too squished, so its old height is not carried over.
    static func load(raw: String?, oldBoardFraction: Double?) -> DashboardSections {
        if let raw, !raw.isEmpty, let d = try? JSONDecoder().decode(DashboardSections.self, from: Data(raw.utf8)),
           [d.board, d.usage, d.weft].allSatisfy({ $0.isFinite && $0 > 0 }) {
            return d
        }
        guard let f = oldBoardFraction, f.isFinite else { return .defaults }
        let b = DashboardLayout.boardFraction(f)
        return DashboardSections(board: 0.65 * b, usage: 0.65 * (1 - b), weft: 0.35)
    }
}

enum DashboardLayout {
    static let minChat: Double = 380
    static let minSide: Double = 260
    /// Upper bound for the right column when the window is wide enough (see `maxSide(total:)`).
    static let maxSide: Double = 900
    static let defaultSide: Double = 400
    /// Every open section keeps at least its header + about one row.
    static let minSection: Double = 64
    /// Divider between two sections: the full height is grab area (a 1 pt line drawn in the middle).
    static let handle: Double = 9

    /// Widest the right column can be in a window this wide: 900 pt, and the chat keeps 380.
    static func maxSide(total: Double) -> Double { max(minSide, min(maxSide, total - minChat)) }

    /// Right column width after a drag, kept within bounds and leaving the chat its minimum.
    static func sideWidth(_ proposed: Double, total: Double) -> Double {
        min(max(proposed, minSide), maxSide(total: total))
    }

    /// Old board share of board + usage (only read when migrating the old key).
    static func boardFraction(_ proposed: Double) -> Double { min(max(proposed, 0.25), 0.85) }

    /// Sections in column order that are switched on.
    static func visible(board: Bool, usage: Bool, weft: Bool) -> [DashboardSection] {
        DashboardSection.allCases.filter { s in
            switch s {
            case .board: board
            case .usage: usage
            case .weft: weft
            }
        }
    }

    /// Height of every visible section in a column `column` pt tall. Folded sections get their
    /// header; open ones share the rest by weight, none below `minSection` (others give way
    /// proportionally). With every section folded, the space below them stays empty.
    static func heights(_ sizes: DashboardSections, visible: [DashboardSection], column: Double) -> [DashboardSection: Double] {
        var out: [DashboardSection: Double] = [:]
        let open = visible.filter { !sizes.isFolded($0) }
        var available = column - Double(max(visible.count - 1, 0)) * handle
        for s in visible where sizes.isFolded(s) {
            out[s] = s.headerHeight
            available -= s.headerHeight
        }
        guard !open.isEmpty else { return out }
        available = max(available, 0)
        if available <= Double(open.count) * minSection {
            for s in open { out[s] = available / Double(open.count) }
            return out
        }
        // Proportional split, then pin anything under the minimum and re-share the rest.
        var pinned = Set<DashboardSection>()
        while true {
            let free = open.filter { !pinned.contains($0) }
            let room = available - Double(pinned.count) * minSection
            let weight = free.reduce(0) { $0 + sizes[$1] }
            var changed = false
            for s in free {
                let h = weight > 0 ? room * sizes[s] / weight : room / Double(free.count)
                if h < minSection { pinned.insert(s); changed = true }
                out[s] = h
            }
            if !changed { break }
        }
        for s in pinned { out[s] = minSection }
        return out
    }

    /// The two open sections a divider between `upper` and `lower` resizes: the nearest open one at or
    /// above it and the nearest at or below it (a folded section in between just rides along).
    /// nil when there's no open section on one side (the divider does nothing).
    static func pair(above upper: DashboardSection, below lower: DashboardSection, visible: [DashboardSection],
                     sizes: DashboardSections) -> (DashboardSection, DashboardSection)? {
        guard let i = visible.firstIndex(of: upper), let j = visible.firstIndex(of: lower), i < j else { return nil }
        let a = visible[...i].last { !sizes.isFolded($0) }
        let b = visible[j...].first { !sizes.isFolded($0) }
        guard let a, let b else { return nil }
        return (a, b)
    }

    /// Dragging the divider between `a` (above) and `b` (below) by `delta` pt (down = positive), from
    /// their heights when the drag started. Only those two change: their combined weight stays the
    /// same (so every other section keeps its size) and neither goes under `minSection`.
    static func drag(_ sizes: DashboardSections, a: DashboardSection, b: DashboardSection,
                     startA: Double, startB: Double, delta: Double) -> DashboardSections {
        let total = startA + startB
        guard total > 0, total >= 2 * minSection else { return sizes }
        let newA = min(max(startA + delta, minSection), total - minSection)
        let weight = sizes[a] + sizes[b]
        var c = sizes
        c[a] = weight * newA / total
        c[b] = weight * (total - newA) / total
        return c
    }

    /// Double-click a divider: the two sections it resizes split their space evenly.
    static func evenSplit(_ sizes: DashboardSections, a: DashboardSection, b: DashboardSection) -> DashboardSections {
        var c = sizes
        let half = (sizes[a] + sizes[b]) / 2
        c[a] = half
        c[b] = half
        return c
    }
}

// MARK: - Whole right panel: collapse / expand (⌥⌘0, the sidebar.right button, drag past the edge)

/// What the right column shows. `showPanel` collapses the whole column without touching the
/// section toggles, so expanding brings back exactly the sections that were there.
struct DashboardPanel: Equatable {
    var showPanel: Bool
    var board: Bool
    var usage: Bool
    var weft: Bool

    /// The column is on screen: the panel is expanded and at least one section is on.
    var columnVisible: Bool { showPanel && (board || usage || weft) }

    /// ⌥⌘0 / the toolbar button. Expanding a panel with every section switched off turns the board
    /// on, so "Show Panel" never shows nothing.
    mutating func togglePanel() {
        if columnVisible {
            showPanel = false
        } else {
            showPanel = true
            if !(board || usage || weft) { board = true }
        }
    }

    /// ⇧⌘B / ⇧⌘U / ⇧⌘E. Turning a section on while the panel is collapsed expands the panel.
    mutating func toggle(_ s: DashboardSection) {
        switch s {
        case .board: board.toggle()
        case .usage: usage.toggle()
        case .weft: weft.toggle()
        }
        if isOn(s) { showPanel = true }
    }

    /// Whether `s` is on screen right now (switched on and the panel expanded).
    func shows(_ s: DashboardSection) -> Bool { showPanel && isOn(s) }

    /// The View menu's "Show/Hide Board" (etc.): hides a section that's on screen; otherwise makes it
    /// visible, expanding a collapsed panel (a section that was already on just comes back).
    mutating func showOrHide(_ s: DashboardSection) {
        if shows(s) { toggle(s) }
        else if isOn(s) { showPanel = true }
        else { toggle(s) }
    }

    func isOn(_ s: DashboardSection) -> Bool {
        switch s {
        case .board: board
        case .usage: usage
        case .weft: weft
        }
    }

    init(showPanel: Bool = true, board: Bool = true, usage: Bool = true, weft: Bool = true) {
        self.showPanel = showPanel
        self.board = board
        self.usage = usage
        self.weft = weft
    }

    /// Reads the persisted state (defaults: everything on).
    init(defaults d: UserDefaults) {
        func flag(_ k: String) -> Bool { d.object(forKey: k) as? Bool ?? true }
        self.init(showPanel: flag(DashboardPrefs.showPanel), board: flag(DashboardPrefs.showBoard),
                  usage: flag(DashboardPrefs.showUsage), weft: flag(DashboardPrefs.showWeft))
    }

    func write(to d: UserDefaults) {
        d.set(showPanel, forKey: DashboardPrefs.showPanel)
        d.set(board, forKey: DashboardPrefs.showBoard)
        d.set(usage, forKey: DashboardPrefs.showUsage)
        d.set(weft, forKey: DashboardPrefs.showWeft)
    }

    /// Applies a change to the stored state (what the toolbar, menu and shortcuts call).
    static func update(_ d: UserDefaults = .standard, _ change: (inout DashboardPanel) -> Void) {
        var p = DashboardPanel(defaults: d)
        change(&p)
        p.write(to: d)
    }
}

extension DashboardLayout {
    /// Dragging the column's edge past this width collapses the panel (like NSSplitView).
    static let collapseBelow: Double = minSide - 90

    enum SideDrag: Equatable {
        case width(Double)
        case collapse
    }

    /// The right column's divider dragged to `proposed` pt: a clamped width, or collapse when it
    /// went well under the minimum. The stored width isn't changed by a collapse.
    static func sideDrag(_ proposed: Double, total: Double) -> SideDrag {
        proposed < collapseBelow ? .collapse : .width(sideWidth(proposed, total: total))
    }
}
