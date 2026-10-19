import Foundation
import Testing
@testable import Hermes

/// The dashboard's whole-panel collapse (⌥⌘0) and the live card times.
@MainActor
@Suite struct DashboardPanelTests {
    private func defaults() -> UserDefaults {
        let name = "dash-panel-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Panel collapse

    @Test func collapseKeepsSectionTogglesAndExpandRestoresThem() {
        var p = DashboardPanel(showPanel: true, board: true, usage: false, weft: true)
        p.togglePanel()
        #expect(!p.showPanel && !p.columnVisible)
        #expect(p.board && !p.usage && p.weft)  // untouched
        p.togglePanel()
        #expect(p == DashboardPanel(showPanel: true, board: true, usage: false, weft: true))
    }

    @Test func expandingWithEverySectionOffShowsTheBoard() {
        var p = DashboardPanel(showPanel: true, board: false, usage: false, weft: false)
        #expect(!p.columnVisible)
        p.togglePanel()
        #expect(p.columnVisible && p.board && !p.usage && !p.weft)
    }

    @Test func sectionShortcutsWhileCollapsed() {
        // ⇧⌘B on a collapsed panel whose board is on: brings the panel back (board still on).
        var p = DashboardPanel(showPanel: false, board: true, usage: true, weft: false)
        p.showOrHide(.board)
        #expect(p == DashboardPanel(showPanel: true, board: true, usage: true, weft: false))
        // ⇧⌘E for a section that's off, while collapsed: turns it on and expands.
        var q = DashboardPanel(showPanel: false, board: true, usage: false, weft: false)
        q.showOrHide(.weft)
        #expect(q.showPanel && q.weft && q.board)
        // Visible section: hides just that section.
        q.showOrHide(.board)
        #expect(q.showPanel && !q.board && q.weft)
    }

    @Test func panelStatePersistsAcrossRelaunch() {
        let d = defaults()
        #expect(DashboardPanel(defaults: d) == DashboardPanel())  // fresh install: everything on
        DashboardPanel.update(d) { $0.usage = false }
        DashboardPanel.update(d) { $0.togglePanel() }
        let relaunched = DashboardPanel(defaults: d)
        #expect(relaunched == DashboardPanel(showPanel: false, board: true, usage: false, weft: true))
        #expect(d.object(forKey: DashboardPrefs.showPanel) as? Bool == false)
        DashboardPanel.update(d) { $0.togglePanel() }
        #expect(DashboardPanel(defaults: d) == DashboardPanel(showPanel: true, board: true, usage: false, weft: true))
    }

    @Test func draggingTheEdgePastTheMinimumCollapses() {
        let total = 1400.0
        #expect(DashboardLayout.sideDrag(500, total: total) == .width(500))
        #expect(DashboardLayout.sideDrag(DashboardLayout.minSide - 20, total: total) == .width(DashboardLayout.minSide))
        #expect(DashboardLayout.sideDrag(DashboardLayout.collapseBelow - 1, total: total) == .collapse)
        #expect(DashboardLayout.sideDrag(-50, total: total) == .collapse)
        #expect(DashboardLayout.sideDrag(5000, total: total) == .width(DashboardLayout.maxSide(total: total)))
    }

    // MARK: Card times

    private func task(_ status: String, created: Double? = 1000, started: Double? = nil, run: Double? = nil,
                      completed: Double? = nil, beat: Double? = nil) -> KanbanTask {
        KanbanTask(id: "t_x", title: "x", body: nil, assignee: nil, status: status, priority: nil,
                   createdAt: created, startedAt: started, completedAt: completed, result: nil,
                   latestSummary: nil, commentCount: nil, lastFailureError: nil, blockKind: nil,
                   currentRunStartedAt: run, lastHeartbeatAt: beat)
    }

    @Test func datePerStatus() {
        let d = { (t: Double) in Date(timeIntervalSince1970: t) }
        // Running: the current run's start (a retry's), not the first-ever start or the creation.
        #expect(CardTime.of(task("running", started: 2000, run: 3000, beat: 3100)) == .running(since: d(3000), heartbeat: d(3100)))
        #expect(CardTime.of(task("running", started: 2000)) == .running(since: d(2000), heartbeat: nil))
        #expect(CardTime.of(task("done", started: 2000, completed: 4000)) == .done(d(4000)))
        for s in ["todo", "ready", "blocked", "review", "triage"] {
            #expect(CardTime.of(task(s, started: 2000, completed: 4000)) == .created(d(1000)))
        }
        #expect(CardTime.of(task("todo", created: nil)) == nil)
    }

    @Test func runningLabelTicksOverSimulatedTime() {
        let start = Date(timeIntervalSince1970: 10_000)
        let t = CardTime.running(since: start, heartbeat: start.addingTimeInterval(5))
        #expect(t.label(now: start.addingTimeInterval(3)) == "running 3s")
        #expect(t.label(now: start.addingTimeInterval(4)) == "running 4s")
        #expect(t.label(now: start.addingTimeInterval(12 * 60 + 30)) == "running 12m")
        #expect(t.label(now: start.addingTimeInterval(3900)) == "running 1h 5m")
        #expect(t.heartbeatLabel(now: start.addingTimeInterval(45)) == "beat 40s ago")
        #expect(CardTime.done(start).heartbeatLabel(now: start) == nil)
    }

    @Test func relativeLabelChangesOverSimulatedTime() {
        let d = Date(timeIntervalSince1970: 50_000)
        let a = CardTime.created(d).label(now: d.addingTimeInterval(3))
        let b = CardTime.created(d).label(now: d.addingTimeInterval(9))
        let c = CardTime.created(d).label(now: d.addingTimeInterval(600))
        #expect(a == "3s ago" && b == "9s ago")
        #expect(c != b && c.contains("10"))
    }

    @Test func scheduleTicksEverySecondThenEvery15s() {
        let anchor = Date(timeIntervalSince1970: 0)
        let it = LiveTimeSchedule(anchor: anchor).entries(from: anchor, mode: .normal)
        let first = (0..<62).compactMap { _ in it.next() }.map { $0.timeIntervalSince1970 }
        #expect(first[0] == 0 && first[1] == 1 && first[59] == 59 && first[60] == 60)
        #expect(first[61] == 75)  // a minute old: every 15 s
        #expect(CardTime.nextTick(after: Date(timeIntervalSince1970: 3600), anchor: anchor).timeIntervalSince1970 == 3615)
    }

    @Test func boardPayloadDecodesRunFields() throws {
        let json = #"{"id":"t_1","title":"T","status":"running","created_at":1,"started_at":2,"current_run_started_at":3,"last_heartbeat_at":4}"#
        let t = try HermesClient.decoder.decode(KanbanTask.self, from: Data(json.utf8))
        #expect(t.currentRunStartedAt == 3 && t.lastHeartbeatAt == 4 && t.startedAt == 2)
        let old = try HermesClient.decoder.decode(KanbanTask.self, from: Data(#"{"id":"t_2","title":"T","status":"todo"}"#.utf8))
        #expect(old.currentRunStartedAt == nil)
    }
}
