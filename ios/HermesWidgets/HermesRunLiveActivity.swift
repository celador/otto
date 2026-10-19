import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen banner + Dynamic Island for a running Hermes turn.
struct HermesRunLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesRunAttributes.self) { context in
            // Background tint and system-action colour only take effect on the root view of this closure,
            // so they're set here, not inside LockScreenRunView. Always a dark card with white text:
            // following the colour scheme left white text on the default white banner.
            LockScreenRunView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "hermes://open?session=\(context.attributes.sessionID)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image("OttoMark")
                        .resizable().renderingMode(.template).scaledToFit()
                        .frame(width: 28, height: 28)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RunTimer(context: context).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        StatusLine(state: context.state)
                        if context.state.voice != nil { VoiceStopButton() }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image("OttoMark")
                    .resizable().renderingMode(.template).scaledToFit()
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                CompactTrailing(context: context)
            } minimal: {
                Image(systemName: runIcon(for: context.state))
                    .foregroundStyle(runTint(for: context.state))
            }
            .widgetURL(URL(string: "hermes://open?session=\(context.attributes.sessionID)"))
        }
    }
}

private struct LockScreenRunView: View {
    let context: ActivityViewContext<HermesRunAttributes>
    private let ink = Color.white

    var body: some View {
        content
            .foregroundStyle(ink)
            .environment(\.liveInk, ink)
            .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("OttoMark")
                .resizable().renderingMode(.template).scaledToFit()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(context.attributes.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    RunTimer(context: context).font(.caption.monospacedDigit()).foregroundStyle(ink.opacity(0.6))
                }
                StatusLine(state: context.state)
            }
            if context.state.voice != nil { VoiceStopButton() }
        }
        .padding(14)
    }
}

private struct StatusLine: View {
    let state: HermesRunAttributes.ContentState
    @Environment(\.liveInk) private var ink

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: runIcon(for: state))
                .foregroundStyle(state.finished || state.needsApproval ? runTint(for: state) : (ink ?? .secondary).opacity(0.6))
            Text(statusText(for: state)).lineLimit(1)
            Spacer(minLength: 0)
            if state.toolsUsed > 0 {
                Text("\(state.toolsUsed) step\(state.toolsUsed == 1 ? "" : "s")")
                    .foregroundStyle(ink.map { $0.opacity(0.6) } ?? .secondary)
            }
        }
        .font(.footnote)
    }
}

/// Ends the spoken conversation without unlocking the phone.
private struct VoiceStopButton: View {
    var body: some View {
        Button(intent: StopOttoVoiceIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .background(Color.red.opacity(0.85), in: Circle())
        .foregroundStyle(.white)
        .accessibilityLabel("Stop talking to Otto")
    }
}

private struct CompactTrailing: View {
    let context: ActivityViewContext<HermesRunAttributes>

    var body: some View {
        if context.state.voice != nil || context.state.finished || context.state.needsApproval {
            Image(systemName: runIcon(for: context.state)).foregroundStyle(runTint(for: context.state))
        } else {
            RunTimer(context: context).font(.caption2.monospacedDigit()).frame(maxWidth: 40)
        }
    }
}

private struct RunTimer: View {
    let context: ActivityViewContext<HermesRunAttributes>

    var body: some View {
        if context.state.finished {
            Text(context.state.failed ? "" : "✓")
        } else {
            Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

private func runIcon(for s: HermesRunAttributes.ContentState) -> String {
    if s.needsApproval { return "hand.raised.fill" }
    switch s.voice {
    case "listening": return "mic.fill"
    case "speaking": return "waveform"
    case "muted": return "mic.slash.fill"
    case "thinking": return "ellipsis"
    default: break
    }
    if s.finished { return s.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill" }
    return "ellipsis"
}

/// Voice mode says what it's doing; while it waits on the agent, the agent's status shows instead.
private func statusText(for s: HermesRunAttributes.ContentState) -> String {
    switch s.voice {
    case "listening": return "Listening"
    case "speaking": return "Speaking"
    case "muted": return "Voice · muted"
    default: return s.status
    }
}

private func runTint(for s: HermesRunAttributes.ContentState) -> Color {
    if s.needsApproval { return .orange }
    if s.voice != nil { return .white }
    if s.finished { return s.failed ? .red : .green }
    return .secondary
}

private extension EnvironmentValues {
    /// Explicit text colour on the lock screen; nil in the Dynamic Island (always dark, system colours work).
    @Entry var liveInk: Color? = nil
}
