import SwiftUI

/// Timeline schedule for a time label anchored at `anchor`: a tick every second while it's under a
/// minute old, then every 15 s.
struct LiveTimeSchedule: TimelineSchedule {
    let anchor: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = CardTime.nextTick(after: current, anchor: anchor)
            return current
        }
    }
}

/// A card's time ("running 12m", "3 min. ago"), re-rendered live instead of once per board poll.
struct LiveCardTime: View {
    let time: CardTime
    var showHeartbeat = true

    var body: some View {
        TimelineView(LiveTimeSchedule(anchor: time.anchor)) { ctx in
            HStack(spacing: 4) {
                Text(time.label(now: ctx.date))
                if showHeartbeat, let hb = time.heartbeatLabel(now: ctx.date) {
                    Text("· " + hb).foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
        }
        .help(helpText)
    }

    private var helpText: String {
        let d = time.anchor.formatted(date: .abbreviated, time: .standard)
        switch time {
        case .running: return "Started \(d)"
        case .done: return "Completed \(d)"
        case .created: return "Created \(d)"
        }
    }
}

/// Any plain date as a live "3 min. ago" label (comments etc.).
struct LiveRelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(LiveTimeSchedule(anchor: date)) { ctx in
            Text(CardTime.relative(date, now: ctx.date)).monospacedDigit()
        }
    }
}
