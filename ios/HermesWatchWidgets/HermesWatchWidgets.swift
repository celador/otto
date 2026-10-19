import SwiftUI
import WidgetKit

// Watch face complications: AI limits ring, Hermes live line, and a one-tap mic.
// Data comes from the watch app (its own runs, plus what the iPhone pushes) via the shared keychain.

@main
struct HermesWatchWidgets: WidgetBundle {
    var body: some Widget {
        LimitsRingWidget()
        LiveLineWidget()
        TalkWidget()
    }
}

// MARK: - AI limits ring

struct LimitsTimeline: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry { LimitsEntry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        completion(LimitsEntry(date: .now, snapshot: context.isPreview ? .sample : SharedVault.limits() ?? .sample))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        let snap = SharedVault.limits()
        // Redraw at each reset (the window empties) and hourly so countdowns stay honest.
        var dates = [Date.now] + (snap?.resetDates.prefix(6) ?? [])
        dates += (1...6).map { Date.now.addingTimeInterval(Double($0) * 3600) }
        let entries = Array(Set(dates)).sorted().map { LimitsEntry(date: $0, snapshot: snap) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct LimitsRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.elier.hermes.watch.limits", provider: LimitsTimeline()) { entry in
            LimitsRingView(entry: entry, forcedFamily: nil)
                .containerBackground(.clear, for: .widget)
                .widgetURL(URL(string: "hermes://limits"))
        }
        .configurationDisplayName("AI Limits")
        .description("Claude and Codex limits: Claude on the outer ring and in the middle, Codex on the inner ring.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Live line

struct LiveTimeline: TimelineProvider {
    func placeholder(in context: Context) -> LiveEntry {
        LiveEntry(date: .now, status: LiveStatus(state: .working, line: "Searching the web", title: "Trip to Porto",
                                                 sessionID: nil, steps: 3, startedAt: .now.addingTimeInterval(-90), updatedAt: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (LiveEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : LiveEntry(date: .now, status: SharedVault.status().current()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveEntry>) -> Void) {
        let s = SharedVault.status()
        // Now, plus the moments a done/stale status should fall back to "Ready".
        let later = [s.updatedAt.addingTimeInterval(2 * 3600 + 5), s.updatedAt.addingTimeInterval(45 * 60 + 5)].filter { $0 > .now }
        let entries = ([Date.now] + later).map { LiveEntry(date: $0, status: s.current(at: $0)) }
        completion(Timeline(entries: entries, policy: .never))   // the app reloads us when something changes
    }
}

struct LiveLineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.elier.hermes.watch.live", provider: LiveTimeline()) { entry in
            LiveLineView(entry: entry, forcedFamily: nil)
                .containerBackground(.clear, for: .widget)
                .widgetURL(entry.status.sessionID.map { URL(string: "hermes://chat?session=\($0)")! } ?? URL(string: "hermes://talk"))
        }
        .configurationDisplayName("Otto Now")
        .description("What your agent is doing: working, needs you, or done with the first line of the answer.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: - Talk

struct TalkEntry: TimelineEntry { let date: Date }

struct TalkTimeline: TimelineProvider {
    func placeholder(in context: Context) -> TalkEntry { TalkEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (TalkEntry) -> Void) { completion(TalkEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TalkEntry>) -> Void) {
        completion(Timeline(entries: [TalkEntry(date: .now)], policy: .never))
    }
}

struct TalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ai.elier.hermes.watch.talk", provider: TalkTimeline()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title3.weight(.semibold))
            }
            .containerBackground(.clear, for: .widget)
            .widgetURL(URL(string: "hermes://talk"))
        }
        .configurationDisplayName("Talk to Otto")
        .description("One tap from the watch face to talking.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

