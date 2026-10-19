import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

extension LimitsSnapshot {
    /// Claude first (John's main plan), then Codex, then anything else.
    var orderedProviders: [LimitProvider] {
        let rank = ["claude": 0, "codex": 1]
        return providers.filter { !$0.windows.isEmpty }
            .sorted { (rank[$0.id] ?? 9, $0.name) < (rank[$1.id] ?? 9, $1.name) }
    }
}

extension LimitProvider {
    /// The window closest to running out (a window past its reset counts as empty).
    func worst(at date: Date = .now) -> (window: LimitWindow, percent: Double)? {
        windows.map { ($0, $0.effectivePercent(at: date)) }.max { $0.1 < $1.1 }
    }

    var shortName: String {
        switch id {
        case "claude": "CL"
        case "codex": "CX"
        default: String(name.prefix(2)).uppercased()
        }
    }
}

/// How fast a window is being used compared with how much of it has gone by.
enum LimitPace: Int, Comparable, Sendable {
    case under, onPace, ahead, farAhead, out

    static func < (a: LimitPace, b: LimitPace) -> Bool { a.rawValue < b.rawValue }

    var ringColor: Color {
        switch self {
        case .under, .onPace: .green
        case .ahead: .yellow
        case .farAhead: .orange
        case .out: .red
        }
    }
}

extension LimitWindow {
    /// Percent of this window that has elapsed at `date` (nil when the window length or reset is unknown).
    func elapsedPercent(at date: Date) -> Double? {
        guard let reset = resetDate, let minutes = windowMinutes, minutes > 0 else { return nil }
        if reset <= date { return 0 }  // reset passed: a fresh, empty window
        let left = reset.timeIntervalSince(date) / (minutes * 60)
        return min(100, max(0, (1 - left) * 100))
    }

    /// Used vs. elapsed: green when you're at or under pace, yellow up to 10 points ahead of the clock,
    /// orange up to 25 ahead, red beyond that or when the window is used up.
    func pace(at date: Date) -> LimitPace {
        let used = effectivePercent(at: date)
        if used >= 99.5 { return .out }
        guard let expected = elapsedPercent(at: date) ?? pace?.expectedUsedPercent else {
            switch LimitLevel(used) {  // no timing info: fall back to how full it is
            case .fine: return .onPace
            case .getting: return .ahead
            case .high: return .farAhead
            case .out: return .out
            }
        }
        let over = used - max(expected, 5)  // the first few % of a window don't count as "ahead"
        switch over {
        case ..<(-3): return .under
        case ..<3: return .onPace
        case ..<10: return .ahead
        case ..<25: return .farAhead
        default: return .out
        }
    }
}

/// Two concentric rings for a round complication: outer = first provider (Claude), inner = second (Codex),
/// the first provider's percent in the middle.
struct DualLimitRing: View {
    let snapshot: LimitsSnapshot?
    var date: Date = .now

    var body: some View {
        let ps = snapshot?.orderedProviders ?? []
        let outer = ps.first?.worst(at: date)
        let inner = ps.dropFirst().first?.worst(at: date)
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let w = max(3, side * 0.09)
            ZStack {
                ring(outer?.percent, pace: outer.map { $0.window.pace(at: date) }, lineWidth: w).padding(w / 2)
                    .accentableIfWidget()
                if ps.count > 1 {
                    ring(inner?.percent, pace: inner.map { $0.window.pace(at: date) }, lineWidth: w * 0.8).padding(w * 1.9)
                        .opacity(0.85)
                }
                VStack(spacing: -1) {
                    Text(outer.map { "\(Int($0.percent.rounded()))" } ?? "--")
                        .font(.system(size: side * 0.3, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text(ps.first?.shortName ?? "AI")
                        .font(.system(size: side * 0.15, weight: .medium))
                        .opacity(0.8)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ring(_ percent: Double?, pace: LimitPace?, lineWidth: CGFloat) -> some View {
        let f = min(max((percent ?? 0) / 100, 0), 1)
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: f)
                .stroke((pace ?? .onPace).ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

extension LimitLevel {
    var ringColor: Color {
        switch self {
        case .fine: .green
        case .getting: .orange
        case .high, .out: .red
        }
    }
}

/// "CL 32% · CX 100%"
func limitsInlineText(_ snapshot: LimitsSnapshot?, at date: Date = .now) -> String {
    let parts = (snapshot?.orderedProviders ?? []).prefix(2).compactMap { p in
        p.worst(at: date).map { "\(p.shortName) \(Int($0.percent.rounded()))%" }
    }
    return parts.isEmpty ? "AI limits" : parts.joined(separator: " · ")
}

private extension View {
    @ViewBuilder func accentableIfWidget() -> some View {
        #if canImport(WidgetKit)
        self.widgetAccentable()
        #else
        self
        #endif
    }
}
