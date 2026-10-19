import Foundation

// MARK: - Card times that tick live
//
// "The running Weft card showed '3 seconds ago' and stayed frozen." `Text(d, format: .relative)`
// formats once per render, so the label only moved when the 5 s board poll happened to re-render,
// and it showed the creation date for running cards. `CardTime` picks the date that matters for
// the card's status and formats it against a given `now`; `LiveCardTime` (Views/LiveTime.swift)
// re-renders it on a schedule (every second for the first minute, then every 15 s).

enum CardTime: Equatable {
    /// Working now: elapsed time since the current run started.
    case running(since: Date, heartbeat: Date?)
    /// Finished: when it completed.
    case done(Date)
    /// Anything else (triage, todo, ready, blocked, review…): when it was created.
    case created(Date)

    static func of(_ task: KanbanTask) -> CardTime? {
        func date(_ t: Double?) -> Date? { t.map { Date(timeIntervalSince1970: $0) } }
        switch task.status {
        case "running":
            guard let since = date(task.currentRunStartedAt ?? task.startedAt) ?? date(task.createdAt) else { return nil }
            return .running(since: since, heartbeat: date(task.lastHeartbeatAt))
        case "done":
            return (date(task.completedAt) ?? date(task.createdAt)).map(CardTime.done)
        default:
            return date(task.createdAt).map(CardTime.created)
        }
    }

    var anchor: Date {
        switch self {
        case .running(let d, _), .done(let d), .created(let d): d
        }
    }

    /// Primary label: "running 42s", "running 12m", "running 1h 5m"; otherwise "3 min. ago" style.
    func label(now: Date) -> String {
        switch self {
        case .running(let since, _):
            return "running " + Self.elapsed(now.timeIntervalSince(since))
        case .done(let d), .created(let d):
            return Self.relative(d, now: now)
        }
    }

    /// Secondary label for running cards: how long ago the worker last checked in.
    func heartbeatLabel(now: Date) -> String? {
        guard case .running(_, let hb?) = self else { return nil }
        return "beat " + Self.elapsed(now.timeIntervalSince(hb)) + " ago"
    }

    /// Compact elapsed time: 0s…59s, 1m…59m, 1h 5m, 2d 3h.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        let d = h / 24
        return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h"
    }

    static func relative(_ date: Date, now: Date) -> String {
        // Under a minute, count seconds ourselves ("12s ago"); the system formatter says "now"/"in 0 sec".
        let s = now.timeIntervalSince(date)
        if s >= 0 && s < 60 { return "\(Int(s))s ago" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: now)
    }

    /// When the label should next change: every second for its first minute, then every 15 s.
    static func nextTick(after date: Date, anchor: Date) -> Date {
        let age = date.timeIntervalSince(anchor)
        return date.addingTimeInterval(age < 60 ? 1 : 15)
    }
}
