import Foundation
import Testing
@testable import Hermes

struct WeftPerformanceTests {
    private func event(_ repo: String, _ seq: Int, _ ts: String) throws -> WeftEvent {
        let json = """
        {"seq":\(seq),"repo":"\(repo)","kind":"edit","ts":"\(ts)","actor":{"type":"agent","id":"a\(seq % 7)"},
         "agent":"a\(seq % 7)","task":"T-\(seq % 13)","x_task_title":"Task \(seq % 13)","summary":"s"}
        """
        return try JSONDecoder().decode(WeftEvent.self, from: Data(json.utf8))
    }

    @Test func fastParserMatchesFormatter() {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let p = ISO8601DateFormatter()
        for s in ["2026-10-04T03:54:21.005Z", "2026-10-05T14:03:11.204Z", "2026-01-31T23:59:59.999Z", "2024-02-29T00:00:00.000Z"] {
            #expect(WeftTime.parse(s) == f.date(from: s), "\(s)")
        }
        for s in ["2026-10-05T14:00:00Z", "2026-10-04T07:00:00-03:00", "2026-10-04T07:00:00+05:30", "1999-12-31T23:59:59Z"] {
            #expect(WeftTime.parse(s) == p.date(from: s), "\(s)")
        }
        #expect(WeftTime.parse("garbage") == nil)
    }

    /// Ten repos × 500 cached records (the cache maximum), then live arrivals: must stay far under a frame budget.
    @Test func bigLogStaysFast() throws {
        var events: [WeftEvent] = []
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for r in 0..<10 { for s in 1...500 {
            events.append(try event("repo\(r)", s, f.string(from: base.addingTimeInterval(Double(s * 37 + r)))))
        } }
        let t0 = Date()
        var log = WeftLog(events: events)
        let build = Date().timeIntervalSince(t0)
        #expect(log.combined.count == 5000)
        #expect(build < 0.5, "build took \(build)s")
        let t1 = Date()
        for s in 501...560 { log.ingest([try event("repo3", s, f.string(from: base.addingTimeInterval(Double(s * 37))))]) }
        let live = Date().timeIntervalSince(t1)
        #expect(live < 0.2, "60 live inserts took \(live)s")
        #expect(log.combined.count == 5000)   // trimmed back to 500 per repo
        #expect(log.combined == WeftLog(events: log.combined).combined)
        #expect(zip(log.combined, log.combined.dropFirst()).allSatisfy { !WeftLog.newestFirst($1, $0) })
        let t2 = Date()
        for e in log.combined.prefix(200) { _ = e.task.flatMap(log.taskTitle) }
        #expect(Date().timeIntervalSince(t2) < 0.01)
        #expect(log.taskTitle("T-3") == "Task 3")
    }
}
