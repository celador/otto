import Foundation
import Testing
@testable import Hermes

/// The combined feed (`GET /v1/feed`, spec §9.5) as the phone now reads it: one poll instead of
/// a WebSocket per repo. `live-feed-tail.json` is a slice of a real `tail=1` page from
/// weft-gateway-preview (2026-10-09): cto probe edits/releases from Hermes profiles, whole-file
/// edits and a land in weft, a blocked edit and a join in weft-demo.
@Suite struct WeftFeedTests {
    static func page() throws -> WeftFeedPage {
        try JSONDecoder().decode(WeftFeedPage.self, from: WeftLiveFixture.data("feed-tail"))
    }

    static func event(_ p: WeftFeedPage, _ repo: String, _ seq: Int) throws -> WeftEvent {
        try #require(p.events.first { $0.repo == repo && $0.seq == seq })
    }

    @Test func decodesLiveFeedPage() throws {
        let p = try Self.page()
        #expect(p.events.count == 14 && !p.hasMore)
        #expect(p.cursor.hasPrefix("v0."))
        #expect(Set(p.events.map(\.repo)) == ["cto", "weft", "weft-demo"])
        var log = WeftLog()
        log.ingest(p.events)
        #expect(log.resumePoint("cto") == 8 && log.combined.first?.id == WeftEventID(repo: "cto", seq: 8))
    }

    // MARK: "*" (whole-file key) rendering

    @Test func whole_file_edits_and_releases_name_the_file() throws {
        let p = try Self.page()
        #expect(WeftSummary.render(try Self.event(p, "cto", 4)) == "Created weft-probe-2.md")
        #expect(WeftSummary.render(try Self.event(p, "cto", 7)) == "Released its claim on weft-probe.md (expired)")
        #expect(WeftSummary.render(try Self.event(p, "cto", 8)) == "Released its claim on weft-probe-2.md (expired)")
        #expect(WeftSummary.withActor(try Self.event(p, "cto", 2)) == "hermes-webmaster created weft-probe.md")
        // 43 whole-file writes: named by file, rest counted, the coordinator's reason kept.
        let big = WeftSummary.render(try Self.event(p, "weft", 603))
        #expect(big.hasPrefix("Edited run-4.driver.log, created "))
        #expect(big.contains(" more") && big.hasSuffix("— M2 milestone: full demo scenario end to end"))
        // Mixed: files by name, parsed symbols keep the symbol phrasing.
        let mixed = WeftSummary.render(try Self.event(p, "weft", 652))
        #expect(mixed.contains("removed b, base +4 more in .probe.mjs"))
        #expect(WeftSummary.render(try Self.event(p, "weft", 638)) == "Landed hermes-backend/t_dc8956a4 (4 files)")
        // No rendered summary anywhere shows the bare key.
        for e in p.events {
            #expect(!WeftSummary.render(e).contains("*"), "\(e.id): \(WeftSummary.render(e))")
            #expect(!WeftSummary.withActor(e).contains("*"))
        }
    }

    @Test func parsed_symbols_keep_the_coordinators_summary() throws {
        let p = try Self.page()
        let blocked = try Self.event(p, "weft-demo", 578)
        #expect(WeftSummary.rebuild(blocked) == nil)
        #expect(WeftSummary.render(blocked).hasPrefix("Blocked: claude-t3-r4 added refreshSession"))
        let cp = try Self.event(p, "weft", 608)
        #expect(WeftSummary.render(cp).hasPrefix("Pushed checkpoint 8430787"))
    }

    @Test func whole_file_keys_display_as_the_file() {
        #expect(WeftSymbol.isWholeFile("docs/try-it.md#*") && !WeftSymbol.isWholeFile("src/a.ts#f"))
        #expect(WeftSymbol.display("docs/try-it.md#*") == "try-it.md")
        #expect(WeftSymbol.display("src/a.ts#Store.get") == "Store.get")
        #expect(WeftSummary.names(["a/x.md#*", "b/y.json#*", "c/z.py#*"]) == "x.md, y.json +1 more")
    }

    // MARK: Default kind filter

    @Test func default_feed_hides_session_bookkeeping() throws {
        let p = try Self.page()
        var log = WeftLog()
        log.ingest(p.events)
        let shown = log.filtered(WeftFilter())
        #expect(Set(shown.map(\.kind)) == ["edit", "checkpoint", "land"])
        #expect(!shown.contains { ["join", "leave", "release", "claim"].contains($0.kind) })
        #expect(shown.map(\.id).contains(WeftEventID(repo: "weft-demo", seq: 578)))   // blocked edit stays
        // The toggle brings everything back.
        #expect(log.filtered(WeftFilter(showSessionEvents: true)).count == p.events.count)
        // Picking a session kind explicitly shows it without the toggle.
        #expect(log.filtered(WeftFilter(kinds: [.claim])).map(\.kind) == ["release", "release"])
        #expect(WeftFilter().isEmpty && !WeftFilter(showSessionEvents: true).isEmpty)
        #expect(WeftFilter(showSessionEvents: true).count == 1)
    }

    @Test func blocked_or_squiggled_bookkeeping_is_never_hidden() throws {
        let json = #"{"seq":9,"repo":"r","status":"rejected","kind":"claim","ts":"2026-10-09T10:00:00Z","actor":{"type":"agent","id":"a"},"agent":"a","writes":[{"key":"x.md#*","kind":"body"}],"summary":"Blocked: a claimed *"}"#
        let e = try JSONDecoder().decode(WeftEvent.self, from: Data(json.utf8))
        #expect(!e.isSessionBookkeeping)
        #expect(WeftFilter().matches(e))
        #expect(WeftSummary.render(e) == "Blocked: Claimed x.md")
    }

    @Test func filters_saved_by_older_builds_still_load() throws {
        let old = #"{"repos":["cto"],"tasks":[],"agents":[],"kinds":["edit"],"onlyConflicts":false}"#
        let f = try JSONDecoder().decode(WeftFilter.self, from: Data(old.utf8))
        #expect(f.repos == ["cto"] && f.kinds == [.edit] && !f.showSessionEvents)
        let round = try JSONDecoder().decode(WeftFilter.self, from: JSONEncoder().encode(WeftFilter(showSessionEvents: true)))
        #expect(round.showSessionEvents)
    }

    // MARK: Header + polling

    @Test func repos_sort_by_activity_and_header_counts_the_last_7_days() throws {
        let p = try Self.page()
        var log = WeftLog()
        log.ingest(p.events)
        #expect(log.reposByActivity == ["cto", "weft", "weft-demo"])
        let now = try #require(WeftTime.parse("2026-10-09T15:00:00Z"))
        // weft-demo's newest record here is 2026-10-04: still inside 7 days of the 9th.
        #expect(log.activeRepos(days: 7, now: now) == ["cto", "weft", "weft-demo"])
        #expect(log.activeRepos(days: 1, now: now) == ["cto"])

        let live = WeftHeaderStatus(configured: true, live: true, loading: false, everSucceeded: true, active: ["cto", "weft"], hasSaved: true)
        #expect(live.text == "Live · 2 repos" && live.tone == .live)
        #expect(WeftHeaderStatus(configured: true, live: true, loading: false, everSucceeded: true, active: ["cto"], hasSaved: true).text == "Live · cto")
        let first = WeftHeaderStatus(configured: true, live: false, loading: true, everSucceeded: false, active: [], hasSaved: false)
        #expect(first.text == "Connecting" && first.tone == .connecting)
        let stale = WeftHeaderStatus(configured: true, live: false, loading: true, everSucceeded: true, active: ["cto"], hasSaved: true)
        #expect(stale.text == "Offline · saved changes" && stale.tone == .offline)
    }

    @MainActor @Test func live_means_a_poll_succeeded_in_the_last_15_seconds() {
        let store = WeftStore(config: nil, useCache: false)
        #expect(!store.isLive())
        #expect(WeftPollPolicy.liveWindow == 15)
    }

    @Test func poll_interval_eases_off_when_quiet_and_backs_off_on_failure() {
        #expect(WeftPollPolicy.interval(idlePolls: 0, failures: 0) == 4)
        #expect(WeftPollPolicy.interval(idlePolls: 20, failures: 0) == 7)
        #expect(WeftPollPolicy.interval(idlePolls: 100, failures: 0) == 10)
        // The slowest idle poll plus a ~3 s round trip still lands inside the live window.
        #expect(WeftPollPolicy.interval(idlePolls: 1_000, failures: 0) + 3 < WeftPollPolicy.liveWindow)
        #expect((1...6).map { WeftPollPolicy.interval(idlePolls: 0, failures: $0) } == [2, 4, 8, 16, 30, 30])
    }
}
