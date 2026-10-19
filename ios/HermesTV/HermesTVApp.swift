import SwiftUI

@main
struct HermesTVApp: App {
    @State private var model = TVModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.config == nil {
                    TVPairView()
                } else {
                    TVRootView()
                }
            }
            .environment(model)
            .preferredColorScheme(.dark)
        }
    }
}

enum TVTab: Hashable { case talk, chats, now, settings }

struct TVRootView: View {
    @Environment(TVModel.self) private var model
    @State private var tab: TVTab = .talk

    var body: some View {
        TabView(selection: $tab) {
            Tab("Talk", systemImage: "mic", value: TVTab.talk) { TVTalkView() }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: TVTab.chats) {
                TVChatsView { chat in
                    Task { await model.open(chat) }
                    tab = .talk
                }
            }
            Tab("Now", systemImage: "gauge.with.dots.needle.33percent", value: TVTab.now) { TVNowView() }
            Tab("Settings", systemImage: "gearshape", value: TVTab.settings) { TVSettingsView() }
        }
        .task {
            #if DEBUG
            switch UserDefaults.standard.string(forKey: "tv.tab") {
            case "chats": tab = .chats
            case "now": tab = .now
            case "settings": tab = .settings
            default: break
            }
            if let q = UserDefaults.standard.string(forKey: "tv.ask"), !q.isEmpty { model.ask(q) }
            #endif
            await model.refreshDashboard()
        }
    }
}

// MARK: - Talk

struct TVTalkView: View {
    @Environment(TVModel.self) private var model
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                talkField
                if model.turns.isEmpty {
                    emptyState
                } else {
                    if let title = model.sessionTitle {
                        Text(title).font(.headline).foregroundStyle(.secondary)
                    }
                    ForEach(model.turns) { turn in TVTurnView(turn: turn) }
                    controls
                }
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: fieldFocused) { _, focused in
            // tvOS's keyboard closes with Done or Menu; either way, what was said gets sent.
            if !focused { send() }
        }
    }

    private var talkField: some View {
        HStack(spacing: 24) {
            Image(systemName: model.isRunning ? "waveform" : "mic.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor, isActive: model.isRunning)
            TextField(model.isRunning ? "Otto is working…" : (model.turns.isEmpty ? "Talk to Otto" : "Reply"), text: $text)
                .font(.title2)
                .focused($fieldFocused)
                .onSubmit { send() }
                .disabled(model.isRunning)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Select the field above, then hold the microphone button on your Siri Remote and talk.")
                .font(.title3)
            Text("Let go when you're done and press Menu. Otto answers on screen and out loud.")
                .font(.body).foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 30) {
            if model.isRunning {
                Button(role: .destructive) { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                if let last = model.turns.last, TVModel.asksYesNo(last.answer) {
                    Button { model.ask("Yes") } label: { Label("Yes", systemImage: "checkmark") }
                    Button { model.ask("No") } label: { Label("No", systemImage: "xmark") }
                }
                if model.speaking {
                    Button { model.stopSpeaking() } label: { Label("Stop reading", systemImage: "speaker.slash") }
                } else if let last = model.turns.last, !last.answer.isEmpty {
                    Button { Task { await model.speak(last.answer) } } label: { Label("Read aloud", systemImage: "speaker.wave.2") }
                }
                Button { model.newConversation() } label: { Label("New conversation", systemImage: "plus") }
            }
        }
        .padding(.top, 10)
    }

    private func send() {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !model.isRunning else { return }
        text = ""
        model.ask(said)
    }
}

struct TVTurnView: View {
    let turn: TVTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(turn.question)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            if !turn.answer.isEmpty {
                // Separate focusable paragraphs so the remote can scroll through long answers.
                ForEach(Array(TVText.paragraphs(turn.answer).enumerated()), id: \.offset) { _, p in
                    TVParagraph(text: p, failed: turn.failed)
                }
            }
            if !turn.done {
                HStack(spacing: 16) {
                    ProgressView()
                    Text(turn.status).font(.headline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TVParagraph: View {
    let text: String
    let failed: Bool
    @FocusState private var focused: Bool

    var body: some View {
        Text(TVText.attributed(text))
            .font(.system(size: 46))
            .lineSpacing(8)
            .foregroundStyle(failed ? .orange : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(focused ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14))
            .focusable()
            .focused($focused)
    }
}

enum TVText {
    nonisolated static func paragraphs(_ s: String) -> [String] {
        s.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    nonisolated static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Chats

struct TVChatsView: View {
    @Environment(TVModel.self) private var model
    let onOpen: (HermesLite.ChatRow) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 520), spacing: 40)], spacing: 40) {
                ForEach(model.chats) { chat in
                    Button { onOpen(chat) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(chat.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                            if let t = chat.lastActive {
                                Text(Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        .padding(24)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 40)
        }
        .overlay {
            if model.chats.isEmpty { ContentUnavailableView("No chats yet", systemImage: "bubble.left") }
        }
        .task { await model.refreshDashboard() }
    }
}

// MARK: - Now

struct TVNowView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 80) {
                VStack(alignment: .leading, spacing: 30) {
                    Text("AI limits").font(.title3.weight(.semibold))
                    DualLimitRing(snapshot: model.limits)
                        .frame(width: 300, height: 300)
                    ForEach(model.limits?.orderedProviders ?? []) { p in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(p.name).font(.headline)
                            ForEach(p.windows) { w in
                                HStack {
                                    Text(w.label).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Int(w.effectivePercent(at: .now).rounded()))%").monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                        .frame(width: 420)
                        .focusable()
                    }
                    if model.limits == nil { Text("--").font(.title).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 24) {
                    Text("Scheduled jobs").font(.title3.weight(.semibold))
                    ForEach(model.jobs.prefix(8)) { job in
                        Button { Task { await model.run(job) } } label: {
                            HStack(spacing: 20) {
                                Image(systemName: job.isPaused ? "pause.circle" : (job.lastFailed ? "exclamationmark.triangle" : "play.circle"))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.title).font(.headline).lineLimit(1)
                                    if let next = job.nextRun, !job.isPaused {
                                        Text("Next \(next.formatted(.relative(presentation: .named)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("Run").font(.callout)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    if model.jobs.isEmpty { Text("No scheduled jobs").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 40)
        }
        .task { await model.refreshDashboard() }
    }
}

// MARK: - Settings

struct TVSettingsView: View {
    @Environment(TVModel.self) private var model
    @AppStorage(VoiceChoice.mainKey) private var main = VoiceChoice.hermesDefault
    @AppStorage(VoiceChoice.spanishKey) private var spanish = VoiceChoice.defaultSpanish
    @AppStorage(VoiceChoice.speedKey) private var speed = 1.0

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Read answers aloud", isOn: $m.speakAnswers)
                }
                Section {
                    pills([CuratedVoice(id: VoiceChoice.hermesDefault, label: model.hermesDefaultLabel)]
                          + VoiceChoice.curatedMain, selection: $main, id: "main")
                    NavigationLink {
                        TVAllVoicesView(selection: $main, title: "Voice")
                    } label: {
                        LabeledContent("All voices", value: main.isEmpty ? model.hermesDefaultLabel
                                                                         : VoiceChoice.displayName(main, in: model.voices))
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    if model.voicesOutdated { Text("Restart the relay on your Mac to pick voices.") }
                }
                Section("Spanish replies use") {
                    pills(VoiceChoice.curatedSpanish + [CuratedVoice(id: VoiceChoice.sameAsMain, label: "Same voice")],
                          selection: $spanish, id: "spanish")
                    NavigationLink {
                        TVAllVoicesView(selection: $spanish, title: "Spanish replies use")
                    } label: {
                        LabeledContent("All voices", value: spanish.isEmpty ? "Same voice"
                                                                            : VoiceChoice.displayName(spanish, in: model.voices))
                    }
                }
                Section("Speaking speed") {
                    HStack(spacing: 30) {
                        Button { speed = max(VoiceChoice.speedRange.lowerBound, ((speed - 0.1) * 10).rounded() / 10) } label: {
                            Image(systemName: "tortoise")
                        }
                        Text(String(format: "%.1f×", speed)).font(.title3.monospacedDigit()).frame(minWidth: 120)
                        Button { speed = min(VoiceChoice.speedRange.upperBound, ((speed + 0.1) * 10).rounded() / 10) } label: {
                            Image(systemName: "hare")
                        }
                    }
                }
                Section("Connection") {
                    LabeledContent("Server", value: model.config?.gateway.host() ?? "—")
                    LabeledContent("This app", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                }
            }
            .frame(maxWidth: 1300)
        }
        .task { await model.loadVoices() }
    }

    /// Fícha-style pills: tap to choose and hear the voice.
    private func pills(_ voices: [CuratedVoice], selection: Binding<String>, id: String) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 24) {
                ForEach(voices) { voice in
                    Button {
                        selection.wrappedValue = voice.id
                        if !(id == "spanish" && voice.id.isEmpty) { Task { await model.preview(voice.id) } }
                    } label: {
                        Label(voice.label, systemImage: selection.wrappedValue == voice.id ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityIdentifier("settings.voice.\(id).\(voice.id)")
                }
            }
            .padding(.vertical, 16).padding(.horizontal, 8)
        }
        .scrollClipDisabled()
    }
}

/// Every Edge voice, grouped by language, with search. Selecting one plays a short preview.
struct TVAllVoicesView: View {
    @Environment(TVModel.self) private var model
    @Binding var selection: String
    let title: String
    @State private var query = ""

    var body: some View {
        List {
            if model.voicesOutdated {
                Text("Restart the relay on your Mac to pick voices.")
            }
            ForEach(VoiceChoice.groups(model.voices, query: query)) { group in
                Section(group.title) {
                    ForEach(group.voices) { voice in
                        Button {
                            selection = voice.shortName
                            Task { await model.preview(voice.shortName) }
                        } label: {
                            HStack {
                                Text(voice.label)
                                Text(voice.gender).foregroundStyle(.secondary)
                                Spacer()
                                if selection == voice.shortName { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(title)
        .task { await model.loadVoices() }
    }
}
