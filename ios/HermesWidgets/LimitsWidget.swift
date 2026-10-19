import SwiftUI
import WidgetKit

// Home Screen + Lock Screen widget: your AI subscription limits (CodexBar on the Mac, via the relay).

struct LimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: LimitsSnapshot?
    let connected: Bool
}

struct LimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry { LimitsEntry(date: .now, snapshot: .preview, connected: true) }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        completion(LimitsEntry(date: .now, snapshot: SharedVault.limits() ?? .preview, connected: SharedVault.relay() != nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        let done = Completion(completion)
        Task {
            let relay = SharedVault.relay()
            var snapshot = SharedVault.limits()
            if let relay, let fresh = try? await LimitsAPI.fetch(relay: relay.relay, apiKey: relay.apiKey, timeout: 25) {
                snapshot = fresh
                SharedVault.saveLimits(fresh)
            }
            let entry = LimitsEntry(date: .now, snapshot: snapshot, connected: relay != nil)
            done.call(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    /// WidgetKit's completion isn't Sendable; it's safe to call once from the fetch task.
    private final class Completion: @unchecked Sendable {
        let call: (Timeline<LimitsEntry>) -> Void
        init(_ c: @escaping (Timeline<LimitsEntry>) -> Void) { call = c }
    }
}

struct HermesLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LimitsWidgetKind.kind, provider: LimitsProvider()) { entry in
            LimitsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "hermes://usage"))
        }
        .configurationDisplayName("AI Limits")
        .description("How much of your Codex and Claude limits you've used, and when they reset.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LimitsWidgetView: View {
    let entry: LimitsEntry
    @Environment(\.widgetFamily) private var family

    private var providers: [LimitProvider] { entry.snapshot?.orderedProviders ?? [] }

    var body: some View {
        if providers.isEmpty {
            empty
        } else {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: medium
            default: small
            }
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(providers.prefix(2)) { p in
                VStack(alignment: .leading, spacing: 5) {
                    Text(p.name).font(.caption.weight(.semibold))
                    ForEach(p.windows.prefix(2)) { w in
                        LimitWindowRow(window: w, showPace: false, compact: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(providers.prefix(2)) { p in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 4) {
                        Text(p.name).font(.subheadline.weight(.semibold))
                        if let plan = p.planLabel { Text(plan).font(.caption2).foregroundStyle(.secondary) }
                        if p.incident != nil {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    ForEach(p.windows.prefix(3)) { w in
                        LimitWindowRow(window: w, showPace: false, compact: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            DualLimitRing(snapshot: entry.snapshot).padding(2)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(providers.prefix(2)) { p in
                if let w = p.worst()?.window {
                    HStack(spacing: 4) {
                        Text(p.name).font(.caption.weight(.semibold))
                        Spacer(minLength: 2)
                        Text("\(Int(w.usedPercent.rounded()))% \(w.label.lowercased())").font(.caption.monospacedDigit())
                    }
                    ProgressView(value: w.fraction)
                }
            }
        }
    }

    private var inline: some View {
        Text(limitsInlineText(entry.snapshot))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.title3)
            Text(entry.connected ? "No limits yet" : "Open Otto once").font(.caption.weight(.semibold))
            if family == .systemSmall || family == .systemMedium {
                Text(entry.connected ? "Turn on providers in CodexBar on your Mac." : "So the widget can reach your Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

extension LimitsSnapshot {
    static let preview = LimitsSnapshot(providers: [
        LimitProvider(id: "claude", name: "Claude", plan: "Max 5x", source: nil, windows: [
            LimitWindow(id: "primary", label: "5-hour", windowMinutes: 300, usedPercent: 22,
                        resetsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(2 * 3600)), resetDescription: nil, pace: nil),
            LimitWindow(id: "secondary", label: "Weekly", windowMinutes: 10080, usedPercent: 72,
                        resetsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(30 * 3600)), resetDescription: nil, pace: nil),
        ], credits: nil, status: nil, error: nil, updatedAt: nil),
        LimitProvider(id: "codex", name: "Codex", plan: "Plus", source: nil, windows: [
            LimitWindow(id: "primary", label: "5-hour", windowMinutes: 300, usedPercent: 8,
                        resetsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(4 * 3600)), resetDescription: nil, pace: nil),
            LimitWindow(id: "secondary", label: "Weekly", windowMinutes: 10080, usedPercent: 31,
                        resetsAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(5 * 86400)), resetDescription: nil, pace: nil),
        ], credits: nil, status: nil, error: nil, updatedAt: nil),
    ], fetchedAt: nil, error: nil, stale: nil)
}
