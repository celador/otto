import SwiftUI

/// Edge voices from the relay, loaded once per launch for the pickers.
@MainActor
@Observable
final class VoiceCatalog {
    static let shared = VoiceCatalog()
    private(set) var voices: [EdgeVoice] = []
    /// The Hermes profile's own voice ("en-US-AriaNeural").
    private(set) var hermesVoice: String?
    private(set) var loading = false
    private(set) var outdated = false
    private(set) var error: String?

    func load(_ companion: CompanionClient?, force: Bool = false) async {
        guard let companion, !loading, force || voices.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await companion.voices()
            voices = r.voices
            hermesVoice = r.default.isEmpty ? nil : r.default
            outdated = false
            error = nil
        } catch CompanionError.relayOutdated {
            outdated = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Hermes default (Aria)".
    var hermesDefaultLabel: String {
        guard let v = hermesVoice else { return "Hermes default" }
        let name = VoiceChoice.displayName(v, in: voices)
        return "Hermes default (\(name.split(separator: " ").first.map(String.init) ?? name))"
    }
}

/// Settings → Voice mode: which engine runs the conversation, and Gemini's voice.
struct VoiceModeSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(VoiceEngine.key) private var engine = VoiceEngine.gemini.rawValue
    @AppStorage(VoiceEngine.geminiVoiceKey) private var geminiVoice = ""
    @AppStorage(VoiceEngine.chatgptVoiceKey) private var chatgptVoice = ""
    @State private var chatgpt: GeminiLiveStatus?
    @State private var chatgptError: String?
    @AppStorage(LocalVoice.useKey) private var useLocal = true
    @State private var status: GeminiLiveStatus?
    @State private var statusError: String?
    @State private var local: LocalVoiceStatus?

    private static let fallbackVoices: [GeminiLiveStatus.Voice] = [
        .init(name: "Charon", style: "Informative"), .init(name: "Puck", style: "Upbeat"),
        .init(name: "Kore", style: "Firm"), .init(name: "Aoede", style: "Breezy"),
        .init(name: "Zephyr", style: "Bright"), .init(name: "Sulafat", style: "Warm"),
    ]

    private static let chatgptFallbackVoices: [GeminiLiveStatus.Voice] = [
        .init(name: "cove", style: "Composed, direct"), .init(name: "juniper", style: "Open, upbeat"),
        .init(name: "maple", style: "Cheerful, candid"), .init(name: "spruce", style: "Calm, affirming"),
        .init(name: "ember", style: "Confident, optimistic"), .init(name: "vale", style: "Bright, inquisitive"),
        .init(name: "breeze", style: "Animated, earnest"), .init(name: "arbor", style: "Easygoing, versatile"),
        .init(name: "sol", style: "Savvy, relaxed"),
    ]

    var body: some View {
        Section {
            Picker("Engine", selection: $engine) {
                ForEach(VoiceEngine.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .accessibilityIdentifier("settings.voiceEngine")
            if engine == VoiceEngine.gemini.rawValue {
                Picker("Gemini voice", selection: $geminiVoice) {
                    Text("Default (\(status?.defaultVoice ?? VoiceEngine.defaultGeminiVoice))").tag("")
                    ForEach(status?.voices ?? Self.fallbackVoices, id: \.name) { v in
                        Text("\(v.name) · \(v.style)").tag(v.name)
                    }
                }
                .accessibilityIdentifier("settings.geminiVoice")
            }
            if engine == VoiceEngine.chatgpt.rawValue {
                Picker("ChatGPT voice", selection: $chatgptVoice) {
                    Text("Default (\((chatgpt?.defaultVoice ?? VoiceEngine.defaultChatGPTVoice).capitalized))").tag("")
                    ForEach(chatgpt?.voices ?? Self.chatgptFallbackVoices, id: \.name) { v in
                        Text("\(v.name.capitalized) · \(v.style)").tag(v.name)
                    }
                }
                .accessibilityIdentifier("settings.chatgptVoice")
            }
            if local?.available == true {
                Toggle("Transcribe on your Mac", isOn: $useLocal)
                    .accessibilityIdentifier("settings.localSTT")
            }
        } header: {
            Text("Voice mode")
        } footer: {
            Text(footer)
        }
        .task { await loadStatus() }
    }

    private var footer: String {
        if engine == VoiceEngine.chatgpt.rawValue {
            if let chatgpt, !chatgpt.available {
                return (chatgpt.reason ?? "ChatGPT voice isn't set up on your Mac.") + " Until then voice mode uses Otto voice."
            }
            if chatgptError != nil {
                return "Restart the relay on your Mac to use ChatGPT voice. Until then voice mode uses Otto voice."
            }
            return "ChatGPT's voice on your ChatGPT plan, through your Mac. Talk naturally and interrupt anytime; it hands real work to your agent and tells you the result."
        }
        guard engine == VoiceEngine.gemini.rawValue else {
            if local?.available == true, useLocal {
                return "Parakeet on your Mac writes down what you say (also for the mic in the message box), and Kokoro voices marked “On your Mac” speak the replies. Only your agent's model is in the cloud."
            }
            return "Your iPhone hears you, the agent answers, and Otto reads the reply in the voice below."
        }
        if let status, !status.available {
            return (status.reason ?? "Gemini Live isn't set up on your Mac.") + " Until then voice mode uses Otto voice."
        }
        if statusError != nil {
            return "Restart the relay on your Mac to use Gemini Live. Until then voice mode uses Otto voice."
        }
        return "Talk naturally and interrupt anytime. Gemini answers small talk itself and hands real work to your agent, then tells you the result."
    }

    private func loadStatus() async {
        guard let c = model.companionClient else { return }
        local = try? await c.localVoiceStatus()
        do { status = try await c.geminiLiveStatus(); statusError = nil } catch { statusError = error.localizedDescription }
        do { chatgpt = try await c.liveStatus(.chatgpt); chatgptError = nil } catch { chatgptError = error.localizedDescription }
    }
}

/// Settings → Voice: the voice for replies, speaking speed, and the voice for Spanish sentences.
struct VoiceSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(VoiceChoice.mainKey) private var main = VoiceChoice.hermesDefault
    @AppStorage(VoiceChoice.spanishKey) private var spanish = VoiceChoice.defaultSpanish
    @AppStorage(VoiceChoice.speedKey) private var speed = 1.0
    private var catalog: VoiceCatalog { VoiceCatalog.shared }

    var body: some View {
        Section {
            NavigationLink {
                VoicePickerView(kind: .main)
            } label: {
                LabeledContent("Voice", value: main.isEmpty ? catalog.hermesDefaultLabel
                                                            : VoiceChoice.displayName(main, in: catalog.voices))
            }
            .accessibilityIdentifier("settings.voice")
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Speaking speed", value: Self.speedLabel(speed))
                Slider(value: $speed, in: VoiceChoice.speedRange, step: 0.05) {
                    Text("Speaking speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                VoicePickerView(kind: .spanish)
            } label: {
                LabeledContent("Spanish replies use", value: spanish.isEmpty ? "Same voice"
                                                                         : VoiceChoice.displayName(spanish, in: catalog.voices))
            }
            .accessibilityIdentifier("settings.voice.spanish")
        } header: {
            Text("Voice")
        } footer: {
            if catalog.outdated {
                Text("Restart the relay on your Mac to pick voices.")
            } else {
                Text("Used for voice mode and Read aloud. Sentences in Spanish switch to the Spanish voice.")
            }
        }
        .task { await catalog.load(model.companionClient) }
    }

    /// "1×", "1.1×", "1.25×".
    static func speedLabel(_ speed: Double) -> String {
        var s = String(format: "%.2f", speed)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "×"
    }
}

/// A voice list: hand-picked pills on top, then every Edge voice grouped by language, with search
/// and a Preview button per voice.
struct VoicePickerView: View {
    enum Kind { case main, spanish }
    let kind: Kind

    @Environment(AppModel.self) private var model
    @AppStorage(VoiceChoice.mainKey) private var main = VoiceChoice.hermesDefault
    @AppStorage(VoiceChoice.spanishKey) private var spanish = VoiceChoice.defaultSpanish
    @State private var query = ""
    private var catalog: VoiceCatalog { VoiceCatalog.shared }
    private var preview: VoicePreview { VoicePreview.shared }

    private var selection: Binding<String> {
        kind == .main ? $main : $spanish
    }

    /// The pills: "Hermes default (Aria)" / "Same voice" first, then the curated voices.
    private var pills: [CuratedVoice] {
        switch kind {
        case .main:
            [CuratedVoice(id: VoiceChoice.hermesDefault, label: catalog.hermesDefaultLabel)]
                + VoiceChoice.curatedMain + VoiceChoice.curatedSpanish
        case .spanish:
            VoiceChoice.curatedSpanish + [CuratedVoice(id: VoiceChoice.sameAsMain, label: "Same voice")]
        }
    }

    private var groups: [VoiceGroup] {
        VoiceChoice.groups(catalog.voices, query: query)
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    PillFlow(spacing: 8) {
                        ForEach(pills) { pill in
                            Button {
                                selection.wrappedValue = pill.id
                                playPreview(pill.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: selection.wrappedValue == pill.id ? "checkmark.circle.fill" : "circle")
                                    Text(pill.label).lineLimit(1)
                                }
                                    .fixedSize()
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .foregroundStyle(selection.wrappedValue == pill.id ? Color(.systemBackground) : .primary)
                                    .background(selection.wrappedValue == pill.id ? Color.primary : Color(.secondarySystemFill),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("voice.pill.\(pill.id.isEmpty ? "default" : pill.id)")
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Suggested")
                } footer: {
                    Text(kind == .spanish
                         ? "Sentences detected as Spanish are read in this voice. Tap a voice to hear it."
                         : "Tap a voice to choose it and hear it.")
                }
            }
            if catalog.outdated {
                Section {
                    Label("Restart the relay on your Mac to pick voices", systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                }
            } else if let error = catalog.error, catalog.voices.isEmpty {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { Task { await catalog.load(model.companionClient, force: true) } }
                }
            } else if catalog.loading, catalog.voices.isEmpty {
                Section { HStack { ProgressView(); Text("Loading voices…").foregroundStyle(.secondary) } }
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.voices) { voice in row(voice) }
                }
            }
        }
        .searchable(text: $query, prompt: "Search voices, languages, countries")
        .navigationTitle(kind == .main ? "Voice" : "Spanish replies use")
        .navigationBarTitleDisplayMode(.inline)
        .task { await catalog.load(model.companionClient) }
        .onDisappear { preview.stop() }
    }

    private func row(_ voice: EdgeVoice) -> some View {
        HStack(spacing: 12) {
            Button {
                selection.wrappedValue = voice.shortName
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.label).foregroundStyle(.primary)
                        Text("\(voice.gender) · \(voice.locale)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection.wrappedValue == voice.shortName {
                        Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                playPreview(voice.shortName, voice: voice)
            } label: {
                Image(systemName: preview.playing == voice.shortName ? "stop.circle" : "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(preview.playing == voice.shortName ? "Stop preview" : "Preview \(voice.name)")
        }
    }

    private func playPreview(_ id: String, voice: EdgeVoice? = nil) {
        if kind == .spanish, id.isEmpty { preview.stop(); return }
        let v = voice ?? catalog.voices.first { $0.shortName == id }
        let effective = id.isEmpty ? (catalog.hermesVoice ?? "") : id
        let lang = v?.language ?? String(effective.prefix(2))
        let name = v?.name ?? VoiceChoice.displayName(effective, in: catalog.voices).split(separator: " ").first.map(String.init) ?? "Otto"
        preview.play(voice: id, sample: VoiceChoice.sample(language: lang, name: name), spanish: lang == "es",
                     companion: model.companionClient)
    }
}
