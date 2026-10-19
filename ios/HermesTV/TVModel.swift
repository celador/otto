import AVFoundation
import Foundation
import Observation

/// One spoken turn on the TV.
struct TVTurn: Identifiable, Equatable, Sendable {
    let id = UUID()
    var question: String
    var answer: String = ""
    var status: String = "Thinking…"
    var done = false
    var failed = false
}

@MainActor @Observable
final class TVModel {
    var config: TVConfig?
    var turns: [TVTurn] = []
    var sessionID: String?
    var sessionTitle: String?
    var chats: [HermesLite.ChatRow] = []
    var limits: LimitsSnapshot?
    var jobs: [JobLite] = []
    var errorMessage: String?
    var speaking = false
    // `bool(forKey:)` also reads "-tv.speak NO" launch args; `object as? Bool` didn't, so a test spoke aloud.
    var speakAnswers = UserDefaults.standard.object(forKey: "tv.speak") == nil ? true : UserDefaults.standard.bool(forKey: "tv.speak") {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "tv.speak") }
    }

    private var player: AVAudioPlayer?
    private var runTask: Task<Void, Never>?
    private var currentRun: String?

    static let instructions = """
    This message was spoken to an Apple TV with the Siri Remote and transcribed (it may contain \
    mis-hearings; use the latest intent). Your reply is read aloud in the living room and shown in \
    large type on the TV: answer conversationally in a few short sentences or short paragraphs unless \
    asked for detail. No markdown tables, no code blocks, no raw URLs. Do the work with your tools as \
    usual. Do not claim an action succeeded before it actually did.
    """

    init() {
        config = TVKeychain.load()
        #if DEBUG
        let d = UserDefaults.standard
        if let g = d.string(forKey: "tv.gateway"), let r = d.string(forKey: "tv.relay"), let k = d.string(forKey: "tv.key"),
           let gu = URL(string: g), let ru = URL(string: r), !k.isEmpty {
            config = TVConfig(gateway: gu, relay: ru, apiKey: k)
        }
        if d.bool(forKey: "tv.unpaired") { config = nil }
        #endif
    }

    var isRunning: Bool { turns.last.map { !$0.done } ?? false }

    func connect(_ c: TVConfig) {
        TVKeychain.save(c)
        config = c
    }

    func disconnect() {
        TVKeychain.save(nil)
        config = nil
        newConversation()
    }

    // MARK: Dashboard

    func refreshDashboard() async {
        guard let c = config else { return }
        async let chats = try? c.lite.recentChats(limit: 12)
        async let limits = try? LimitsAPI.fetch(relay: c.relay, apiKey: c.apiKey, timeout: 30)
        async let jobs = try? JobsAPI.list(relay: c.relay, apiKey: c.apiKey)
        if let v = await chats { self.chats = v }
        if let v = await limits { self.limits = v }
        if let v = await jobs { self.jobs = JobsAPI.ordered(v) }
    }

    func run(_ job: JobLite) async {
        guard let c = config else { return }
        do { try await JobsAPI.run(job, relay: c.relay, apiKey: c.apiKey) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Conversation

    func newConversation() {
        runTask?.cancel()
        stopSpeaking()
        turns = []
        sessionID = nil
        sessionTitle = nil
    }

    /// Continue an existing chat: show its last exchange, follow-ups go to that session.
    func open(_ chat: HermesLite.ChatRow) async {
        newConversation()
        sessionID = chat.id
        sessionTitle = chat.title
        guard let c = config else { return }
        if let ex = try? await c.lite.lastExchange(sessionID: chat.id) {
            turns = [TVTurn(question: ex.asked ?? "", answer: ex.answer ?? "", status: "", done: true)]
        }
    }

    func ask(_ raw: String) {
        let said = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, let c = config, !isRunning else { return }
        stopSpeaking()
        turns.append(TVTurn(question: said))
        let index = turns.count - 1
        runTask = Task {
            do {
                let lite = c.lite
                if sessionID == nil {
                    let title = HermesLite.title(for: said, prefix: "📺 ")
                    sessionID = try await lite.createSession(title: title)
                    sessionTitle = title
                }
                let turn = try await lite.ask(audio: nil, text: said, sessionID: sessionID, instructions: Self.instructions)
                currentRun = turn.runID
                try await follow(turn.runID, index: index, lite: lite)
            } catch is CancellationError {
            } catch {
                guard turns.indices.contains(index) else { return }
                turns[index].failed = true
                turns[index].done = true
                turns[index].status = ""
                turns[index].answer = error.localizedDescription
            }
            currentRun = nil
        }
    }

    func stop() {
        if let run = currentRun, let c = config { Task { await c.lite.stop(runID: run) } }
        runTask?.cancel()
        if let i = turns.indices.last, !turns[i].done {
            turns[i].done = true
            turns[i].status = ""
            if turns[i].answer.isEmpty { turns[i].answer = "Stopped." }
        }
        stopSpeaking()
    }

    private func follow(_ runID: String, index: Int, lite: HermesLite) async throws {
        var misses = 0
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(1))
            let state: HermesLite.RunState
            do { state = try await lite.status(runID: runID); misses = 0 } catch {
                misses += 1
                if misses > 20 { throw error }
                continue
            }
            guard turns.indices.contains(index) else { return }
            turns[index].status = Self.statusText(state.lastEvent)
            if let out = state.output, !out.isEmpty { turns[index].answer = out }
            if state.isDone {
                turns[index].done = true
                turns[index].status = ""
                if state.status != "completed" {
                    turns[index].failed = turns[index].answer.isEmpty
                    if turns[index].answer.isEmpty { turns[index].answer = "Otto couldn't finish that (\(state.status))." }
                } else if speakAnswers {
                    await speak(turns[index].answer)
                }
                Task { await refreshDashboard() }
                return
            }
        }
    }

    nonisolated static func statusText(_ event: String?) -> String {
        let e = (event ?? "").lowercased()
        if e.contains("tool") { return "Using tools…" }
        if e.contains("approval") { return "Needs your approval on your phone" }
        if e.contains("delta") || e.contains("message") || e.contains("output") { return "Writing…" }
        return "Thinking…"
    }

    /// Hermes asked a yes/no-style question at the end of its answer.
    nonisolated static func asksYesNo(_ answer: String) -> Bool {
        guard let last = answer.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { ".!\n".contains($0) }).last
        else { return false }
        let s = last.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.hasSuffix("?") else { return false }
        let starts = ["should", "shall", "do you", "would you", "want", "can i", "could i", "is that", "are you", "did you", "will you", "ok", "okay", "is it"]
        return starts.contains { s.hasPrefix($0) } || s.contains("want me to")
    }

    // MARK: Voice out

    func speak(_ text: String) async {
        guard let c = config, !text.isEmpty else { return }
        // Spanish paragraphs in the Spanish voice, the rest in the chosen voice.
        let segments = VoiceChoice.plan(String(text.prefix(4000)), main: VoiceChoice.main,
                                        spanish: VoiceChoice.spanish, maxChars: 1500)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        speaking = true
        defer { speaking = false }
        let lite = c.lite, speed = VoiceChoice.speed
        func fetch(_ i: Int) -> Task<Data?, Never>? {
            guard segments.indices.contains(i) else { return nil }
            let seg = segments[i]
            return Task { try? await lite.speak(seg.text, voice: seg.voice, speed: speed) }
        }
        var next = fetch(0)
        for i in segments.indices {
            let data = await next?.value
            next = fetch(i + 1)
            guard !Task.isCancelled, speaking else { next?.cancel(); return }
            guard let data, let p = try? AVAudioPlayer(data: data) else { continue }
            player = p
            p.play()
            while p.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
            if player !== p { next?.cancel(); return }   // stopped
        }
    }

    // MARK: Voice choice (Settings)

    private(set) var voices: [EdgeVoice] = []
    private(set) var hermesVoice: String?
    private(set) var voicesOutdated = false
    private var previewPlayer: AVAudioPlayer?
    private(set) var previewing: String?

    func loadVoices() async {
        guard let c = config, voices.isEmpty else { return }
        do {
            let r = try await c.lite.voices()
            voices = r.voices
            hermesVoice = r.default.isEmpty ? nil : r.default
        } catch HermesLite.Failure.http(404, _) {
            voicesOutdated = true
        } catch {}
    }

    var hermesDefaultLabel: String {
        guard let v = hermesVoice else { return "Hermes default" }
        let name = VoiceChoice.displayName(v, in: voices)
        return "Hermes default (\(name.split(separator: " ").first.map(String.init) ?? name))"
    }

    /// Plays one short line in a voice ("" = Hermes default).
    func preview(_ id: String) async {
        guard let c = config else { return }
        previewPlayer?.stop()
        previewing = id
        let effective = id.isEmpty ? (hermesVoice ?? "en-US-AriaNeural") : id
        let v = voices.first { $0.shortName == effective }
        let name = v?.name ?? VoiceChoice.displayName(effective).split(separator: " ").first.map(String.init) ?? "Otto"
        let sample = VoiceChoice.sample(language: v?.language ?? String(effective.prefix(2)), name: name)
        defer { if previewing == id { previewing = nil } }
        guard let data = try? await c.lite.speak(sample, voice: id.isEmpty ? nil : id, speed: VoiceChoice.speed),
              previewing == id, let p = try? AVAudioPlayer(data: data) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        previewPlayer = p
        p.play()
        while p.isPlaying, previewPlayer === p { try? await Task.sleep(for: .milliseconds(250)) }
    }

    func stopSpeaking() {
        player?.stop()
        player = nil
        speaking = false
    }
}
