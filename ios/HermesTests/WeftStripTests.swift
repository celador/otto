import Foundation
import Testing
@testable import Hermes

/// The dashboard's Weft strip (WeftStrip.swift): every edit as its own live row, who is editing
/// what, conflicts, landings, installs.
@Suite struct WeftStripTests {
    let now = WeftTime.parse("2026-10-18T05:00:00.000Z")!

    func ev(_ seq: Int, _ kind: String, minutesAgo: Double, status: String = "accepted", change: String? = "hermes-default/t_aaaaaaaa",
            task: String? = "t_aaaaaaaa", files: [String] = [], intent: String? = nil, payload: String? = nil,
            diagnostics: String = "[]", agent: String = "hermes-default", actor: String = "agent") -> WeftEvent {
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
        var json = """
        {"seq": \(seq), "repo": "hermes-ios", "status": "\(status)", "kind": "\(kind)", "ts": "\(ts)",
         "actor": {"type": "\(actor)", "id": "\(actor == "system" ? "weft-pm-land" : agent)"}, "agent": "\(agent)",
         "summary": "s", "diagnostics": \(diagnostics), "files": \(try! String(data: JSONEncoder().encode(files), encoding: .utf8)!)
        """
        if let change { json += #", "change": "\#(change)""# }
        if let task { json += #", "task": "\#(task)""# }
        if let intent { json += #", "intent": "\#(intent)""# }
        if let payload { json += #", "payload": \#(payload)"# }
        json += "}"
        return try! JSONDecoder().decode(WeftEvent.self, from: Data(json.utf8))
    }

    @Test func repoNameFollowsTheAdapter() {
        #expect(WeftStripModel.repo(forFolder: "/Users/sam/code/hermes-ios") == "hermes-ios")
        #expect(WeftStripModel.repo(forFolder: "~/github/gascity.nvim/") == "gascity.nvim")
        #expect(WeftStripModel.repo(forFolder: "/x/My Project!") == "My-Project")
        #expect(WeftStripModel.repo(forFolder: nil) == nil)
        #expect(WeftStripModel.shortAgent("hermes-default") == "default")
        #expect(WeftStripModel.shortAgent("claude-a") == "claude-a")
    }

    @Test func editingNowListsUnlandedChangesWithTheirFilesAndCounts() {
        let m = WeftStripModel.make(events: [
            ev(1, "edit", minutesAgo: 20, files: ["ios/Hermes/Views/WorkspaceDashboard.swift"],
               intent: "t_aaaaaaaa: Weft strip in the dashboard"),
            ev(2, "edit", minutesAgo: 5, files: ["ios/Hermes/Weft/WeftStrip.swift", "ios/Hermes/Views/WorkspaceDashboard.swift"],
               intent: "t_aaaaaaaa: Weft strip in the dashboard"),
            ev(3, "edit", minutesAgo: 2, change: "hermes-backend/t_bbbbbbbb", task: "t_bbbbbbbb", files: ["relay/x.py"],
               agent: "hermes-backend"),
        ], now: now)
        #expect(m.editing.map(\.change) == ["hermes-backend/t_bbbbbbbb", "hermes-default/t_aaaaaaaa"])
        let a = m.editing[1]
        #expect(a.who == "default")
        #expect(a.title == "Weft strip in the dashboard")
        #expect(a.files == ["ios/Hermes/Weft/WeftStrip.swift", "ios/Hermes/Views/WorkspaceDashboard.swift"])
        #expect(a.latest == WeftEventID(repo: "hermes-ios", seq: 2))
        #expect(a.count == 2)
        #expect(a.lastEdit == now.addingTimeInterval(-5 * 60))
        #expect(!a.conflicted)
    }

    /// The point of the card: three saves of the same file are three rows, not one folded row.
    @Test func everyEditIsItsOwnRowNewestFirst() {
        let m = WeftStripModel.make(events: [
            ev(10, "edit", minutesAgo: 3, files: ["scratch.txt"], intent: "t_aaaaaaaa: Every edit visible"),
            ev(12, "edit", minutesAgo: 1, files: ["scratch.txt"]),
            ev(11, "edit", minutesAgo: 2, files: ["scratch.txt"]),
            ev(13, "join", minutesAgo: 1),                          // bookkeeping: not in the feed
            ev(14, "checkpoint", minutesAgo: 0.5, payload: #"{"sha": "abc1234"}"#),   // agent commit: not in the feed
        ], now: now)
        #expect(m.feed.map(\.id.seq) == [12, 11, 10])
        #expect(m.feed.allSatisfy { $0.tone == .edit && $0.title == "scratch.txt" })
        // The card title comes from any record of the change, so later edits without an intent still show it.
        #expect(m.feed.allSatisfy { $0.cardTitle == "Every edit visible" && $0.task == "t_aaaaaaaa" && $0.who == "default" })
        #expect(m.editing.count == 1)
        #expect(m.editing[0].count == 3)
    }

    @Test func feedInterleavesLandsInstallsAndEditsByTime() {
        let m = WeftStripModel.make(events: [
            ev(1, "edit", minutesAgo: 30, files: ["a.swift"]),
            ev(2, "land", minutesAgo: 20, payload: #"{"sha": "25f7af6abcdef", "op_id": "x"}"#, actor: "system"),
            ev(3, "checkpoint", minutesAgo: 10, change: nil, task: nil,
               payload: #"{"sha": "abc1234", "x_install": {"build": "90", "target": "mac", "devices": ["Nano"]}}"#, actor: "system"),
            ev(4, "edit", minutesAgo: 1, change: "hermes-default/t_cccccccc", task: "t_cccccccc", files: ["b.swift", "c.md"]),
        ], now: now)
        #expect(m.feed.map(\.tone) == [.edit, .install, .landed, .edit])
        #expect(m.feed[0].title == "b.swift · c.md")
        #expect(m.feed[1].title == "Build 90 → Mac")
    }

    @Test func expandingACardShowsItsFullTrail() {
        let m = WeftStripModel.make(events: [
            ev(1, "edit", minutesAgo: 9, files: ["a.swift"]),
            ev(2, "edit", minutesAgo: 8, change: "hermes-backend/t_bbbbbbbb", task: "t_bbbbbbbb", files: ["x.py"], agent: "hermes-backend"),
            ev(3, "edit", minutesAgo: 7, files: ["b.swift"]),
            ev(4, "edit", minutesAgo: 6, files: ["a.swift"]),
        ], now: now)
        let a = m.editing.first { $0.change == "hermes-default/t_aaaaaaaa" }!
        #expect(a.trail.map(\.seq) == [4, 3, 1])
        #expect(m.trail(for: a).map(\.id.seq) == [4, 3, 1])
        #expect(m.trail(for: a).allSatisfy { $0.task == "t_aaaaaaaa" })
    }

    /// The blank band under "Every edit · live": an expanded card's trail rows are the same records as
    /// feed rows in the same stack. Shared ids made SwiftUI collapse one copy into empty space.
    @Test func expandedTrailRowsNeverShareAnIdentityWithFeedRows() {
        let m = WeftStripModel.make(events: [
            ev(1, "edit", minutesAgo: 9, files: ["slides.html"]),
            ev(2, "edit", minutesAgo: 8, change: "hermes-backend/t_bbbbbbbb", task: "t_bbbbbbbb", files: ["x.py"], agent: "hermes-backend"),
            ev(3, "edit", minutesAgo: 7, files: ["build_slides.py"]),
        ], now: now)
        let a = m.editing.first { $0.change == "hermes-default/t_aaaaaaaa" }!
        // The same records really are in both lists...
        #expect(Set(m.trail(for: a).map(\.id)).isSubset(of: Set(m.feed.map(\.id))))
        // ...but their row identities differ.
        #expect(m.trailRows(for: a).map(\.item.id.seq) == [3, 1])
        let all = m.renderedKeys(expanded: Set(m.editing.map(\.change)), shown: WeftStripModel.pageSize)
        #expect(all.count == 2 + 1 + 3)
        #expect(Set(all).count == all.count)
        #expect(m.feed.map(\.feedKey) == m.feed.map { WeftStripModel.RowKey.feed($0.id) })
    }

    @Test func landedOrStaleChangesAreNotEditingNowButStayInTheFeed() {
        let m = WeftStripModel.make(events: [
            ev(1, "edit", minutesAgo: 30, files: ["a.swift"]),
            ev(2, "land", minutesAgo: 10, payload: #"{"sha": "25f7af6abcdef", "op_id": "x", "trunk_ref": "refs/heads/rebrand/otto"}"#,
               actor: "system"),
            ev(3, "edit", minutesAgo: 600, change: "hermes-default/t_cccccccc", task: "t_cccccccc", files: ["old.swift"]),
        ], now: now)
        #expect(m.editing.isEmpty)
        #expect(m.feed.map(\.id.seq) == [2, 1, 3])
        #expect(m.feed[0].tone == .landed)
        #expect(m.feed[0].detail == "default · 25f7af6")
    }

    @Test func onlyTaskIntentsNameTheCard() {
        let m = WeftStripModel.make(events: [
            ev(1, "edit", minutesAgo: 9, files: ["a.swift"], intent: "t_aaaaaaaa: Real title"),
            ev(2, "leave", minutesAgo: 8, intent: "hermes process exit"),
            ev(3, "land", minutesAgo: 7, payload: #"{"sha": "95eafa8aaaa"}"#, actor: "system"),
        ], now: now)
        #expect(m.feed.first?.title == "Landed Real title")
        #expect(m.feed.last?.cardTitle == "Real title")
    }

    @Test func blockedAndWarnedEditsCarryAnInlineBadge() {
        let stale = #"[{"severity": "error", "code": "stale_overwrite", "file": "ios/A.swift", "symbol": "ios/A.swift#*", "message": "m", "caused_by_seq": 4, "caused_by_agent": "hermes-default"}]"#
        let wait = #"[{"severity": "warning", "code": "claim_wait", "file": "ios/B.swift", "symbol": "ios/B.swift#*", "message": "m", "caused_by_seq": 4, "caused_by_agent": "hermes-default"}]"#
        let m = WeftStripModel.make(events: [
            ev(5, "edit", minutesAgo: 2, status: "rejected", change: "hermes-backend/t_bbbbbbbb", task: "t_bbbbbbbb",
               files: ["ios/A.swift"], diagnostics: stale, agent: "hermes-backend"),
            ev(6, "edit", minutesAgo: 1, files: ["ios/B.swift"], diagnostics: wait),
        ], now: now)
        #expect(m.feed.count == 2)   // one row per edit; the conflict isn't a second row
        #expect(m.feed[1].tone == .edit)
        #expect(m.feed[1].badge == .blocked("stale overwrite"))
        #expect(m.feed[0].badge == .warned("claim wait"))
        let backend = m.editing.first { $0.change == "hermes-backend/t_bbbbbbbb" }!
        #expect(backend.conflicted)
        #expect(backend.files == [])   // a rejected edit never reached the file
    }

    @Test func nonEditConflictsAreAmberRows() {
        let diag = #"[{"severity": "error", "code": "land_conflict", "file": "ios/A.swift", "symbol": "ios/A.swift#*", "message": "m", "caused_by_seq": 4, "caused_by_agent": "hermes-default"}]"#
        let m = WeftStripModel.make(events: [
            ev(5, "land", minutesAgo: 1, status: "rejected", files: ["ios/A.swift"], diagnostics: diag),
        ], now: now)
        #expect(m.feed.first?.tone == .conflict)
        #expect(m.feed.first?.title == "land conflict · A.swift")
        #expect(m.feed.first?.detail == "default blocked")
    }

    @Test func installsAreBlueWithBuildAndDevice() {
        let m = WeftStripModel.make(events: [
            ev(7, "checkpoint", minutesAgo: 1, change: nil, task: nil,
               payload: #"{"sha": "abc1234", "ref": "refs/heads/rebrand/otto", "x_install": {"build": "87", "target": "mac", "devices": ["Nano"]}}"#,
               actor: "system"),
            ev(6, "checkpoint", minutesAgo: 2, payload: #"{"sha": "abc1234"}"#),   // an agent's commit: not an install
        ], now: now)
        #expect(m.feed.count == 1)
        #expect(m.feed[0].tone == .install)
        #expect(m.feed[0].title == "Build 87 → Mac")
        #expect(m.feed[0].detail == "Nano")
    }

    @Test func probeRunsAreHiddenAndTheFeedIsCapped() {
        var events = [ev(1, "edit", minutesAgo: 1, change: "hermes-default/weft-probe-a-1", task: "weft-probe-a-1", files: ["p.swift"])]
        for i in 0..<(WeftStripModel.feedLimit + 40) {
            events.append(ev(10 + i, "edit", minutesAgo: 10 - Double(i) / 100, files: ["f\(i).swift"]))
        }
        let m = WeftStripModel.make(events: events, now: now)
        #expect(m.feed.count == WeftStripModel.feedLimit)
        #expect(m.feed.first?.id.seq == 10 + WeftStripModel.feedLimit + 39)   // newest kept
        #expect(m.feed.last?.id.seq == 50)                                  // the 40 oldest dropped
        #expect(!m.feed.contains { $0.id.seq == 1 })       // the probe
    }

    @Test func pagingRevealsHeldRowsThenFetchesOlderUntilTheCap() {
        #expect(WeftFeedPaging.next(shown: 60, total: 200, held: 210, reachedStart: false) == .reveal(120))
        #expect(WeftFeedPaging.next(shown: 180, total: 200, held: 210, reachedStart: false) == .reveal(200))
        #expect(WeftFeedPaging.next(shown: 200, total: 200, held: 210, reachedStart: false) == .fetchOlder)
        #expect(WeftFeedPaging.next(shown: 200, total: 200, held: 210, reachedStart: true) == .end)
        #expect(WeftFeedPaging.next(shown: 500, total: 500, held: WeftLog.perRepoLimit, reachedStart: false) == .end)
    }

    @Test func relativeTimesTickLive() {
        let t = now
        #expect(WeftFeedTime.label(t, now: t) == "now")
        #expect(WeftFeedTime.label(t, now: t.addingTimeInterval(12)) == "12s")
        #expect(WeftFeedTime.label(t, now: t.addingTimeInterval(13)) == "13s")   // changes a second later
        #expect(WeftFeedTime.label(t, now: t.addingTimeInterval(4 * 60 + 5)) == "4m")
        #expect(WeftFeedTime.label(t, now: t.addingTimeInterval(2 * 3600)) == "2h")
        #expect(WeftFeedTime.label(t, now: t.addingTimeInterval(3 * 86_400)) == "3d")
        #expect(WeftFeedTime.tick(t, now: t.addingTimeInterval(10)) == 1)
        #expect(WeftFeedTime.tick(t, now: t.addingTimeInterval(120)) == 15)
        // The schedule hands TimelineView one entry per second while the row is fresh.
        var it = WeftTickSchedule(date: t).entries(from: t, mode: .normal)
        let first = (0..<4).compactMap { _ in it.next() }
        #expect(first == [t, t.addingTimeInterval(1), t.addingTimeInterval(2), t.addingTimeInterval(3)])
        #expect(first.map { WeftFeedTime.label(t, now: $0) } == ["now", "now", "now", "now"])
        var later = WeftTickSchedule(date: t).entries(from: t.addingTimeInterval(60), mode: .normal)
        #expect(later.next() == t.addingTimeInterval(60))
        #expect(later.next() == t.addingTimeInterval(75))
    }

    @Test func lineStatsCountTheDiff() {
        let diff = """
        --- a/ios/A.swift
        +++ b/ios/A.swift
        @@ -1,3 +1,4 @@
         keep
        -old
        +new
        +more
        """
        #expect(WeftLineStats.from(diff: diff) == WeftLineStats(added: 2, removed: 1))
        let p = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"x_lines": {"added": 5, "removed": 0}}"#.utf8))
        #expect(WeftLineStats.from(payload: p) == WeftLineStats(added: 5, removed: 0))
        #expect(WeftLineStats.from(payload: nil) == nil)
    }
}
