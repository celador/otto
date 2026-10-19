import Foundation
import Testing
@testable import Hermes

/// Message times and day separators (ChatTimeline, Transcript dates, outbox queue time).
struct ChatTimestampTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let enUS = Locale(identifier: "en_US")
    /// 2026-10-17 15:00:00 UTC (a Saturday).
    private let now = Date(timeIntervalSince1970: 1_792_249_200)
    private func ago(days: Double, hours: Double = 0) -> Date {
        now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
    }

    @Test func historyCarriesServerTimestamps() {
        let t = Transcript.fromHistory([
            StoredMessage(id: 1, role: "user", content: "hello", timestamp: 1_792_000_000),
            StoredMessage(id: 2, role: "assistant", content: "hi there", timestamp: 1_792_000_005.5),
            StoredMessage(id: 3, role: "assistant", content: "Operation interrupted by user", timestamp: 1_792_000_009),
            StoredMessage(id: 4, role: "user", content: "no time"),
            StoredMessage(id: 5, role: "assistant", content: "", timestamp: 1_792_000_020),   // not shown
        ])
        #expect(t.date(for: "h1") == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(t.date(for: "h2") == Date(timeIntervalSince1970: 1_792_000_005.5))
        #expect(t.date(for: "h3") == Date(timeIntervalSince1970: 1_792_000_009))   // notice
        #expect(t.date(for: "h4") == nil)
        #expect(t.dates["h5"] == nil)
        #expect(t.dates.count == 3)
    }

    @Test func cacheRoundTripKeepsTimestamp() {
        let m = StoredMessage(id: 7, role: "user", content: "x", timestamp: 1_792_000_000)
        #expect(CachedMessage(m).stored.timestamp == 1_792_000_000)
    }

    @Test func liveRowsAreStampedWhenTheyAppear() {
        var t = Transcript()
        let sent = now.addingTimeInterval(-30)
        t.appendUser("what time is it?", at: sent)
        t.apply(RunEvent(event: "tool.started", seq: 0, tool: "terminal"), runID: "r", now: now)
        t.apply(RunEvent(event: "tool.completed", seq: 1, tool: "terminal"), runID: "r", now: now)
        // First words at `first`; later deltas and completion must not move the stamp.
        let first = now.addingTimeInterval(5)
        t.apply(RunEvent(event: "message.delta", seq: 2, delta: "It is"), runID: "r", now: first)
        t.apply(RunEvent(event: "message.delta", seq: 3, delta: " 3 PM"), runID: "r", now: first.addingTimeInterval(2))
        t.apply(RunEvent(event: "run.completed", seq: 4, output: "It is 3 PM"), runID: "r", now: first.addingTimeInterval(3))
        let ids = t.items.map(\.id)
        #expect(t.date(for: ids[0]) == sent)
        #expect(t.date(for: ids[2]) == first)
        if case .assistant(_, let text, false) = t.items[2] { #expect(text == "It is 3 PM") } else { Issue.record("no reply") }
    }

    @Test func liveEventsPreferTheGatewayTimestamp() {
        var t = Transcript()
        // A replay after reconnecting: the event's own time wins over arrival time.
        t.apply(RunEvent(event: "message.delta", seq: 0, delta: "Hi", timestamp: 1_792_000_000), runID: "r", now: now)
        t.apply(RunEvent(event: "run.failed", seq: 1, isError: true, errorMessage: "down"), runID: "r", now: now)
        #expect(t.date(for: t.items[0].id) == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(t.date(for: t.items[1].id) == now)
    }

    @Test func runEventDecodesTimestamp() throws {
        let json = #"{"event":"message.delta","run_id":"r","seq":3,"delta":"x","timestamp":1792242109.4}"#
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let e = try d.decode(RunEvent.self, from: Data(json.utf8))
        #expect(e.timestamp == 1792242109.4)
    }

    @Test func emptyStreamDropsItsDate() {
        var t = Transcript()
        t.apply(RunEvent(event: "message.delta", seq: 0, delta: "  "), runID: "r", now: now)
        t.apply(RunEvent(event: "message.delta", seq: 1, delta: "x"), runID: "r", now: now)
        t.apply(RunEvent(event: "tool.started", seq: 2, tool: "terminal"), runID: "r", now: now)
        #expect(Set(t.dates.keys) == Set(t.items.map(\.id)))
    }

    @Test func outboxKeepsQueueTime() throws {
        let q = Date(timeIntervalSince1970: 1_792_000_000)
        let m = PendingMessage(id: "p", text: "hi", queuedAt: q)
        let back = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(m))
        #expect(back.queuedAt == q)
        // Outboxes written by older builds have no time.
        let old = try JSONDecoder().decode(PendingMessage.self, from: Data(#"{"id":"o","text":"x","images":[],"isSteer":false}"#.utf8))
        #expect(old.queuedAt == nil)
    }

    @Test func dayStartsMarkFirstMessageAndEachNewDay() {
        let rows: [(id: String, date: Date?)] = [
            ("tool0", nil),
            ("a", ago(days: 3)),
            ("b", ago(days: 3).addingTimeInterval(60)),
            ("tool1", nil),
            ("c", ago(days: 1)),
            ("cmd", nil),
            ("d", now.addingTimeInterval(-60)),
            ("e", now),
        ]
        let starts = ChatTimeline.dayStarts(rows, calendar: utc)
        #expect(Set(starts.keys) == ["a", "c", "d"])
        #expect(starts["a"] == ago(days: 3))
        #expect(ChatTimeline.dayStarts([("x", nil)], calendar: utc).isEmpty)
    }

    @Test func dayStartsFollowTheCalendarsTimeZone() {
        // 23:30 and 00:30 UTC are different days in UTC but the same day in New York.
        let late = Date(timeIntervalSince1970: 1_792_193_400)   // 2026-10-16 23:30 UTC
        let early = late.addingTimeInterval(3_600)              // 2026-10-17 00:30 UTC
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(ChatTimeline.dayStarts([("a", late), ("b", early)], calendar: utc).count == 2)
        #expect(ChatTimeline.dayStarts([("a", late), ("b", early)], calendar: ny).count == 1)
    }

    @Test func dayLabels() {
        func label(_ d: Date) -> String { ChatTimeline.dayLabel(d, now: now, calendar: utc, locale: enUS) }
        #expect(label(now.addingTimeInterval(-3_600)) == "Today")
        #expect(label(ago(days: 1)) == "Yesterday")
        #expect(label(ago(days: 2)) == "Thursday")
        #expect(label(ago(days: 6)) == "Sunday")
        #expect(label(ago(days: 7)) == "Oct 10")
        #expect(label(Date(timeIntervalSince1970: 1_760_000_000)) == "Oct 9, 2025")
    }

    @Test func timeLabelUsesLocaleAndZone() {
        let label = ChatTimeline.timeLabel(now, calendar: utc, locale: enUS)
        #expect(label.replacingOccurrences(of: "\u{202F}", with: " ") == "3:00 PM")
    }
}
