import Foundation
import Testing
@testable import Hermes

/// Pinned WCP v0.1 payloads from ~/github/weft packages/protocol/fixtures/messages/valid
/// (branch wt/p1 @ 0c42178), copied into WeftFixtures/. Each file is {"schema", "value"}.
enum WeftFixture {
    static func value(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("WeftFixtures/\(name).json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: obj["value"]!)
    }

    static func record(seq: Int, repo: String = "r", kind: String = "edit", ts: String? = nil, agent: String = "a",
                       status: String = "accepted", task: String? = nil, change: String? = nil,
                       payload: String? = nil, diagnostics: String = "[]", diff: String? = nil) -> WeftEvent {
        var json = """
        {"seq": \(seq), "repo": "\(repo)", "status": "\(status)", "kind": "\(kind)",
         "ts": "\(ts ?? String(format: "2026-10-05T14:%02d:%02d.000Z", seq / 60, seq % 60))",
         "actor": {"type": "agent", "id": "\(agent)", "harness": "codex"}, "agent": "\(agent)",
         "summary": "\(agent) did \(kind) #\(seq)", "diagnostics": \(diagnostics)
        """
        if let task { json += #", "task": "\#(task)""# }
        if let change { json += #", "change": "\#(change)""# }
        if let payload { json += #", "payload": \#(payload)"# }
        if let diff { json += #", "diff": \#(String(data: try! JSONEncoder().encode(diff), encoding: .utf8)!)"# }
        json += "}"
        return try! JSONDecoder().decode(WeftEvent.self, from: Data(json.utf8))
    }
}

@Suite struct WeftDecodingTests {
    @Test func legacyWorkersDevPreviewOriginIsRewritten() throws {
        // Synthetic subdomain; the real one is never written down.
        let sha = String(repeating: "a", count: 40)
        let json = """
        {"preview_url": "https://weft-previews-preview.acme-co.workers.dev/p/r/\(sha)/SIG/",
         "screenshots": ["https://weft-previews-preview.acme-co.workers.dev/e/SIG/x.png",
                         "https://weft-previews.acme-co.workers.dev/e/S2/k.png",
                         "https://weft-previews-preview.elier.ai/e/S3/ok.png",
                         "https://other.acme-co.workers.dev/e/S4/kept.png"]}
        """
        let ev = try JSONDecoder().decode(WeftEvidence.self, from: Data(json.utf8))
        #expect(ev.previewURL == "https://weft-previews-preview.elier.ai/p/r/\(sha)/SIG/")
        #expect(ev.screenshots == [
            "https://weft-previews-preview.elier.ai/e/SIG/x.png",
            "https://weft-previews.elier.ai/e/S2/k.png",
            "https://weft-previews-preview.elier.ai/e/S3/ok.png",
            "https://other.acme-co.workers.dev/e/S4/kept.png",
        ])
    }

    @Test func decodesEventsPage() throws {
        let page = try JSONDecoder().decode(WeftEventPage.self, from: WeftFixture.value("events-page"))
        #expect(page.repo == "weft-demo" && page.headSeq == 20 && page.nextAfter == 13 && page.hasMore)
        #expect(page.events.map(\.seq) == [12, 13])
        let edit = page.events[0]
        #expect(edit.kind == "edit" && edit.actor.harness == "claude-code" && edit.who == "claude-a")
        #expect(edit.writes == [WeftWrite(key: "src/auth/session.ts#refreshToken", kind: "signature")])
        #expect(edit.hasDiff == true && edit.diff == nil && edit.mayHaveDiff)
        #expect(edit.tool?.harnessEvent == "PostToolUse" && edit.transcript?.offset == 1824)
        #expect(!edit.isConflict)

        let blocked = page.events[1]
        #expect(blocked.isRejected && blocked.isConflict && blocked.mode == "check")
        let d = try #require(blocked.diagnostics.first)
        #expect(d.severity == "error" && d.code == "stale_assumption")
        #expect(d.causedBySeq == 12 && d.causedByAgent == "claude-a" && d.causedByTask == "T-1")
        #expect(d.range?.start.line == 41 && d.range?.end.character == 22)
        #expect(WeftSymbol.name(d.symbol) == "refreshToken" && WeftSymbol.file(d.symbol) == "src/auth/session.ts")
    }

    @Test func decodesDetailFeedAndRepos() throws {
        let detail = try JSONDecoder().decode(WeftEvent.self, from: WeftFixture.value("event-detail"))
        #expect(detail.diff?.contains("+export async function refreshToken(token: string, opts: RefreshOpts)") == true)
        #expect(detail.date == ISO8601DateFormatter.withFraction.date(from: "2026-10-05T14:03:11.204Z"))

        let feed = try JSONDecoder().decode(WeftFeedPage.self, from: WeftFixture.value("feed-page"))
        #expect(feed.events.count == 1 && feed.cursor.hasPrefix("v0.") && !feed.hasMore)

        let repos = try JSONDecoder().decode(WeftRepoList.self, from: WeftFixture.value("repos"))
        #expect(repos.repos.first?.repo == "weft-demo" && repos.repos.first?.openConflicts == 1)
    }

    @Test func decodesStreamFrames() throws {
        guard case .event(let e) = try WeftStreamFrame.decode(WeftFixture.value("stream-event")) else {
            Issue.record("expected event frame"); return
        }
        #expect(e.seq == 13 && e.isRejected)
        #expect(try WeftStreamFrame.decode(WeftFixture.value("stream-ping")) == .ping(headSeq: 20))
        #expect(try WeftStreamFrame.decode(WeftFixture.value("stream-replay-done")) == .replayDone(headSeq: 20))
        #expect(try WeftStreamFrame.decode(Data(#"{"type":"x_future","n":1}"#.utf8)) == .other("x_future"))
    }

    @Test func decodesLandRevertAndActionResult() throws {
        let land = try JSONDecoder().decode(WeftEvent.self, from: WeftFixture.value("record-land"))
        #expect(land.group == .land && land.actor.type == "system" && land.who == "claude-a" && land.actor.id == "landing-queue")
        #expect(land.payload?["op_id"]?.string == "op_000031" && land.session == nil && land.reads.isEmpty)

        let revert = try JSONDecoder().decode(WeftEvent.self, from: WeftFixture.value("record-revert"))
        #expect(revert.payload?["reverts_seq"]?.int == 31 && revert.payload?["requested_by"]?["id"]?.string == "john")

        let result = try JSONDecoder().decode(WeftActionResult.self, from: WeftFixture.value("action-result"))
        #expect(result.seq == 21 && result.record.kind == "control" && result.record.who == "john")
        #expect(result.record.payload?["target"]?["agent"]?.string == "codex-b")
    }

    @Test func toleratesUnknownKindsAndFields() throws {
        let json = #"{"seq": 5, "repo": "r", "status": "accepted", "kind": "x_teleport", "ts": "2026-10-05T14:00:00Z", "actor": {"type": "agent", "id": "z", "x_new": 1}, "summary": "z teleported", "x_whatever": {"a": [1, null]}}"#
        let e = try JSONDecoder().decode(WeftEvent.self, from: Data(json.utf8))
        #expect(e.group == .other && e.files.isEmpty && e.writes.isEmpty && e.diagnostics.isEmpty)
        #expect(e.date == ISO8601DateFormatter().date(from: "2026-10-05T14:00:00Z"))
    }

    /// Our action encodings must match the spec's pinned HumanAction fixtures exactly.
    @Test func encodesHumanActionsLikeTheSpec() throws {
        func same(_ action: WeftAction, _ fixture: String) throws -> Bool {
            let mine = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: action.json)) as! NSDictionary
            let pinned = try JSONSerialization.jsonObject(with: WeftFixture.value(fixture)) as! NSDictionary
            return mine == pinned
        }
        #expect(try same(.approve(change: "I4f2a", task: nil, note: "screenshots look right"), "action-approve"))
        #expect(try same(.message(agent: "codex-b", text: "Use the overload, don't touch session.ts", intent: "steer"), "action-message"))
        #expect(try same(.pause(agent: "codex-b", reason: "wrong approach"), "action-pause"))
        #expect(try same(.undo(seq: 31, reason: "error spike after landing"), "action-undo"))
    }
}

@Suite struct WeftResumeTests {
    @Test func ingestDeduplicatesBySeqAndTracksHighWater() {
        var log = WeftLog()
        let first = log.ingest((1...5).map { WeftFixture.record(seq: $0) })
        #expect(first.count == 5 && log.resumePoint("r") == 5)
        // Replay after reconnect overlaps live by design (spec §9.4).
        let again = log.ingest((4...7).map { WeftFixture.record(seq: $0) })
        #expect(again.map(\.seq) == [6, 7])
        #expect(log.combined.count == 7 && log.resumePoint("r") == 7)
        #expect(log.ingest([WeftFixture.record(seq: 7)]).isEmpty)
    }

    @Test func detailCopyReplacesListCopyWithoutCountingAsNew() {
        var log = WeftLog(events: [WeftFixture.record(seq: 3)])
        let added = log.ingest([WeftFixture.record(seq: 3, diff: "+x")])
        #expect(added.isEmpty)
        #expect(log.event(WeftEventID(repo: "r", seq: 3))?.diff == "+x")
    }

    @Test func highWaterIsPerRepo() {
        var log = WeftLog()
        log.ingest([WeftFixture.record(seq: 9, repo: "a"), WeftFixture.record(seq: 2, repo: "b")])
        #expect(log.resumePoint("a") == 9 && log.resumePoint("b") == 2 && log.resumePoint("c") == 0)
    }

    @Test func trimsToCacheSizeButKeepsHighWater() {
        var log = WeftLog()
        log.ingest((1...(WeftLog.perRepoLimit + 40)).map { WeftFixture.record(seq: $0) })
        #expect(log.events(repo: "r").count == WeftLog.perRepoLimit)
        #expect(log.oldestSeq("r") == 41 && log.resumePoint("r") == WeftLog.perRepoLimit + 40)
    }

    @Test func catchUpPlan() {
        #expect(WeftLog.catchUpPlan(highWater: 0, head: 20) == .tail)          // first open
        #expect(WeftLog.catchUpPlan(highWater: 18, head: 20) == .after(18))    // foreground resume
        #expect(WeftLog.catchUpPlan(highWater: 20, head: 20) == .after(20))    // nothing missed
        #expect(WeftLog.catchUpPlan(highWater: 10, head: 10 + WeftLog.perRepoLimit + 1) == .tail)  // gone for ages
    }

    @Test func resetDropsRepoForAContiguousWindow() {
        var log = WeftLog(events: [WeftFixture.record(seq: 4, repo: "a"), WeftFixture.record(seq: 4, repo: "b")])
        log.reset(repo: "a")
        #expect(log.resumePoint("a") == 0 && log.repos == ["b"] && log.combined.count == 1)
    }

    @Test func combinedOrderIsNewestFirstAcrossRepos() {
        let log = WeftLog(events: [
            WeftFixture.record(seq: 1, repo: "a", ts: "2026-10-05T14:00:01.000Z"),
            WeftFixture.record(seq: 7, repo: "b", ts: "2026-10-05T14:00:02.000Z"),
            WeftFixture.record(seq: 2, repo: "a", ts: "2026-10-05T14:00:03.500Z"),
        ])
        #expect(log.combined.map(\.id.description) == ["a#2", "b#7", "a#1"])
    }
}

@Suite struct WeftDerivedViewTests {
    static let diag = #"[{"severity":"warning","code":"stale_read","file":"f.ts","symbol":"f.ts#g","message":"m","caused_by_seq":1,"caused_by_agent":"x"}]"#

    @Test func filters() {
        let log = WeftLog(events: [
            WeftFixture.record(seq: 1, kind: "intent", agent: "a", task: "T-1"),
            WeftFixture.record(seq: 2, kind: "edit", agent: "b", task: "T-2", diagnostics: Self.diag),
            WeftFixture.record(seq: 3, kind: "edit", agent: "b", status: "rejected", task: "T-2"),
            WeftFixture.record(seq: 4, kind: "negotiate.propose", agent: "a", task: "T-1"),
            WeftFixture.record(seq: 5, repo: "other", kind: "land", agent: "a"),
        ])
        #expect(log.filtered(WeftFilter(onlyConflicts: true)).map(\.seq) == [3, 2])
        #expect(log.filtered(WeftFilter(kinds: [.negotiate])).map(\.seq) == [4])
        #expect(log.filtered(WeftFilter(agents: ["a"], kinds: [.intent, .land])).map(\.seq) == [5, 1])
        #expect(log.filtered(WeftFilter(repos: ["other"])).map(\.seq) == [5])
        #expect(log.filtered(WeftFilter(tasks: ["T-2"], onlyConflicts: true)).count == 2)
        #expect(log.agents == ["a", "b"] && log.tasks == ["T-1", "T-2"])
        #expect(WeftFilter(agents: ["a"], onlyConflicts: true).count == 2)
    }

    @Test func negotiationThreadFollowsReplyTo() {
        let log = WeftLog(events: [
            WeftFixture.record(seq: 10, kind: "negotiate.propose", agent: "b", payload: #"{"to":{"agent":"a"},"keys":["f#g"],"terms":{"kind":"overload","text":"x"}}"#),
            WeftFixture.record(seq: 11, kind: "edit"),
            WeftFixture.record(seq: 12, kind: "negotiate.counter", agent: "a", payload: #"{"reply_to":10,"terms":{"kind":"sequence","text":"y"}}"#),
            WeftFixture.record(seq: 13, kind: "negotiate.accept", agent: "b", payload: #"{"reply_to":12}"#),
            WeftFixture.record(seq: 14, kind: "negotiate.reject", agent: "c", payload: #"{"reply_to":99}"#),
        ])
        let fromAccept = log.thread(for: log.event(WeftEventID(repo: "r", seq: 13))!)
        #expect(fromAccept.map(\.seq) == [10, 12, 13])
        #expect(log.thread(for: log.event(WeftEventID(repo: "r", seq: 10))!).map(\.seq) == [10, 12, 13])
        #expect(log.thread(for: log.event(WeftEventID(repo: "r", seq: 11))!).isEmpty)
    }

    @Test func candidatesApprovalLandRevertAndPause() {
        let log = WeftLog(events: [
            WeftFixture.record(seq: 1, agent: "a", task: "T-1", change: "Ia"),
            WeftFixture.record(seq: 2, agent: "c", task: "T-1", change: "Ic"),
            WeftFixture.record(seq: 3, kind: "control", agent: "john", payload: #"{"action":"approve","target":{"change":"Ia"}}"#),
            WeftFixture.record(seq: 4, kind: "land", agent: "a", task: "T-1", change: "Ia", payload: #"{"sha":"s","op_id":"o"}"#),
            WeftFixture.record(seq: 5, kind: "revert", agent: "a", payload: #"{"op_id":"o2","reverts_seq":4,"reason":"boom"}"#),
            WeftFixture.record(seq: 6, kind: "control", agent: "john", payload: #"{"action":"pause","target":{"agent":"c"}}"#),
        ])
        let c = log.candidates(task: "T-1", repo: "r")
        #expect(c.map(\.change) == ["Ia", "Ic"])
        #expect(c[0].approved && c[0].landedSeq == 4 && c[0].reverted)
        #expect(!c[1].approved && c[1].landedSeq == nil)
        #expect(log.revert(of: log.event(WeftEventID(repo: "r", seq: 4))!)?.seq == 5)
        #expect(log.isPaused(agent: "c", repo: "r") && !log.isPaused(agent: "a", repo: "r"))
        let resumed = WeftLog(events: log.combined + [WeftFixture.record(seq: 7, kind: "control", agent: "john", payload: #"{"action":"resume","target":{"agent":"c"}}"#)])
        #expect(!resumed.isPaused(agent: "c", repo: "r"))
    }

    @Test func diffParserNumbersLines() {
        let lines = DiffParser.parse("diff --git a/src/x.ts b/src/x.ts\n--- a/src/x.ts\n+++ b/src/x.ts\n@@ -10,3 +10,4 @@\n ctx\n-old\n+new\n+more\n")
        #expect(lines.map(\.kind) == [.fileHeader, .hunk, .context, .removed, .added, .added])
        #expect(lines[0].text == "src/x.ts")
        #expect(lines[2].oldNumber == 10 && lines[2].newNumber == 10)
        #expect(lines[3].oldNumber == 11 && lines[4].newNumber == 11 && lines[5].newNumber == 12)
    }

    @Test func summaryDropsRepeatedActorName() {
        let e = WeftFixture.record(seq: 1, agent: "claude-a")
        #expect(WeftFormat.summary(e) == "Did edit #1")
    }

    @Test func streamURLUsesWebSocketSchemeAndNoToken() {
        let c = WeftClient(config: WeftConfig(baseURL: URL(string: "https://weft.example.dev")!, token: "secret"))
        let u = c.streamURL(repo: "weft-demo", after: 42)?.absoluteString
        #expect(u == "wss://weft.example.dev/v1/repos/weft-demo/stream?after=42")
        #expect(WeftClient.normalizedURL("weft.example.dev/v1/")?.absoluteString == "https://weft.example.dev")
    }
}

extension ISO8601DateFormatter {
    static var withFraction: ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }
}
