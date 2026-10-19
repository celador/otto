import SwiftUI

/// The conversation, newest at the bottom, with one big button to talk.
struct WatchHome: View {
    @Bindable var model: WatchModel

    var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if let title = model.title, model.hasConversation {
                            Text(title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if model.turns.isEmpty {
                            Text(model.hasConversation ? "Continuing your last conversation." : "Ask Otto anything.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                        ForEach(model.turns) { turn in
                            TurnView(turn: turn, isLast: turn.id == model.turns.last?.id, model: model).id(turn.id)
                        }
                        controls.id("controls")
                    }
                    .padding(.horizontal, 2)
                }
                // Show the newest exchange from its top, so the answer is readable; jump to the button only while talking.
                .onChange(of: model.turns) {
                    if let last = model.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                }
                .onChange(of: model.phase) {
                    if model.phase == .recording { withAnimation { proxy.scrollTo("controls", anchor: .bottom) } }
                }
            }
            .navigationTitle("Otto")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.speakReplies.toggle() } label: {
                        Image(systemName: model.speakReplies ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .accessibilityLabel(model.speakReplies ? "Replies are spoken" : "Replies are silent")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.phase == .thinking || model.phase == .sending {
                        Button { Task { await model.cancel() } } label: { Image(systemName: "stop.fill") }
                            .accessibilityLabel("Stop")
                    } else {
                        Button { model.newConversation() } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New conversation")
                            .disabled(!model.hasConversation && model.turns.isEmpty)
                    }
                }
            }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            Button { Task { await model.primaryTap() } } label: {
                TalkOrb(phase: model.phase, level: model.level)
                    .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(buttonLabel)

            Text(status)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())

            if case .error(let m) = model.phase {
                Text(m).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 6)
    }


    private var status: String {
        switch model.phase {
        case .idle: model.endedLine ?? (model.turns.isEmpty ? "Tap to talk" : "Tap to talk again")
        case .recording: model.handsFree ? "Listening… · tap to end" : "Listening… \(Int(model.elapsed))s · tap when done"
        case .sending: "Sending…"
        case .thinking: model.liveStatus ?? "Thinking…"
        case .speaking: (model.onHeadphones ? "Speaking in AirPods" : "Speaking") + " · tap to talk"
        case .error: "Tap to try again"
        }
    }

    private var buttonLabel: String {
        switch model.phase {
        case .recording: model.handsFree ? "End conversation" : "Done talking"
        case .speaking: "Interrupt and talk"
        case .sending, .thinking: "End conversation after this answer"
        default: "Talk to Otto"
        }
    }
}

private struct TurnView: View {
    let turn: WatchModel.Turn
    let isLast: Bool
    @Bindable var model: WatchModel
    @State private var expanded = false

    private static let preview = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 20)
                Text(turn.said)
                    .font(.footnote)
                    .lineLimit(3)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
            }
            if let reply = turn.reply {
                let long = reply.count > Self.preview
                Text(long && !expanded ? String(reply.prefix(Self.preview)).trimmingCharacters(in: .whitespaces) + "…" : reply)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if long {
                        Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                    Button { Task { await model.readAloud(turn) } } label: { Image(systemName: "speaker.wave.2.fill") }
                        .font(.caption2)
                        .buttonStyle(.bordered).controlSize(.mini)
                        .accessibilityLabel("Read aloud")
                    Spacer(minLength: 0)
                }
                // Hermes asked something a tap settles.
                if isLast, model.phase == .idle, WatchSnippet.asksYesNo(reply) {
                    HStack(spacing: 8) {
                        Button("Yes") { Task { await model.ask(text: "Yes, go ahead.") } }
                            .tint(.green)
                        Button("No") { Task { await model.ask(text: "No, don't.") } }
                            .tint(.red)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.footnote.weight(.semibold))
                }
            }
        }
    }
}

/// White orb with the mic; breathes with your voice, spins while thinking.
struct TalkOrb: View {
    let phase: WatchModel.Phase
    let level: Float

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                if phase == .recording || phase == .speaking {
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: 2)
                        .scaleEffect(1.0 + CGFloat(level) * 0.28 + (phase == .speaking ? 0.04 * sin(t * 4) : 0))
                }
                Circle()
                    .fill(phase == .recording ? Color.red : Color.white)
                    .scaleEffect(phase == .recording ? 0.82 + CGFloat(level) * 0.12 : 0.82)
                if phase == .thinking || phase == .sending {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Color.black.opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 36, height: 36)
                        .rotationEffect(.radians(t * 4))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(phase == .recording ? Color.white : Color.black)
                }
            }
        }
    }

    private var icon: String {
        switch phase {
        case .recording: "stop.fill"
        case .speaking: "mic.fill"
        default: "mic.fill"
        }
    }
}
