import SwiftUI

// Small building blocks for limits, used by the app, the widgets and the watch.

extension LimitLevel {
    var tint: Color {
        switch self {
        case .fine: .primary
        case .getting: .orange
        case .high, .out: .red
        }
    }
}

/// A capsule bar with an optional tick where you'd "expect" to be by now (CodexBar's pace).
struct LimitBar: View {
    let window: LimitWindow
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(window.level.tint)
                    .frame(width: max(window.usedPercent > 0 ? height : 0, geo.size.width * window.fraction))
                if let expected = window.pace?.expectedUsedPercent, expected > 0, expected < 100 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * expected / 100 - 0.75)
                }
            }
        }
        .frame(height: height)
        .padding(.vertical, 2)   // room for the pace tick
        .accessibilityElement()
        .accessibilityLabel("\(window.label) limit")
        .accessibilityValue("\(Int(window.usedPercent.rounded())) percent used")
    }
}

/// One window: label + percent on top, bar, reset countdown.
struct LimitWindowRow: View {
    let window: LimitWindow
    var showPace = true
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(compact ? .caption2.weight(.medium) : .subheadline.weight(.medium))
                Spacer(minLength: 4)
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(compact ? .caption2.monospacedDigit().weight(.semibold) : .subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(window.level == .fine ? Color.primary : window.level.tint)
            }
            LimitBar(window: window, height: compact ? 4 : 6)
            if !compact || window.resetDate != nil {
                HStack(spacing: 4) {
                    if let reset = window.resetDate {
                        Text(window.level == .out ? "Back \(LimitDates.countdown(to: reset))" : "Resets \(LimitDates.countdown(to: reset))")
                    }
                    if showPace, !compact, let pace = window.pace?.short {
                        Text("·")
                        Text(pace).lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
