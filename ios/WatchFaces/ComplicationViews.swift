import SwiftUI
import WidgetKit

// Complication faces, shared by the watch widget extension and (for previews) the watch app.

struct LimitsEntry: TimelineEntry {
    let date: Date
    let snapshot: LimitsSnapshot?
}

struct LiveEntry: TimelineEntry {
    let date: Date
    let status: LiveStatus
}

struct LimitsRingView: View {
    let entry: LimitsEntry
    var forcedFamily: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { forcedFamily ?? envFamily }

    private var providers: [LimitProvider] { entry.snapshot?.orderedProviders ?? [] }

    var body: some View {
        switch family {
        case .accessoryCorner:
            // Claude's number on the face, Claude's gauge along the curve, both in the label.
            let first = providers.first?.worst(at: entry.date)
            Text(first.map { "\(Int($0.percent.rounded()))%" } ?? "--")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: (first?.percent ?? 0) / 100) {
                        Text(limitsInlineText(entry.snapshot, at: entry.date))
                    }
                    .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
                }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(providers.prefix(2)) { p in
                    if let w = p.worst(at: entry.date) {
                        HStack(spacing: 4) {
                            Text(p.name).font(.caption2.weight(.semibold))
                            Spacer(minLength: 2)
                            Text("\(Int(w.percent.rounded()))% \(w.window.label.lowercased())").font(.caption2.monospacedDigit())
                        }
                        Gauge(value: w.percent / 100) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(w.window.pace(at: entry.date).ringColor)
                    }
                }
                if providers.isEmpty { Text("AI limits · open Otto").font(.caption2) }
            }
        case .accessoryInline:
            Text(limitsInlineText(entry.snapshot, at: entry.date))
        default:
            ZStack {
                AccessoryWidgetBackground()
                DualLimitRing(snapshot: entry.snapshot, date: entry.date).padding(2)
            }
        }
    }
}

extension LimitLevel {
    var watchTint: Color {
        switch self {
        case .fine: .green
        case .getting: .orange
        case .high, .out: .red
        }
    }
}

struct LiveLineView: View {
    let entry: LiveEntry
    var forcedFamily: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { forcedFamily ?? envFamily }
    private var s: LiveStatus { entry.status }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(inlineText, systemImage: symbol)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(color)
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(heading).font(.headline).lineLimit(1)
                    Spacer(minLength: 0)
                    if s.state == .working, let start = s.startedAt {
                        Text(start, style: .timer).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(maxWidth: 44, alignment: .trailing)
                    }
                }
                Text(s.line).font(.caption).lineLimit(2)
                if let title = s.title, s.state != .idle {
                    Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var heading: String {
        switch s.state {
        case .idle: "Otto"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Didn't finish"
        }
    }

    private var inlineText: String {
        switch s.state {
        case .idle: "Otto · Ready"
        case .working: "Otto · \(s.line)"
        case .needsYou: "Otto needs you"
        case .done: "Otto · Done"
        case .failed: "Otto · Didn't finish"
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
        case .idle: .secondary
        case .working: .white
        case .needsYou: .orange
        case .done: .green
        case .failed: .red
        }
    }
}

extension LimitsSnapshot {
    static let sample = LimitsSnapshot(providers: [
        LimitProvider(id: "claude", name: "Claude", plan: "Max 5x", source: nil, windows: [
            LimitWindow(id: "primary", label: "5-hour", windowMinutes: 300, usedPercent: 22, resetsAt: nil, resetDescription: nil, pace: nil),
            LimitWindow(id: "secondary", label: "Weekly", windowMinutes: 10080, usedPercent: 72, resetsAt: nil, resetDescription: nil, pace: nil),
        ], credits: nil, status: nil, error: nil, updatedAt: nil),
        LimitProvider(id: "codex", name: "Codex", plan: "Plus", source: nil, windows: [
            LimitWindow(id: "primary", label: "5-hour", windowMinutes: 300, usedPercent: 8, resetsAt: nil, resetDescription: nil, pace: nil),
        ], credits: nil, status: nil, error: nil, updatedAt: nil),
    ], fetchedAt: nil, error: nil, stale: nil)
}
