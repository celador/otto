import SwiftUI

/// Full-screen hands-free conversation over the current chat.
struct VoiceModeView: View {
    @Environment(\.dismiss) private var dismiss
    @State var session: VoiceSession
    var title: String = "Otto"
    /// Quick squeeze of the orb when you talk over Otto.
    @State private var squeeze: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if let engine = session.engineName {
                    Label(engine, systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Spacer()

            Button { Task { await session.tap() } } label: {
                VoiceOrb(phase: session.phase, level: session.level)
                    .frame(width: 220, height: 220)
                    .scaleEffect(squeeze)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(orbHint)

            VStack(spacing: 10) {
                Group {
                    if session.phase == .thinking {
                        TypingIndicator(text: session.status ?? "Thinking")
                    } else {
                        Text(statusText)
                    }
                }
                .font(.title3.weight(.semibold))
                Text(caption)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(minHeight: 88, alignment: .top)
                    .padding(.horizontal, 32)
                    .animation(.easeOut(duration: 0.15), value: caption)
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 36)

            Spacer()

            HStack(spacing: 56) {
                Button {
                    session.muted.toggle()
                    if !session.muted { Task { await session.tap() } }
                    Haptics.tap()
                } label: {
                    Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(session.muted ? Color(.systemBackground) : .primary)
                        .frame(width: 64, height: 64)
                        .background(session.muted ? Color.primary : Color(.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel(session.muted ? "Unmute" : "Mute")
                Button {
                    session.end()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("End voice")
            }
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .task {
            #if DEBUG
            if let p = UserDefaults.standard.string(forKey: "hermes.voicePreview") { session.debugPreview(p); return }
            if let p = UserDefaults.standard.string(forKey: "hermes.voiceSelfTest") { await session.debugSelfTest(p); return }
            #endif
            await session.start()
        }
        .onDisappear { session.end() }
        .onChange(of: session.bargeIns) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { squeeze = 0.82 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.12)) { squeeze = 1 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: session.phase)
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    private var statusText: String {
        switch session.phase {
        case .idle: "Starting…"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .paused: "Muted"
        case .error: "Can't listen"
        }
    }

    private var caption: String {
        switch session.phase {
        case .listening: session.heard.isEmpty ? "Go ahead, I'm listening." : session.heard
        case .thinking: session.heard
        case .speaking: Self.tail(session.spoken)
        case .paused: "Tap the mic to talk again."
        case .error(let m): m
        case .idle: ""
        }
    }

    private var footnote: String {
        switch session.phase {
        case .speaking: "Talk anytime to interrupt"
        case .listening where !session.heard.isEmpty: "Tap the circle to send now"
        default: " "
        }
    }

    private var orbHint: String {
        switch session.phase {
        case .speaking: "Interrupt"
        case .listening: "Send now"
        case .paused, .error: "Start listening"
        default: "Voice"
        }
    }

    /// Last sentence or two of what's being said.
    static func tail(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 180 else { return t }
        return "…" + t.suffix(180)
    }
}

/// Monochrome breathing orb: grows with your voice, pulses while thinking,
/// ripples while Hermes speaks.
struct VoiceOrb: View {
    let phase: VoiceSession.Phase
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let lvl = CGFloat(level)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.30
                let breathe = (sin(t * 1.6) + 1) / 2
                var radius = base
                switch phase {
                case .listening: radius = base * (1 + 0.32 * lvl)
                case .speaking: radius = base * (1 + 0.22 * lvl)
                case .thinking: radius = base * (0.92 + 0.08 * breathe)
                default: radius = base * 0.9
                }
                // Rings
                let rings = phase == .speaking ? 3 : phase == .listening ? 2 : 1
                for i in 0..<rings {
                    let p = (t * 0.6 + Double(i) / Double(rings)).truncatingRemainder(dividingBy: 1)
                    let r = radius * (1.1 + 0.55 * p)
                    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(0.18 * (1 - p))), lineWidth: 1.5)
                }
                // Core
                let rect = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
                let dim = phase == .paused || phase == .idle
                ctx.fill(Path(ellipseIn: rect), with: .color(.primary.opacity(dim ? 0.25 : 0.92)))
                if phase == .thinking {
                    let a = t * 2.4
                    for k in 0..<3 {
                        let ang = a + Double(k) * 2.094
                        let p = CGPoint(x: c.x + cos(ang) * radius * 0.45, y: c.y + sin(ang) * radius * 0.45)
                        let d = radius * 0.16
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                                 with: .color(Color(.systemBackground).opacity(0.85)))
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
