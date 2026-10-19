import Foundation
import Testing
@testable import Hermes

/// Workspace mode (enter/exit/persist), ⌘N routing, sidebar filtering, chat drops, and the live
/// dashboard's refresh triggers / new-card highlights.
@MainActor
@Suite struct WorkspaceModeTests {
    private func defaults() -> UserDefaults {
        let name = "ws-mode-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func enterExitAndPersistAcrossRelaunch() {
        let d = defaults()
        let mode = WorkspaceMode(defaults: d, key: "k")
        #expect(!mode.isActive && mode.activeID == nil)
        mode.enter("p_otto", from: "session:abc")
        #expect(mode.activeID == "p_otto")
        // A relaunch (new instance on the same defaults) lands back inside.
        let relaunched = WorkspaceMode(defaults: d, key: "k")
        #expect(relaunched.activeID == "p_otto")
        #expect(relaunched.returnTo == "session:abc")
        // Switching workspaces keeps the original return point.
        relaunched.enter("p_weft", from: "session:inside-otto")
        #expect(relaunched.activeID == "p_weft")
        #expect(relaunched.exit() == "session:abc")
        #expect(!relaunched.isActive)
        #expect(WorkspaceMode(defaults: d, key: "k").activeID == nil)
        #expect(WorkspaceMode(defaults: d, key: "k").returnTo == nil)
    }

    @Test func goneWorkspaceIsDroppedOnLaunch() {
        let d = defaults()
        let mode = WorkspaceMode(defaults: d, key: "k")
        mode.enter("p_archived", from: nil)
        mode.validate(known: [])            // not loaded yet: keep it
        #expect(mode.activeID == "p_archived")
        mode.validate(known: ["p_otto"])    // loaded, and it's gone
        #expect(mode.activeID == nil)
    }

    @Test func commandNRoutesIntoTheActiveWorkspace() {
        #expect(WorkspaceRouting.newChatWorkspace(explicit: nil, active: "p_otto") == "p_otto")
        #expect(WorkspaceRouting.newChatWorkspace(explicit: nil, active: nil) == nil)
        // "New chat in X" (⌥⌘N, context menu) wins over the workspace you're in.
        #expect(WorkspaceRouting.newChatWorkspace(explicit: "p_weft", active: "p_otto") == "p_weft")
        #expect(WorkspaceRouting.newChatWorkspace(explicit: "p_weft", active: nil) == "p_weft")
    }

    private func row(_ id: String, _ last: Double, archived: Bool? = nil) -> WorkspaceSession {
        WorkspaceSession(id: id, title: id, preview: nil, source: "api_server", startedAt: last, lastActive: last,
                         messageCount: 1, model: nil, archived: archived)
    }

    @Test func sidebarShowsOnlyLiveChatsNewestFirst() {
        let rows = [row("old", 1), row("new", 9), row("gone", 5, archived: true), row("new", 9), row("mid", 4)]
        #expect(WorkspaceRouting.sidebarRows(rows).map(\.id) == ["new", "mid", "old"])
        #expect(WorkspaceRouting.keepsChat("mid", in: rows))
        #expect(!WorkspaceRouting.keepsChat("elsewhere", in: rows))
        #expect(!WorkspaceRouting.keepsChat(nil, in: rows))
    }

    @Test func sidebarFilteringUsesTheStoreRowsForThatWorkspace() {
        // The store's rows for a workspace (cache + moves since) feed the sidebar.
        let w = Workspace(id: "p_otto", slug: "otto", name: "Otto", sessionIds: ["a", "b"])
        let known = [
            SessionSummary(id: "a", source: nil, title: "A", preview: nil, model: nil, startedAt: 1, lastActive: 1,
                           messageCount: 1, pinned: nil, archived: nil),
            SessionSummary(id: "b", source: nil, title: "B", preview: nil, model: nil, startedAt: 3, lastActive: 3,
                           messageCount: 1, pinned: nil, archived: nil),
            SessionSummary(id: "c", source: nil, title: "C", preview: nil, model: nil, startedAt: 5, lastActive: 5,
                           messageCount: 1, pinned: nil, archived: nil),
        ]
        // "a" was just dragged out; "c" (not a member) was dropped in.
        let pending: [String: String?] = ["a": String?.none, "c": "p_otto"]
        let rows = WorkspaceSessionCache.rows(for: "p_otto", workspace: w, cached: nil, known: known, pending: pending)
        #expect(WorkspaceRouting.sidebarRows(rows).map(\.id) == ["c", "b"])
    }

    @Test func chatDragPayloadOnlyAcceptsOurRows() {
        #expect(ChatDragPayload.decode(ChatDragPayload.encode(["s1", "s2"])) == ["s1", "s2"])
        #expect(ChatDragPayload.decode("p_otto").isEmpty)          // a workspace being reordered
        #expect(ChatDragPayload.decode("https://example.com").isEmpty)
        #expect(ChatDragPayload.decode(nil).isEmpty)
    }

    @Test func dropCallsMoveForEachChatNotAlreadyThere() async {
        var calls: [(String, String?)] = []
        let owners = ["s1": "p_weft", "s2": "p_otto"]
        let moved = await ChatDrop.perform(["s1", "s2", "s3", "s1"], onto: "p_otto", owner: { owners[$0] }) { id, to in
            calls.append((id, to))
        }
        #expect(moved == ["s1", "s3"])                       // s2 is already in Otto; duplicates once
        #expect(calls.map(\.0) == ["s1", "s3"])
        #expect(calls.allSatisfy { $0.1 == "p_otto" })

        // Dropped on the back arrow: out of the workspace.
        calls = []
        await ChatDrop.perform(["s2"], onto: nil, owner: { owners[$0] }) { id, to in calls.append((id, to)) }
        #expect(calls.count == 1 && calls[0].0 == "s2" && calls[0].1 == nil)
    }

    // MARK: Live board

    @Test func newCardsHighlightOnlyAfterTheFirstLoad() {
        let first = BoardSnapshot(statuses: ["t1": "todo", "t2": "running"])
        #expect(BoardSnapshot.newCards(previous: nil, current: first).isEmpty)   // opening doesn't flash everything
        let next = BoardSnapshot(statuses: ["t1": "todo", "t2": "running", "t3": "ready"])
        #expect(BoardSnapshot.newCards(previous: first, current: next) == ["t3"])
        #expect(BoardSnapshot.changed(previous: first, current: next))
        let moved = BoardSnapshot(statuses: ["t1": "done", "t2": "running", "t3": "ready"])
        #expect(BoardSnapshot.newCards(previous: next, current: moved).isEmpty)
        #expect(BoardSnapshot.changed(previous: next, current: moved))           // status change refreshes usage
        #expect(!BoardSnapshot.changed(previous: moved, current: moved))
        #expect(!BoardSnapshot.changed(previous: nil, current: moved))
    }

    @Test func highlightFadesAfterItsDuration() {
        var h = NewCardHighlights(duration: 6)
        let t0 = Date(timeIntervalSince1970: 1000)
        h.mark(["t3"], at: t0)
        #expect(h.isNew("t3", at: t0.addingTimeInterval(2)))
        #expect(!h.isNew("t1", at: t0))
        // Marking again doesn't restart the glow.
        h.mark(["t3"], at: t0.addingTimeInterval(4))
        #expect(!h.isNew("t3", at: t0.addingTimeInterval(7)))
        h.prune(at: t0.addingTimeInterval(7))
        #expect(h.since.isEmpty)
    }

    @Test func boardJSONBecomesASnapshot() throws {
        let json = """
        {"columns": [{"name": "todo", "tasks": [{"id": "t1", "title": "A", "status": "todo"}]},
                     {"name": "running", "tasks": [{"id": "t2", "title": "B", "status": "running"}]}]}
        """
        let board = try HermesClient.decoder.decode(KanbanBoard.self, from: Data(json.utf8))
        #expect(BoardSnapshot(board).statuses == ["t1": "todo", "t2": "running"])
        #expect(BoardSnapshot(nil).statuses.isEmpty)
    }

    // MARK: Live usage

    @Test func usageRefreshesOnTimerRunEndAndCardMoves() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(UsageRefreshPolicy.due(last: nil, now: now))
        #expect(!UsageRefreshPolicy.due(last: now.addingTimeInterval(-5), now: now))
        #expect(UsageRefreshPolicy.due(last: now.addingTimeInterval(-12), now: now))
        // A chat stopped working: refresh at once.
        #expect(UsageRefreshPolicy.runFinished(previous: ["a", "b"], current: ["b"]))
        #expect(!UsageRefreshPolicy.runFinished(previous: ["b"], current: ["b", "c"]))   // a run starting isn't "finished"
        let recent = now.addingTimeInterval(-3)
        #expect(!UsageRefreshPolicy.shouldRefresh(last: recent, now: now, previousRunning: ["a"], running: ["a"], boardChanged: false))
        #expect(UsageRefreshPolicy.shouldRefresh(last: recent, now: now, previousRunning: ["a"], running: [], boardChanged: false))
        #expect(UsageRefreshPolicy.shouldRefresh(last: recent, now: now, previousRunning: [], running: [], boardChanged: true))
    }

    @Test func todayIsPickedFromTheDailySeries() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Montevideo")!
        let json = """
        {"daily": [{"day": "2026-10-17", "estimated_cost": 4.5, "input_tokens": 10},
                   {"day": "2026-10-18", "estimated_cost": 1.25, "input_tokens": 100, "output_tokens": 20, "cache_read_tokens": 1000}],
         "totals": null, "models": [], "period_days": 14}
        """
        let u = try HermesClient.decoder.decode(UsageResponse.self, from: Data(json.utf8))
        // ~01:00 on the 18th in Montevideo (04:00 UTC): the local day, not UTC's.
        let now = Date(timeIntervalSince1970: 1_792_296_000)
        let d = try #require(UsageRefreshPolicy.today(u.daily, now: now, calendar: cal))
        #expect(d.day == "2026-10-18" && d.cost == 1.25)
        #expect(UsageRefreshPolicy.tokens(d) == 1120)
        #expect(UsageRefreshPolicy.today([], now: now, calendar: cal)?.day == nil)
    }

    @Test func sessionCostDecodesFromTheGatewayList() throws {
        let json = """
        {"id": "s", "source": "api_server", "title": "T", "estimated_cost_usd": 1.08, "actual_cost_usd": null}
        """
        let s = try HermesClient.decoder.decode(SessionSummary.self, from: Data(json.utf8))
        #expect(s.cost == 1.08)
        let none = try HermesClient.decoder.decode(SessionSummary.self, from: Data(#"{"id": "s"}"#.utf8))
        #expect(none.cost == nil)
    }

    @Test func dashboardPaneSizesStayUsable() {
        #expect(DashboardLayout.sideWidth(100, total: 1400) == DashboardLayout.minSide)
        #expect(DashboardLayout.sideWidth(2000, total: 1400) == 900)
        // A narrow window leaves the chat its minimum.
        #expect(DashboardLayout.sideWidth(500, total: 800) == 420)
        #expect(DashboardLayout.boardFraction(0.1) == 0.25 && DashboardLayout.boardFraction(0.99) == 0.85)
    }

    @Test func maxSideGrowsWithTheWindow() {
        #expect(DashboardLayout.maxSide(total: 2400) == 900)
        #expect(DashboardLayout.maxSide(total: 1280) == 900)
        #expect(DashboardLayout.maxSide(total: 1000) == 620)
        // Tiny window: never below the column's own minimum.
        #expect(DashboardLayout.maxSide(total: 500) == DashboardLayout.minSide)
        #expect(DashboardLayout.sideWidth(800, total: 1100) == 720)
    }

    private let all = DashboardSection.allCases
    private func approx(_ a: Double?, _ b: Double, _ eps: Double = 0.001) -> Bool { abs((a ?? .nan) - b) < eps }
    private func sum(_ h: [DashboardSection: Double]) -> Double { h.values.reduce(0, +) }

    @Test func defaultSplitGivesWeftARealShare() {
        let h = DashboardLayout.heights(.defaults, visible: all, column: 900)
        let room = 900 - 2 * DashboardLayout.handle
        #expect(approx(h[.board], room * 0.45))
        #expect(approx(h[.usage], room * 0.20))
        #expect(approx(h[.weft], room * 0.35))
        #expect(h[.weft]! > 176)
        #expect(approx(sum(h) + 2 * DashboardLayout.handle, 900))
    }

    @Test func dragBetweenTwoSectionsConservesTheirSumAndRespectsMinimums() {
        let s = DashboardSections.defaults
        let h = DashboardLayout.heights(s, visible: all, column: 900)
        // Drag the usage|weft divider up 100 pt: weft grows, usage shrinks, board untouched.
        let d = DashboardLayout.drag(s, a: .usage, b: .weft, startA: h[.usage]!, startB: h[.weft]!, delta: -100)
        #expect(approx(d.usage + d.weft, s.usage + s.weft, 1e-9))
        #expect(d.board == s.board)
        let h2 = DashboardLayout.heights(d, visible: all, column: 900)
        #expect(approx(h2[.board], h[.board]!))
        #expect(approx(h2[.usage]! + h2[.weft]!, h[.usage]! + h[.weft]!))
        #expect(approx(h2[.weft], h[.weft]! + 100))
        // Way past the edge: stops at the minimum.
        let far = DashboardLayout.drag(s, a: .usage, b: .weft, startA: h[.usage]!, startB: h[.weft]!, delta: -5000)
        let h3 = DashboardLayout.heights(far, visible: all, column: 900)
        #expect(approx(h3[.usage], DashboardLayout.minSection))
        #expect(approx(h3[.board], h[.board]!))
        let down = DashboardLayout.drag(s, a: .board, b: .usage, startA: h[.board]!, startB: h[.usage]!, delta: 5000)
        #expect(approx(DashboardLayout.heights(down, visible: all, column: 900)[.usage], DashboardLayout.minSection))
    }

    @Test func noSectionGoesBelowItsMinimum() {
        let s = DashboardSections(board: 0.98, usage: 0.01, weft: 0.01)
        let h = DashboardLayout.heights(s, visible: all, column: 600)
        #expect(h.values.allSatisfy { $0 >= DashboardLayout.minSection - 0.001 })
        #expect(approx(sum(h) + 2 * DashboardLayout.handle, 600))
        // A column too short for every minimum just splits evenly.
        let tiny = DashboardLayout.heights(.defaults, visible: all, column: 120)
        #expect(approx(tiny[.board], tiny[.weft]!))
    }

    @Test func hidingASectionRenormalizesAndShowingRestores() {
        let s = DashboardSections.defaults
        let two = DashboardLayout.heights(s, visible: [.board, .weft], column: 800)
        let room = 800 - DashboardLayout.handle
        #expect(two[.usage] == nil)
        #expect(approx(two[.board], room * 0.45 / 0.80))
        #expect(approx(two[.weft], room * 0.35 / 0.80))
        // Same weights, usage back: identical to never having hidden it.
        #expect(DashboardLayout.heights(s, visible: all, column: 800) == DashboardLayout.heights(.defaults, visible: all, column: 800))
        let one = DashboardLayout.heights(s, visible: [.weft], column: 800)
        #expect(approx(one[.weft], 800))
        #expect(DashboardLayout.visible(board: true, usage: false, weft: true) == [.board, .weft])
    }

    @Test func foldAndUnfoldRestoresThePriorSize() {
        var s = DashboardSections.defaults
        let before = DashboardLayout.heights(s, visible: all, column: 900)
        s = s.togglingFold(.board)
        #expect(s.isFolded(.board))
        let folded = DashboardLayout.heights(s, visible: all, column: 900)
        #expect(folded[.board] == DashboardSection.board.headerHeight)
        // The others take the space, in their own proportion.
        #expect(approx(folded[.usage]! / folded[.weft]!, 0.20 / 0.35))
        #expect(approx(sum(folded) + 2 * DashboardLayout.handle, 900))
        s = s.togglingFold(.board)
        #expect(!s.isFolded(.board))
        #expect(DashboardLayout.heights(s, visible: all, column: 900) == before)
        // Survives the round trip through UserDefaults.
        let saved = DashboardSections.defaults.togglingFold(.usage)
        #expect(DashboardSections.load(raw: saved.raw, oldBoardFraction: nil) == saved)
    }

    @Test func dividerNextToAFoldedSectionResizesTheOpenNeighbours() {
        let s = DashboardSections.defaults.togglingFold(.usage)
        let p1 = DashboardLayout.pair(above: .board, below: .usage, visible: all, sizes: s)
        let p2 = DashboardLayout.pair(above: .usage, below: .weft, visible: all, sizes: s)
        #expect(p1?.0 == .board && p1?.1 == .weft)
        #expect(p2?.0 == .board && p2?.1 == .weft)
        // Folded at the edge: nothing open on that side, the divider is inert.
        let top = DashboardSections.defaults.togglingFold(.board)
        #expect(DashboardLayout.pair(above: .board, below: .usage, visible: all, sizes: top) == nil)
        #expect(DashboardLayout.pair(above: .usage, below: .weft, visible: all, sizes: top)?.0 == .usage)
    }

    @Test func doubleClickSplitsTheTwoNeighboursEvenly() {
        let s = DashboardLayout.evenSplit(.defaults, a: .board, b: .usage)
        #expect(approx(s.board, 0.325, 1e-9) && approx(s.usage, 0.325, 1e-9) && s.weft == 0.35)
        let h = DashboardLayout.heights(s, visible: all, column: 900)
        #expect(approx(h[.board], h[.usage]!))
    }

    @Test func migratesFromTheOldKeys() {
        // Nothing stored: the new defaults.
        #expect(DashboardSections.load(raw: nil, oldBoardFraction: nil) == .defaults)
        #expect(DashboardSections.load(raw: "", oldBoardFraction: nil) == .defaults)
        #expect(DashboardSections.load(raw: "garbage", oldBoardFraction: nil) == .defaults)
        // Old board/usage split kept inside 65 %; Weft gets 35 % (more than the old 176–280 pt strip).
        let m = DashboardSections.load(raw: nil, oldBoardFraction: 0.62)
        #expect(approx(m.board, 0.65 * 0.62, 1e-9) && approx(m.usage, 0.65 * 0.38, 1e-9) && m.weft == 0.35)
        #expect(DashboardLayout.heights(m, visible: all, column: 800)[.weft]! > 260)
        // Out-of-range old value is clamped like before.
        #expect(approx(DashboardSections.load(raw: nil, oldBoardFraction: 0.99).board, 0.65 * 0.85, 1e-9))
        // A stored new value wins over the old key.
        let stored = DashboardSections(board: 0.2, usage: 0.2, weft: 0.6)
        #expect(DashboardSections.load(raw: stored.raw, oldBoardFraction: 0.62) == stored)
    }
}
