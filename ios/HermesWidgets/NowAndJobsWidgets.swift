import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Hermes Now: what Hermes is doing, or its latest answer

struct NowEntry: TimelineEntry {
    let date: Date
    let status: LiveStatus
    let latest: Latest?
    let connected: Bool

    struct Latest: Codable, Sendable {
        let sessionID: String
        let title: String
        let answer: String
        let at: Date?
    }
}

private final class Once<T>: @unchecked Sendable {
    let call: (T) -> Void
    init(_ c: @escaping (T) -> Void) { call = c }
}

struct NowProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowEntry {
        NowEntry(date: .now, status: .idle,
                 latest: .init(sessionID: "", title: "Weekend in Porto",
                               answer: "Start at the Ribeira, cross the Dom Luís bridge at sunset, and book Cantinho do Avillez for Saturday.",
                               at: .now.addingTimeInterval(-1800)),
                 connected: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        completion(NowEntry(date: .now, status: SharedVault.status().current(), latest: Self.cachedLatest(),
                            connected: SharedVault.relay() != nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
        let done = Once(completion)
        Task {
            let status = SharedVault.status()
            var latest = Self.cachedLatest()
            if let fresh = await Self.fetchLatest() {
                latest = fresh
                SharedVault.writeData("nowLatest", try? JSONEncoder().encode(fresh))
            }
            let connected = SharedVault.relay() != nil
            // Now, then the moment a finished/stale status falls back to the latest answer.
            var dates = [Date.now]
            dates += [status.updatedAt.addingTimeInterval(2 * 3600 + 5), status.updatedAt.addingTimeInterval(45 * 60 + 5)]
                .filter { $0 > .now }
            let entries = dates.sorted().map { NowEntry(date: $0, status: status.current(at: $0), latest: latest, connected: connected) }
            let refresh: TimeInterval = status.current().state == .working ? 5 * 60 : 20 * 60
            done.call(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(refresh))))
        }
    }

    static func cachedLatest() -> NowEntry.Latest? {
        SharedVault.readData("nowLatest").flatMap { try? JSONDecoder().decode(NowEntry.Latest.self, from: $0) }
    }

    static func fetchLatest() async -> NowEntry.Latest? {
        guard let relay = SharedVault.relay(), let gateway = SharedVault.gateway() else { return nil }
        let lite = HermesLite(gateway: gateway, relay: relay.relay, apiKey: relay.apiKey, timeout: 20)
        guard let chats = try? await lite.recentChats(limit: 6) else { return nil }
        // The newest chat with an answer (skip automation runs: those land in Telegram etc.).
        for chat in chats.filter({ !($0.source ?? "").hasPrefix("cron") }).prefix(3) {
            if let ex = try? await lite.lastExchange(sessionID: chat.id), let answer = ex.answer {
                return .init(sessionID: chat.id, title: chat.title, answer: WatchSnippet.plain(answer),
                             at: chat.lastActive.map { Date(timeIntervalSince1970: $0) })
            }
        }
        return nil
    }
}

struct HermesNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HermesWidgetKinds.now, provider: NowProvider()) { entry in
            HermesNowView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.url)
        }
        .configurationDisplayName("Otto Now")
        .description("What your agent is working on, or the start of its latest answer.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

extension NowEntry {
    var showsStatus: Bool { status.state != .idle }
    var sessionID: String? { showsStatus ? status.sessionID : latest?.sessionID }
    var url: URL {
        guard let id = sessionID, !id.isEmpty else { return LaunchAction.newChat.url }
        return URL(string: "hermes://open?session=\(id)")!
    }
}

struct HermesNowView: View {
    let entry: NowEntry
    var forcedFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { forcedFamily ?? envFamily }
    private var s: LiveStatus { entry.status }

    var body: some View {
        switch family {
        case .accessoryInline:
            if entry.showsStatus { Label("Otto · \(s.state == .working ? s.line : heading)", systemImage: symbol) }
            else { Label(entry.latest.map { "Otto · \($0.title)" } ?? "Otto · Ready", systemImage: "bubble.left") }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.showsStatus ? symbol : "bubble.left.fill").font(.title3.weight(.semibold))
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                if entry.showsStatus {
                    HStack(spacing: 4) {
                        Image(systemName: symbol)
                        Text(heading).font(.headline).lineLimit(1)
                        if s.state == .working, let start = s.startedAt {
                            Text(start, style: .timer).font(.caption2.monospacedDigit()).frame(maxWidth: 40, alignment: .trailing)
                        }
                    }
                    Text(s.line).font(.caption).lineLimit(2)
                } else if let l = entry.latest {
                    Text(l.title).font(.headline).lineLimit(1)
                    Text(l.answer).font(.caption).lineLimit(2)
                } else {
                    Text("Otto").font(.headline)
                    Text(entry.connected ? "Ready" : "Open Otto to connect").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            home
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image("OttoMark").resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 16, height: 16).foregroundStyle(.secondary)
                if entry.showsStatus {
                    Text(heading).font(.caption.weight(.semibold)).foregroundStyle(color)
                } else {
                    Text(latestLabel)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.showsStatus, s.state == .working, let start = s.startedAt {
                    Text(start, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 48, alignment: .trailing)
                }
            }
            if entry.showsStatus {
                if let t = s.title { Text(t).font(.subheadline.weight(.semibold)).lineLimit(1) }
                Text(s.line).font(family == .systemSmall ? .caption : .subheadline)
                    .lineLimit(family == .systemSmall ? 4 : 3)
                    .foregroundStyle(s.state == .done ? .primary : .secondary)
            } else if let l = entry.latest {
                Text(l.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(l.answer).font(family == .systemSmall ? .caption : .subheadline)
                    .lineLimit(family == .systemSmall ? 5 : 3).foregroundStyle(.secondary)
            } else {
                Text(entry.connected ? "Ask Otto something and its answer shows up here." : "Open Otto to connect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var latestLabel: String {
        guard let at = entry.latest?.at else { return "Latest" }
        let rel = at.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        return family == .systemSmall ? rel : "Latest · \(rel)"
    }

    private var heading: String {
        switch s.state {
        case .idle: "Ready"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Didn't finish"
        }
    }

    private var symbol: String {
        switch s.state {
        case .idle: "circle"
        case .working: "ellipsis.circle.fill"
        case .needsYou: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch s.state {
        case .needsYou: .orange
        case .done: .green
        case .failed: .red
        default: .primary
        }
    }
}

// MARK: - Jobs: next scheduled jobs, last result, Run button

struct JobsEntry: TimelineEntry {
    let date: Date
    let jobs: [JobLite]
    let kicks: [JobKick]
    let connected: Bool

    func running(_ job: JobLite) -> Bool { kicks.contains { $0.jobID == job.id && !$0.finished(in: job) } }
}

struct JobsProvider: TimelineProvider {
    func placeholder(in context: Context) -> JobsEntry { JobsEntry(date: .now, jobs: JobLite.samples, kicks: [], connected: true) }

    func getSnapshot(in context: Context, completion: @escaping (JobsEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let jobs = SharedVault.jobs()
        completion(JobsEntry(date: .now, jobs: jobs.isEmpty ? JobLite.samples : JobsAPI.ordered(jobs),
                             kicks: SharedVault.kicks(), connected: SharedVault.relay() != nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JobsEntry>) -> Void) {
        let done = Once(completion)
        Task {
            var jobs = SharedVault.jobs()
            if let r = SharedVault.relay(), let fresh = try? await JobsAPI.list(relay: r.relay, apiKey: r.apiKey, timeout: 20) {
                jobs = fresh
                SharedVault.saveJobs(fresh)
            }
            // Drop kicks whose run has finished.
            var kicks = SharedVault.kicks()
            kicks = kicks.filter { k in jobs.first { $0.id == k.jobID }.map { !k.finished(in: $0) } ?? false }
            SharedVault.saveKicks(kicks)
            let entry = JobsEntry(date: .now, jobs: JobsAPI.ordered(jobs), kicks: kicks, connected: SharedVault.relay() != nil)
            // Something running: check back soon. Otherwise refresh after the next scheduled run.
            let next = jobs.compactMap(\.nextRun).filter { $0 > .now }.min()
            let after: Date = !kicks.isEmpty ? .now.addingTimeInterval(60)
                : min(next?.addingTimeInterval(120) ?? .distantFuture, .now.addingTimeInterval(30 * 60))
            done.call(Timeline(entries: [entry], policy: .after(after)))
        }
    }
}

struct HermesJobsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HermesWidgetKinds.jobs, provider: JobsProvider()) { entry in
            JobsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "hermes://automations"))
        }
        .configurationDisplayName("Otto Jobs")
        .description("Your scheduled jobs: what's next, how the last run went, and a button to run one now.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct JobsWidgetView: View {
    let entry: JobsEntry
    var forcedFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { forcedFamily ?? envFamily }

    private var shown: [JobLite] {
        Array(entry.jobs.prefix(family == .systemSmall ? 1 : family == .systemMedium ? 3 : 7))
    }

    var body: some View {
        if entry.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Jobs", systemImage: "clock.arrow.circlepath").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(entry.connected ? "No scheduled jobs yet." : "Open Otto to connect.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if family == .systemSmall, let job = shown.first {
            small(job)
        } else {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
                Label("Jobs", systemImage: "clock.arrow.circlepath").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(shown) { row($0) }
                Spacer(minLength: 0)
            }
        }
    }

    private func small(_ job: JobLite) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Next job", systemImage: "clock.arrow.circlepath").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(subtitle(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Button(intent: RunJobIntent(jobID: job.id)) {
                Label(entry.running(job) ? "Running…" : "Run now", systemImage: entry.running(job) ? "hourglass" : "play.fill")
                    .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .disabled(entry.running(job))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ job: JobLite) -> some View {
        HStack(spacing: 8) {
            Circle().fill(dot(job)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(subtitle(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(intent: RunJobIntent(jobID: job.id)) {
                Image(systemName: entry.running(job) ? "hourglass" : "play.fill").font(.caption2.weight(.bold))
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .disabled(entry.running(job))
            .accessibilityLabel("Run \(job.title) now")
        }
    }

    private func subtitle(_ job: JobLite) -> String {
        if entry.running(job) { return "Running · output to \(job.deliveryLabel)" }
        if job.isPaused { return "Paused" }
        var parts: [String] = []
        if let n = job.nextRun { parts.append("Next " + Self.when(n)) }
        if job.lastFailed { parts.append("last run failed") }
        else if let l = job.lastRun { parts.append("ran " + Self.when(l)) }
        return parts.joined(separator: " · ")
    }

    private func dot(_ job: JobLite) -> Color {
        if entry.running(job) { return .blue }
        if job.isPaused { return .gray }
        return job.lastFailed ? .red : .green
    }

    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return time }
        if cal.isDateInTomorrow(d) { return "tomorrow \(time)" }
        if cal.isDateInYesterday(d) { return "yesterday \(time)" }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The widget's Run button. Starts the job on the Mac; output goes wherever the job delivers it.
struct RunJobIntent: AppIntent {
    static var title: LocalizedStringResource { "Run Agent Job" }
    static var description: IntentDescription { IntentDescription("Runs one of your agent's scheduled jobs now.") }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Job ID") var jobID: String

    init() {}
    init(jobID: String) { self.jobID = jobID }

    func perform() async throws -> some IntentResult {
        guard let r = SharedVault.relay() else { return .result() }
        var job = SharedVault.jobs().first { $0.id == jobID }
        if job == nil { job = try? await JobsAPI.list(relay: r.relay, apiKey: r.apiKey).first { $0.id == jobID } }
        guard let job else { return .result() }
        try await JobsAPI.run(job, relay: r.relay, apiKey: r.apiKey)
        SharedVault.addKick(job)
        WidgetCenter.shared.reloadTimelines(ofKind: HermesWidgetKinds.jobs)
        return .result()
    }
}

extension JobLite {
    static let samples: [JobLite] = [
        JobLite(id: "a", name: "Daily briefing", profile: nil, state: "scheduled", scheduleDisplay: "0 7 * * *",
                nextRunAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(9 * 3600)),
                lastRunAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-15 * 3600)),
                lastStatus: "ok", lastError: nil, deliver: "telegram", enabled: true, noAgent: false),
        JobLite(id: "b", name: "Inbox sweep", profile: nil, state: "scheduled", scheduleDisplay: "every 2h",
                nextRunAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(3600)),
                lastRunAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-3600)),
                lastStatus: "ok", lastError: nil, deliver: "telegram", enabled: true, noAgent: false),
        JobLite(id: "c", name: "Weekly money check-in", profile: nil, state: "scheduled", scheduleDisplay: "30 8 * * 1",
                nextRunAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(3 * 86400)),
                lastRunAt: nil, lastStatus: nil, lastError: nil, deliver: "telegram", enabled: true, noAgent: false),
    ]
}
