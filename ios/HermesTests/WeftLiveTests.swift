import Foundation
import Testing
@testable import Hermes

/// Responses captured from the deployed weft-gateway preview (B2, card I1b) with
/// `scripts/weft_live_seed.mjs` data: repos ios-demo / ios-site. Raw bodies, no wrapper.
enum WeftLiveFixture {
    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("WeftFixtures/live/live-\(name).json"))
    }
}

@Suite struct WeftLiveGatewayTests {
    @Test func decodesRepoList() throws {
        let list = try JSONDecoder().decode(WeftRepoList.self, from: WeftLiveFixture.data("repos"))
        #expect(list.repos.map(\.repo) == ["ios-demo", "ios-site"])
        let demo = try #require(list.repos.first)
        #expect(demo.headSeq > 0 && demo.activeAgents != nil && demo.openConflicts != nil && demo.lastEventAt != nil)
    }

    @Test func decodesEveryRecordOfTheLiveLog() throws {
        let page = try JSONDecoder().decode(WeftEventPage.self, from: WeftLiveFixture.data("events-demo"))
        #expect(page.repo == "ios-demo" && !page.hasMore && page.nextAfter == page.headSeq)
        #expect(page.events.map(\.seq) == Array(1...page.headSeq))
        // Join records carry a payload but no mode; system and human records have no session.
        let join = page.events[0]
        #expect(join.kind == "join" && join.who == "claude-a" && join.payload?["level"]?.int == 3)
        let blocked = try #require(page.events.first { $0.seq == 8 })
        #expect(blocked.isRejected && blocked.isConflict && blocked.mode == "commit")
        let d = try #require(blocked.diagnostics.first)
        #expect(d.code == "stale_assumption" && d.causedBySeq == 7 && d.causedByAgent == "claude-a" && d.causedByTask == "T-1")
        #expect(d.range == nil && d.suggestion != nil)
        // Edits in list views flag the diff instead of carrying it.
        let edit = try #require(page.events.first { $0.seq == 7 })
        #expect(edit.hasDiff == true && edit.diff == nil && edit.mayHaveDiff)
    }

    @Test func humanAndSystemRecordsDriveCandidatesPauseAndRevert() throws {
        let page = try JSONDecoder().decode(WeftEventPage.self, from: WeftLiveFixture.data("events-demo"))
        var log = WeftLog()
        log.ingest(page.events)
        let approve = try #require(page.events.first { $0.seq == 16 })
        #expect(approve.actor.type == "human" && approve.who == "reviewer" && approve.task == nil)
        let land = try #require(page.events.first { $0.seq == 29 })
        #expect(land.kind == "land" && land.actor.type == "system" && land.who == "codex-b")
        #expect(log.revert(of: land)?.seq == 31)
        // Pause (#25) then resume (#27) from the app.
        #expect(!log.isPaused(agent: "codex-b", repo: "ios-demo"))
        let t2 = log.candidates(task: "T-2", repo: "ios-demo")
        #expect(t2.map(\.change) == ["I-b"] && t2[0].approved && t2[0].landedSeq == 29 && t2[0].reverted)
        let t1 = log.candidates(task: "T-1", repo: "ios-demo")
        #expect(t1.first?.approved == true && t1.first?.landedSeq == 17 && t1.first?.reverted == false)
        #expect(log.thread(for: try #require(page.events.first { $0.seq == 11 })).map(\.seq) == [10, 11])
    }

    /// The gateway drops unknown top-level fields but keeps `payload` verbatim, so the
    /// x_task_title / x_evidence extensions arrive inside payload.
    @Test func readsVendorExtensionsFromPayload() throws {
        let cp = try JSONDecoder().decode(WeftEvent.self, from: WeftLiveFixture.data("event-36-evidence"))
        #expect(cp.taskTitle == "Retry budget for token refresh")
        #expect(cp.evidence?.tests?.passed == 148 && cp.evidence?.review?.verdict == "approve")
        #expect(cp.evidence?.previewURL?.hasPrefix("https://") == true && cp.evidence?.costUSD == 0.42)

        let page = try JSONDecoder().decode(WeftEventPage.self, from: WeftLiveFixture.data("events-demo"))
        var log = WeftLog()
        log.ingest(page.events)
        #expect(log.taskTitle("T-1") == "Retry budget for token refresh")
        #expect(log.candidates(task: "T-2", repo: "ios-demo").first?.evidence?.tests?.failed == 2)

        // Top-level wins over payload; a non-object payload is ignored.
        let both = WeftFixture.record(seq: 1, payload: #"{"x_task_title": "inner"}"#)
        #expect(both.taskTitle == "inner")
        let json = #"{"seq":2,"repo":"r","kind":"edit","ts":"2026-10-05T14:00:00.000Z","actor":{"type":"agent","id":"a"},"summary":"s","diagnostics":[],"x_task_title":"outer","payload":{"x_task_title":"inner"}}"#
        #expect(try JSONDecoder().decode(WeftEvent.self, from: Data(json.utf8)).taskTitle == "outer")
        let scalar = #"{"seq":3,"repo":"r","kind":"edit","ts":"2026-10-05T14:00:00.000Z","actor":{"type":"agent","id":"a"},"summary":"s","diagnostics":[],"payload":[1,2]}"#
        #expect(try JSONDecoder().decode(WeftEvent.self, from: Data(scalar.utf8)).taskTitle == nil)

        // Cache round trip keeps the extensions.
        let back = try JSONDecoder().decode(WeftEvent.self, from: JSONEncoder().encode(cp))
        #expect(back.taskTitle == cp.taskTitle && back.evidence == cp.evidence)
    }

    @Test func decodesFullRecordWithDiff() throws {
        let e = try JSONDecoder().decode(WeftEvent.self, from: WeftLiveFixture.data("event-7-diff"))
        #expect(e.diff?.contains("+export interface RefreshOpts {") == true)
        #expect(e.writes.map(\.kind) == ["signature", "new"])
    }

    /// Frames captured from `stream?after=37` with an auth frame: auth.ok, replay, replay.done, ping.
    @Test func decodesLiveStreamFrames() throws {
        let raw = try JSONSerialization.jsonObject(with: WeftLiveFixture.data("stream-frames")) as! [[String: Any]]
        let frames = try raw.map { try WeftStreamFrame.decode(JSONSerialization.data(withJSONObject: $0)) }
        #expect(frames.first == .other("auth.ok"))
        let seqs = frames.compactMap { if case .event(let e) = $0 { e.seq } else { nil } }
        #expect(seqs == [38, 39, 40])
        guard case .replayDone(let head) = frames[4] else { Issue.record("no replay.done"); return }
        #expect(head == 40)
        guard case .ping(let pingHead) = frames[5] else { Issue.record("no ping"); return }
        #expect(pingHead == 40)
    }
}

@Suite struct WeftStreamPolicyTests {
    @Test func closeCodes() {
        #expect(WeftStreamPolicy.onClose(code: 4413) == .pageThenReconnect)
        #expect(WeftStreamPolicy.onClose(code: 4401) == .stop)
        #expect(WeftStreamPolicy.onClose(code: 4403) == .stop)
        #expect(WeftStreamPolicy.onClose(code: 4404) == .ignore)
        for code in [1000, 1001, 1006, 4500, 4503] { #expect(WeftStreamPolicy.onClose(code: code) == .backoff) }
    }

    @Test func backoffCapsAtThirtySeconds() {
        #expect((1...7).map { WeftStreamPolicy.backoffSeconds(attempt: $0) } == [2, 4, 8, 16, 30, 30, 30])
        #expect(WeftStreamPolicy.backoffSeconds(attempt: 0) == 2)
    }

    /// After a 4413 the store refreshes the head; a gap past the 500-record window pages a fresh tail.
    @Test func gapPastReplayCapPagesTail() {
        #expect(WeftLog.catchUpPlan(highWater: 10, head: 5_110) == .tail)
        #expect(WeftLog.catchUpPlan(highWater: 5_100, head: 5_110) == .after(5_100))
    }
}
