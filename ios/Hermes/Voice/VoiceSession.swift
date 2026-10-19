import AVFoundation
import Observation
import Speech
#if canImport(UIKit)
import UIKit
#endif

/// Hands-free, full-duplex conversation, like ChatGPT's voice mode.
///
/// The mic stays on the whole time (one `VoiceAudio` engine with echo cancellation), so you can talk
/// over the reply: Otto stops at once, drops what it was about to say and treats what you said as your
/// next turn — a steer if the agent is still working, a stop if you said "stop", otherwise a new turn.
/// Your turn ends after an adaptive pause (short when you've clearly finished, longer mid-phrase).
///
/// Speech-to-text runs on the phone. Replies are spoken in Hermes's own voice, streamed from the relay
/// (`/hermes/speak/stream`, first audio in ~1 s) with the next sentence prefetched while one plays;
/// fallbacks: the whole-clip route (`/hermes/speak`), then the iPhone voice.
@MainActor
@Observable
final class VoiceSession {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case paused
        case error(String)
    }

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            VoiceDiag.log("phase \(oldValue) -> \(phase)")
            if phase == .listening { listeningSince = Date() }
            headphonesPhaseChanged(from: oldValue)
            pushLiveActivity(force: true)
        }
    }
    /// What you're saying (live) or last said.
    private(set) var heard = ""
    /// The reply being spoken, so the screen can show it.
    private(set) var spoken = ""
    /// 0…1 microphone (listening) or playback (speaking) loudness.
    private(set) var level: Float = 0
    /// Bumped on every barge-in, so the orb can react.
    private(set) var bargeIns = 0
    /// What Hermes is doing while you wait ("Searching the web: …").
    var status: String? { chat.liveStatus }
    var muted = false { didSet { if muted != oldValue { applyMute() } } }

    private let chat: ChatModel
    private let companion: CompanionClient?
    private let profile: String
    private let title: String
    private let audio = VoiceAudio()
    /// Gemini Live runs the conversation (nil = the classic on-device pipeline).
    private var live: GeminiLive?
    /// "Gemini Live" while it runs the conversation, for the screen.
    private(set) var engineName: String?
    /// Parakeet on the Mac re-transcribes each finished turn (Apple's recognizer still drives the live
    /// caption and end-of-turn timing).
    @ObservationIgnored private var localSTT = false
    @ObservationIgnored private let turnAudio: TurnAudio
    @ObservationIgnored private let turnEncoder: LiveMicEncoder
    /// When your current turn started (for cutting its audio out of `turnAudio`).
    @ObservationIgnored private var turnStartedAt = Date()

    // listening
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognitionGeneration = 0
    private var recognizedCount = 0
    private var audioBuffersSeen = 0
    private var recognitionRestart: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var heardChangedAt = Date()
    /// When this turn's first words came (for the max turn length).
    private var firstWordsAt: Date?
    /// Transcript changes ignored as far-field (other people) this turn, for the voice log.
    private var farFieldChanges = 0
    private var stableUpdates = 0
    private var lastVoiceAt = Date.distantPast
    private var noise = VoiceLogic.NoiseFloor()
    private var voicedRun = VoiceLogic.VoicedRun()
    /// What the recognizer hears while Otto is talking or working (barge-in detection).
    private var monitorHeard = ""
    /// The reply text that was playing when you barged in, stripped from the start of your turn.
    private var echoContext = ""
    /// Your words from earlier recognition segments of this turn (the recognizer closes a segment on a
    /// pause; the turn goes on until endpointing says you're done).
    private var committedHeard = ""
    private var listeningSince = Date()
    /// You said "stop": don't follow the run while it winds down.
    private var stoppingRun = false

    // reply → speech
    private var watchTask: Task<Void, Never>?
    private var replyID: String?
    private var spokenUpTo = 0          // characters of the current reply already queued (or skipped)
    private var replyText = ""          // the current reply's cleaned text, as last seen
    /// You talked over this reply: the rest of the same message isn't spoken.
    private var skipCurrentReply = false
    /// Normalized chunks already queued for this reply (a chunk is never spoken twice).
    private var queuedChunks: [String] = []
    /// Runs after the queued speech finishes instead of listening again (e.g. "new chat").
    private var afterSpeech: (() -> Void)?
    private var firstChunk = true
    private var replyDone = false
    private var pendingTexts: [String] = []
    private var inflight: [AudioClip] = []
    private var playingClip: AudioClip?
    private var previewOnly = false
    private var speakTask: Task<Void, Never>?
    private var captionMarks: [(index: Int, text: String)] = []
    private var recentlySpoken: [String] = []
    private var useStream = true
    private var useHermesVoice = true
    /// The last routed sentence was Spanish (short ones like "Sí." keep the language).
    private var lastSpanish = false
    private var interruptionObserver: NSObjectProtocol?
    private var lastActivityPush = Date.distantPast
    /// The headphone button sends / interrupts / ends (see `HeadphoneControl`).
    @ObservationIgnored let headphones = HeadphoneControl()

    /// Phone-side commands said out loud ("/model haiku", "/new"): returns what Otto says back.
    var onCommand: ((String) async -> VoiceCommandResult)?

    init(chat: ChatModel, companion: CompanionClient?, profile: String = "default", title: String = "Otto") {
        self.chat = chat
        self.companion = companion
        let turnAudio = TurnAudio()
        self.turnAudio = turnAudio
        self.turnEncoder = LiveMicEncoder { chunk in turnAudio.append(chunk) }
        self.profile = profile
        self.title = title
    }

    #if DEBUG
    /// Screenshot aid: show a phase without touching the mic.
    func debugPreview(_ name: String) {
        previewOnly = true
        switch name {
        case "listening": phase = .listening; heard = "What's on my calendar tomorrow?"; level = 0.6
        case "thinking": phase = .thinking; heard = "What's on my calendar tomorrow?"
        case "bargein": phase = .listening; heard = "Wait, make it Tuesday instead"; level = 0.7; bargeIns = 1
        default: phase = .speaking; spoken = "Sure. Saturday looks sunny in Lisbon, around twenty-seven degrees, with a little rain on Sunday."; level = 0.5
        }
    }

    /// Device self-test (`-hermes.voiceSelfTest "<prompt>"`): the prompt is rendered with the iPhone voice and
    /// fed to the recognizer as if spoken, the reply's audio plays at volume 0. Everything else is real.
    func debugSelfTest(_ prompt: String) async {
        await start()
        audio.muteOutput()
        if let live {
            // Gemini Live: the prompt goes in as typed text; everything after (tool call → agent run →
            // spoken answer, muted) is real.
            VoiceDiag.log("selftest(gemini): sending \"\(prompt)\"")
            try? await Task.sleep(for: .milliseconds(500))
            live.debugSendText(prompt)
            return
        }
        VoiceDiag.log("selftest: injecting \"\(prompt)\" phase=\(phase)")
        try? await Task.sleep(for: .milliseconds(800))
        guard let request else { VoiceDiag.log("selftest: no recognition request"); return }
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: prompt)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        let stream = AsyncStream<BufferBox> { c in Self.render(synth, u) { if let b = $0 { c.yield(b) } else { c.finish() } } }
        var n = 0
        for await box in stream { request.append(box.buffer); turnEncoder.append(box.buffer); n += 1 }
        _ = synth
        VoiceDiag.log("selftest: appended \(n) buffers")
        // Recognizer unavailable (simulator): type the words in so the rest of the pipeline is exercised.
        try? await Task.sleep(for: .seconds(5))
        if phase == .listening, heard.isEmpty {
            VoiceDiag.log("selftest: recognizer heard nothing; injecting text")
            heard = prompt
            finishTurn()
        }
        // Optional second utterance while Otto is thinking (`-hermes.voiceSelfTestFollowUp "<text>"`):
        // exercises "talking while thinking" — the reply must still be spoken, never dropped.
        if let follow = UserDefaults.standard.string(forKey: "hermes.voiceSelfTestFollowUp") {
            try? await Task.sleep(for: .milliseconds(600))
            VoiceDiag.log("selftest: follow-up while phase=\(phase): \"\(follow)\"")
            if phase == .thinking {
                monitorHeard = follow
                userStartedTalking()
            }
            try? await Task.sleep(for: .seconds(2.5))
            if phase == .listening { finishTurn() }
        }
    }
    #endif

    // MARK: Control

    func start() async {
        VoiceDiag.log("start: build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?") session=\(chat.sessionID ?? "new") companion=\(companion != nil) engine=\(VoiceEngine.current.rawValue)")
        if VoiceEngine.current.isLive, let companion, await startLive(companion, engine: VoiceEngine.current) { return }
        guard await Self.requestPermissions() else {
            VoiceDiag.log("permissions denied")
            phase = .error("Allow Microphone and Speech Recognition for Otto in Settings.")
            return
        }
        let rec = SFSpeechRecognizer()
        VoiceDiag.log("recognizer locale=\(rec?.locale.identifier ?? "nil") available=\(rec?.isAvailable ?? false) onDevice=\(rec?.supportsOnDeviceRecognition ?? false)")
        guard let recognizer = rec, recognizer.isAvailable else {
            phase = .error("Speech recognition isn't available right now.")
            return
        }
        self.recognizer = recognizer
        Speaker.shared.stop()
        configureAudioSession()
        audio.onInput = { [weak self] db, duration in self?.heardAudio(db: db, duration: duration) }
        audio.onOutputLevel = { [weak self] lvl in
            guard let self, self.phase == .speaking else { return }
            self.level = self.level * 0.5 + lvl * 0.5
        }
        audio.onBufferPlayed = { [weak self] index in self?.bufferPlayed(index) }
        audio.onRestart = { [weak self] in self?.audioRestarted() }
        do { try audio.start() } catch {
            VoiceDiag.log("audio.start failed: \(error)")
            phase = .error("Couldn't start the microphone.")
            return
        }
        VoiceDiag.log("audio started: \(audio.describe())")
        if LocalVoice.enabled, let companion { Task { await enableLocalSTT(companion) } }
        observeInterruptions()
        startTicker()
        beginListening()
    }

    func end() {
        VoiceDiag.log("end")
        headphonesEnded()
        audio.pcmSink.set(nil)
        turnAudio.reset()
        live?.close()
        live = nil
        VoiceDiag.upload(companion)
        recognitionGeneration += 1
        stopRecognition()
        stopSpeaking()
        watchTask?.cancel()
        ticker?.cancel()
        recognitionRestart?.cancel()
        audio.stop()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        phase = .idle
        LiveActivityController.shared.voiceEnded()
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    /// Tap the orb: interrupt speech, end your turn early, or resume after pause.
    func tap() async {
        if let live {
            switch phase {
            case .error: await live.retry()
            case .paused: muted = false
            default: if live.tap() { Haptics.tap() } // tap to send
            }
            return
        }
        switch phase {
        case .speaking:
            bargeIn(manual: true)
        case .listening:
            if heard.trimmingCharacters(in: .whitespaces).isEmpty { return }
            finishTurn()
        case .paused, .error:
            muted = false
            if !audio.isRunning {
                do { try audio.start() } catch { phase = .error("Couldn't start the microphone."); return }
                if ticker == nil { startTicker() }
            }
            beginListening()
        case .thinking, .idle:
            break
        }
    }

    // MARK: Local speech-to-text (Parakeet on the Mac)

    private func enableLocalSTT(_ companion: CompanionClient) async {
        guard let s = try? await companion.localVoiceStatus(), s.available else {
            VoiceDiag.log("local STT unavailable; Apple's recognizer only")
            return
        }
        guard live == nil, phase != .idle else { return }
        localSTT = true
        audio.pcmSink.set { [turnEncoder] buf in turnEncoder.append(buf) }
        VoiceDiag.log("local STT on: \(s.sttModel ?? "?")")
    }

    // MARK: Gemini Live

    /// Gemini Live owns the conversation; false (no key on the Mac, old relay, offline) → classic.
    private func startLive(_ companion: CompanionClient, engine: VoiceEngine) async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .error("Allow Microphone for Otto in Settings.")
            return true
        }
        Speaker.shared.stop()
        configureAudioSession()
        let live = GeminiLive(host: self, chat: chat, companion: companion, audio: audio, engine: engine)
        audio.onInput = { [weak self] db, duration in self?.live?.micLevel(db: db, duration: duration) }
        audio.onOutputLevel = { [weak self] lvl in self?.live?.outputLevel(lvl) }
        audio.onBufferPlayed = nil
        audio.onRestart = nil
        do { try audio.start() } catch {
            VoiceDiag.log("gemini: audio.start failed: \(error)")
            return false
        }
        self.live = live
        guard await live.connect() else {
            VoiceDiag.log("gemini: unavailable; using the classic voice pipeline")
            self.live = nil
            audio.stop()
            return false
        }
        engineName = engine.label
        VoiceDiag.log("gemini: live \(audio.describe())")
        observeInterruptions()
        phase = .listening
        Haptics.tap()
        return true
    }

    // MARK: Listening

    private func beginListening() {
        guard !muted else { phase = .paused; return }
        turnStartedAt = Date().addingTimeInterval(-0.3)
        echoContext = ""
        committedHeard = ""
        heard = ""
        firstWordsAt = nil
        farFieldChanges = 0
        startRecognition()
        phase = .listening
        Haptics.tap()
    }

    private func startRecognition() {
        stopRecognition()
        guard !muted, let recognizer else { return }
        lastRecognitionStart = Date()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On-device: faster partial results, no server time limit, works off-network.
        if recognizer.supportsOnDeviceRecognition, !onDeviceFailed { request.requiresOnDeviceRecognition = true }
        self.request = request
        monitorHeard = ""
        // Mid-turn (a recognizer segment closed on a pause): keep the endpointing clock running.
        if !(phase == .listening && !committedHeard.isEmpty) {
            stableUpdates = 0
            heardChangedAt = Date()
            voicedRun.reset()
        }
        recognitionGeneration += 1
        let gen = recognitionGeneration
        audio.feed(request)
        task = Self.recognize(recognizer, request: request) { [weak self] text, isFinal, failed in
            Task { @MainActor in self?.recognized(text: text, isFinal: isFinal, failed: failed, generation: gen) }
        }
    }

    private func stopRecognition() {
        audio.feed(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Recognition ended on its own (silence timeout, error): start a new one shortly.
    private var quickFailures = 0
    /// On-device recognition failed to initialise (error 300 / 1101): use Apple's server recognizer.
    private var onDeviceFailed = false
    private var lastRecognitionStart = Date.distantPast

    private func restartRecognitionSoon() {
        recognitionRestart?.cancel()
        // A recognizer that fails straight away (engine down, no audio) mustn't spin: back off.
        quickFailures = Date().timeIntervalSince(lastRecognitionStart) < 1.5 ? quickFailures + 1 : 0
        let delay = min(250 * (1 << min(quickFailures, 4)), 3000)
        recognitionRestart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, !self.muted else { return }
            switch self.phase {
            case .listening, .thinking, .speaking: self.startRecognition()
            default: break
            }
        }
    }

    private func recognized(text: String?, isFinal: Bool, failed: Bool, generation gen: Int) {
        guard gen == recognitionGeneration else { return }
        if failed, text == nil, request?.requiresOnDeviceRecognition == true,
           Date().timeIntervalSince(lastRecognitionStart) < 1.0, !onDeviceFailed {
            onDeviceFailed = true
            VoiceDiag.log("on-device recognition failed at start; switching to server recognition")
        }
        if isFinal || failed || recognizedCount % 10 == 0 {
            VoiceDiag.log("recognized[\(phase)] final=\(isFinal) failed=\(failed) text=\"\((text ?? "nil").prefix(80))\"")
        }
        recognizedCount += 1
        switch phase {
        case .listening:
            if let text, !text.isEmpty {
                let part = echoContext.isEmpty ? text : VoiceLogic.stripEcho(heard: text, playing: echoContext)
                let mine = committedHeard.isEmpty ? part : committedHeard + " " + part
                if mine != heard {
                    let first = heard.trimmingCharacters(in: .whitespaces).isEmpty
                    heard = mine
                    if first { firstWordsAt = Date() }
                    if VoiceLogic.countsAsTalking(firstWords: first, sinceVoice: Date().timeIntervalSince(lastVoiceAt),
                                                  floor: noise.floor) {
                        heardChangedAt = Date()
                        stableUpdates = 0
                    } else {
                        // New words with no near-field voice: someone else talking nearby.
                        farFieldChanges += 1
                        if farFieldChanges == 1 || farFieldChanges % 10 == 0 {
                            VoiceDiag.log("far-field words ignored x\(farFieldChanges) floor=\(noise.describe())")
                        }
                    }
                } else {
                    stableUpdates += 1
                }
            }
            if isFinal || (failed && text == nil) {
                if heard.trimmingCharacters(in: .whitespaces).isEmpty {
                    restartRecognitionSoon()   // timed out on silence: keep listening
                } else {
                    // The recognizer closed its segment on a pause. That isn't the end of your turn:
                    // keep the words, listen on, and let endpointing decide.
                    committedHeard = heard
                    echoContext = ""
                    restartRecognitionSoon()
                }
            }
        case .thinking, .speaking:
            if let text { monitorHeard = text }
            checkBargeIn()
            if isFinal || failed { restartRecognitionSoon() }
        default:
            break
        }
    }

    /// Every mic buffer: learn the room, track voice, drive the orb, watch for barge-in.
    private func heardAudio(db: Float, duration: TimeInterval) {
        guard !muted else { return }
        audioBuffersSeen += 1
        if audioBuffersSeen == 1 || audioBuffersSeen % 200 == 0 {
            VoiceDiag.log("mic buffers=\(audioBuffersSeen) db=\(Int(db)) floor=\(noise.describe()) phase=\(phase) playing=\(audio.isPlaying)")
        }
        let playing = audio.isPlaying
        let voice = noise.observe(db, playing: playing, duration: duration)
        voicedRun.add(isVoice: voice, duration: duration)
        if voice { lastVoiceAt = Date() }
        if phase == .listening {
            level = level * 0.6 + max(0, min(1, (db + 50) / 40)) * 0.4
        } else if phase == .thinking || phase == .speaking, voice {
            checkBargeIn()
        }
    }

    private func checkBargeIn() {
        guard !muted, phase == .thinking || phase == .speaking else { return }
        if phase == .thinking, !audio.isPlaying {
            // Otto is only working, not talking: you speaking isn't an interruption. Collect your turn;
            // whatever Otto answers meanwhile is kept and spoken after it.
            if VoiceLogic.shouldBargeIn(voiced: voicedRun.voiced, heard: monitorHeard, playing: "", audioPlaying: false) {
                userStartedTalking()
            }
            return
        }
        // Without echo cancellation the mic hears Otto itself: only tapping interrupts.
        guard audio.fullDuplex else { return }
        let playing = recentlySpoken.suffix(2).joined(separator: " ")
        if VoiceLogic.shouldBargeIn(voiced: voicedRun.voiced, heard: monitorHeard, playing: playing,
                                    audioPlaying: audio.isPlaying || phase == .speaking) {
            bargeIn(manual: false)
        }
    }

    /// You started talking while Otto was thinking (nothing playing). Nothing is stopped or dropped.
    private func userStartedTalking() {
        VoiceDiag.log("talking while thinking: \"\(monitorHeard.prefix(60))\" voiced=\(voicedRun.voiced) (reply kept)")
        echoContext = ""
        committedHeard = ""
        heard = monitorHeard
        firstWordsAt = Date()
        farFieldChanges = 0
        // Voice is detected ~1 s after you start: take the audio from a bit before.
        turnStartedAt = Date().addingTimeInterval(-1.5)
        heardChangedAt = Date()
        stableUpdates = 0
        phase = .listening
    }

    private var hasUnspoken: Bool { !pendingTexts.isEmpty || !inflight.isEmpty }

    /// You talked over Otto (or tapped): stop now, drop the queue, and listen to you.
    private func bargeIn(manual: Bool) {
        VoiceDiag.log("barge-in manual=\(manual) monitorHeard=\"\(monitorHeard.prefix(60))\" voiced=\(voicedRun.voiced)")
        let playing = recentlySpoken.suffix(2).joined(separator: " ")
        stopSpeaking()
        skipRestOfReply()
        bargeIns += 1
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
        if manual {
            beginListening()
            return
        }
        // Keep the running recognition: it already has your first words.
        turnStartedAt = Date().addingTimeInterval(-1.5)
        committedHeard = ""
        echoContext = playing
        heard = VoiceLogic.stripEcho(heard: monitorHeard, playing: playing)
        firstWordsAt = Date()
        farFieldChanges = 0
        heardChangedAt = Date()
        stableUpdates = 0
        phase = .listening
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if self.phase == .listening, !self.muted {
                    let now = Date()
                    if let reason = VoiceLogic.endTurnReason(
                        transcript: self.heard, stableUpdates: self.stableUpdates,
                        sinceWords: now.timeIntervalSince(self.heardChangedAt),
                        sinceVoice: now.timeIntervalSince(self.lastVoiceAt),
                        turnAge: self.firstWordsAt.map { now.timeIntervalSince($0) } ?? 0) {
                        if !self.refining { VoiceDiag.log("end of turn (\(reason)) floor=\(self.noise.describe()) farField=\(self.farFieldChanges)") }
                        self.finishTurn()
                    } else if self.heard.trimmingCharacters(in: .whitespaces).isEmpty, self.watchTask == nil,
                              self.chat.isRunning, !self.stoppingRun {
                        // A turn started outside the voice loop (a steer the agent never got, replayed
                        // as a new turn; a queued message): follow it and speak its answer.
                        VoiceDiag.log("following a run started outside voice mode")
                        self.phase = .thinking
                        self.resetReply(keepUnspoken: true)
                        self.pump()
                        self.watchReply(after: nil)
                    } else if self.heard.trimmingCharacters(in: .whitespaces).isEmpty, self.hasUnspoken,
                              now.timeIntervalSince(self.listeningSince) > 1.5, now.timeIntervalSince(self.lastVoiceAt) > 1.5 {
                        // Listening picked up nothing after all, and a reply is waiting: say it.
                        VoiceDiag.log("nothing said; speaking the waiting reply")
                        self.phase = .thinking
                        self.pump()
                    }
                }
                if !self.chat.isRunning { self.stoppingRun = false }
                self.pushLiveActivity(force: false)
                self.audioWatchdog()
            }
        }
    }

    private var lastWatchdog = Date.distantPast

    /// The engine can stop on its own (route change, voice processing reconfiguring, Siri): bring it back.
    private func audioWatchdog() {
        guard !muted, !previewOnly else { return }
        switch phase {
        case .listening, .thinking, .speaking: break
        default: return
        }
        guard !audio.isRunning, Date().timeIntervalSince(lastWatchdog) > 1 else { return }
        lastWatchdog = Date()
        VoiceDiag.log("watchdog: engine stopped, rebuilding")
        configureAudioSession()
        if audio.recover() { VoiceDiag.log("watchdog: running again \(audio.describe())") }
    }

    @ObservationIgnored private var refining = false

    private func finishTurn() {
        guard phase == .listening, !refining else { return }
        let quick = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quick.isEmpty else { return }
        // Stop words act at once; everything else gets Parakeet's transcript when the Mac has it.
        guard localSTT, !VoiceLogic.isStopCommand(quick) else { return finishTurn(said: quick) }
        let pcm = turnAudio.slice(since: turnStartedAt)
        guard pcm.count >= 16_000 * 2 / 4, let companion else { return finishTurn(said: quick) }  // < 0.25 s
        let echo = echoContext
        committedHeard = ""
        stopRecognition()
        refining = true
        level = 0
        Task {
            let t0 = Date()
            var said = quick
            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await companion.localTranscribe(pcm16k: pcm) }
                    group.addTask { try await Task.sleep(for: .seconds(3)); throw CancellationError() }
                    defer { group.cancelAll() }
                    return try await group.next() ?? ""
                }
                let clean = (echo.isEmpty ? text : VoiceLogic.stripEcho(heard: text, playing: echo))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { said = clean }
                VoiceDiag.log(String(format: "parakeet %.2fs %dKB apple=\"%@\" parakeet=\"%@\"",
                                     Date().timeIntervalSince(t0), pcm.count / 1024, String(quick.prefix(80)), String(clean.prefix(80))))
            } catch {
                VoiceDiag.log("parakeet failed (\(error)); using Apple's transcript")
            }
            refining = false
            guard phase == .listening else { return }  // ended / muted meanwhile
            heard = said
            finishTurn(said: said)
        }
    }

    private func finishTurn(said: String) {
        playCue(.sent)
        committedHeard = ""
        if let command = VoiceLogic.voiceCommand(said), onCommand != nil {
            VoiceDiag.log("finishTurn command=\(command) said=\"\(said.prefix(80))\"")
            heard = said
            startRecognition()
            runCommand(command)
            return
        }
        let action = VoiceLogic.turnAction(utterance: said, runActive: chat.isRunning)
        VoiceDiag.log("finishTurn action=\(action) said=\"\(said.prefix(80))\" runActive=\(chat.isRunning) unspoken=\(pendingTexts.count + inflight.count)")
        heard = said
        // Fresh recognition for the next phase (monitoring for barge-in), without your last words.
        startRecognition()
        switch action {
        case .dismiss:
            stopSpeaking()
            pendingTexts = []
            beginListening()
        case .stopRun:
            stopSpeaking()
            pendingTexts = []
            watchTask?.cancel()
            watchTask = nil
            stoppingRun = true
            Haptics.send()
            Task { await chat.stop() }
            beginListening()
        case .steer:
            phase = .thinking
            level = 0
            replyDone = false
            Haptics.send()
            pump()
            Task {
                await chat.send(OutgoingMessage(text: said, voice: true))
                if watchTask == nil { watchReply(after: lastAssistant()?.id) }
            }
        case .send:
            // The previous run may have just ended: take the rest of its reply before moving on.
            if watchTask != nil, let reply = lastAssistant(), reply.id != watchAfterID {
                feed(reply.id, reply.text, final: true)
            }
            watchTask?.cancel()
            watchTask = nil
            // An answer that arrived while you were talking is still spoken (before the next one).
            let keep = hasUnspoken
            if keep { VoiceDiag.log("keeping \(pendingTexts.count + inflight.count) unspoken chunk(s) of the last reply") }
            phase = .thinking
            level = 0
            if !keep { spoken = "" }
            resetReply(keepUnspoken: keep)
            pump()
            Haptics.send()
            let before = lastAssistant()?.id
            Task {
                await chat.send(OutgoingMessage(text: said, voice: true))
                watchReply(after: before)
            }
        }
    }

    // MARK: Reply → speech

    private func resetReply(keepUnspoken: Bool = false) {
        if !keepUnspoken {
            stopSpeaking()
            pendingTexts = []
            recentlySpoken = []
        }
        replyID = nil
        replyText = ""
        spokenUpTo = 0
        firstChunk = true
        replyDone = false
        skipCurrentReply = false
        queuedChunks = []
    }

    /// "Switch your model to haiku", "new chat": run it on the phone and say what happened.
    private func runCommand(_ command: String) {
        Haptics.send()
        let runActive = chat.isRunning || watchTask != nil
        phase = .thinking
        level = 0
        Task {
            let result = await onCommand?(command) ?? VoiceCommandResult(reply: "I can't do that from voice mode.")
            VoiceDiag.log("command \(command) -> \"\(result.reply)\"")
            afterSpeech = result.then
            if !runActive {
                resetReply(keepUnspoken: hasUnspoken)
                replyDone = true
            }
            if phase == .listening { phase = .thinking }
            pendingTexts.append(result.reply)
            pump()
        }
    }

    /// Follows the streaming reply and speaks each finished sentence.
    private var watchAfterID: String?

    private func watchReply(after previousID: String?) {
        watchTask?.cancel()
        watchAfterID = previousID
        watchTask = Task { [weak self] in
            var sawRun = false
            let started = Date()
            while !Task.isCancelled {
                guard let self else { return }
                if self.chat.isRunning { sawRun = true }
                if !sawRun, Date().timeIntervalSince(started) > 20 {
                    // Never started (offline / Tailscale off): the message waits in the outbox.
                    VoiceDiag.log("watchReply: run never started (error=\(self.chat.errorMessage ?? "nil"))")
                    self.enqueue("I couldn't reach your agent. Check your connection and try again.")
                    self.replyDone = true
                    self.watchTask = nil
                    self.checkDone()
                    return
                }
                if let reply = self.lastAssistant(), reply.id != previousID {
                    self.feed(reply.id, reply.text, final: !reply.streaming && !self.chat.isRunning)
                }
                if sawRun || self.chat.errorMessage != nil, !self.chat.isRunning {
                    VoiceDiag.log("watchReply: run ended replyID=\(self.replyID ?? "nil") error=\(self.chat.errorMessage ?? "nil")")
                    if self.lastAssistant()?.id == previousID, self.replyID == nil {
                        // Finished without a new reply (error or interrupted).
                        self.enqueue("Sorry, that didn't go through.")
                    }
                    self.replyDone = true
                    self.watchTask = nil
                    self.checkDone()
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func lastAssistant() -> (id: String, text: String, streaming: Bool)? {
        // Delivered transcript only: an undelivered message stuck in the outbox mustn't hide every
        // later reply (it did: "Sorry, that didn't go through" while the answer was on screen).
        for item in chat.transcript.items.reversed() {
            if case .assistant(let id, let text, let streaming) = item { return (id, text, streaming) }
            if case .user = item { return nil }
        }
        return nil
    }

    private func feed(_ id: String, _ text: String, final: Bool) {
        let clean = SpeechText.clean(text)
        if id != replyID {
            if let old = replyID, let carried = VoiceLogic.carriedOffset(old: replyText, spokenUpTo: spokenUpTo, new: clean) {
                // Same reply under a new id (the stored copy replaced the streamed one at run end):
                // keep what's already queued — every sentence is spoken once.
                VoiceDiag.log("reply \(old) is now \(id): \(carried)/\(clean.count) chars already queued")
                spokenUpTo = carried
            } else {
                // A new reply message (e.g. after a steer). First say the end of the previous one, which
                // was waiting for its sentence to finish ("Two plus two is four." had no space after it).
                if replyID != nil, !skipCurrentReply, replyText.count > spokenUpTo {
                    let (rest, _) = VoiceLogic.nextChunk(String(replyText.dropFirst(spokenUpTo)), flush: true, isFirst: false)
                    queueChunk(rest)
                }
                if replyID != nil { skipCurrentReply = false }
                spokenUpTo = 0
                firstChunk = true
            }
            replyID = id
        }
        replyText = clean
        if skipCurrentReply { spokenUpTo = max(spokenUpTo, clean.count); return }
        if spokenUpTo > clean.count { spokenUpTo = clean.count }
        while clean.count > spokenUpTo {
            let rest = String(clean.dropFirst(spokenUpTo))
            let (ready, consumed) = VoiceLogic.nextChunk(rest, flush: final, isFirst: firstChunk)
            guard consumed > 0 else { return }
            spokenUpTo += consumed
            firstChunk = false
            queueChunk(ready)
        }
    }

    /// Queues one chunk of the reply for speech, unless the same words were already queued.
    private func queueChunk(_ text: String) {
        guard !text.isEmpty else { return }
        let key = VoiceLogic.normalizedWords(text).joined(separator: " ")
        if !key.isEmpty, queuedChunks.contains(key) {
            VoiceDiag.log("skip duplicate \"\(text.prefix(40))\"")
            return
        }
        queuedChunks.append(key)
        enqueue(text)
    }

    /// Barge-in: what the agent already wrote for this reply won't be spoken.
    private func skipRestOfReply() {
        pendingTexts = []
        if let reply = lastAssistant() {
            skipCurrentReply = true
            replyID = reply.id
            replyText = SpeechText.clean(reply.text)
            spokenUpTo = replyText.count
            firstChunk = false
        }
    }

    /// Splits off whole sentences (grouped so each request is a decent size). Kept for callers/tests.
    nonisolated static func completeSentences(_ s: String, flush: Bool) -> (String, Int) {
        VoiceLogic.nextChunk(s, flush: flush, isFirst: false)
    }

    private func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        VoiceDiag.log("enqueue \"\(text.prefix(60))\" phase=\(phase)")
        pendingTexts.append(text)
        pump()
    }

    private func pump() {
        // While you're talking (after a barge-in) nothing new starts playing.
        guard speakTask == nil, phase == .thinking || phase == .speaking else { return }
        guard !pendingTexts.isEmpty || !inflight.isEmpty else { checkDone(); return }
        speakTask = Task { [weak self] in
            await self?.runSpeaker()
            guard let self else { return }
            self.speakTask = nil
            self.checkDone()
        }
    }

    private func runSpeaker() async {
        while !Task.isCancelled {
            topUpPrefetch()
            guard !inflight.isEmpty else { return }
            let clip = inflight.removeFirst()
            playingClip = clip
            defer { playingClip = nil }
            topUpPrefetch()
            var next = 0
            var marked = false
            while !Task.isCancelled {
                while next < clip.buffers.count {
                    let wasIdle = !audio.isPlaying
                    let index = audio.schedule(clip.buffers[next])
                    if !marked {
                        marked = true
                        if phase == .thinking { phase = .speaking }
                        if wasIdle { showSpoken(clip.text) } else { captionMarks.append((index, clip.text)) }
                    }
                    next += 1
                }
                if clip.done { break }
                await clip.waitForChange()
            }
            clip.buffers.removeAll()
        }
    }

    /// Keeps the next two sentences downloading while one plays.
    private func topUpPrefetch() {
        while inflight.count < 2, !pendingTexts.isEmpty {
            let clip = AudioClip(text: pendingTexts.removeFirst())
            let seg = VoiceChoice.voice(for: clip.text, main: VoiceChoice.main, spanish: VoiceChoice.spanish,
                                        previousSpanish: lastSpanish)
            lastSpanish = seg.spanish
            clip.voice = seg.voice
            clip.spanish = seg.spanish
            clip.task = Task { [weak self] in
                await self?.fill(clip)
                clip.finish()
            }
            inflight.append(clip)
        }
    }

    private func showSpoken(_ text: String) {
        spoken = spoken.isEmpty ? text : spoken + " " + text
        recentlySpoken.append(text)
        if recentlySpoken.count > 4 { recentlySpoken.removeFirst() }
    }

    private func bufferPlayed(_ index: Int) {
        while let mark = captionMarks.first, mark.index <= index + 1 {
            captionMarks.removeFirst()
            showSpoken(mark.text)
        }
        if !audio.isPlaying { checkDone() }
    }

    /// The reply is finished and fully played: your turn.
    private func checkDone() {
        guard phase == .speaking || phase == .thinking else { return }
        guard replyDone, watchTask == nil, pendingTexts.isEmpty, inflight.isEmpty, speakTask == nil,
              !audio.isPlaying else { return }
        level = 0
        if let then = afterSpeech {
            afterSpeech = nil
            then()
            return
        }
        beginListening()
    }

    private func stopSpeaking() {
        speakTask?.cancel()
        speakTask = nil
        for clip in inflight { clip.cancel() }
        inflight = []
        playingClip?.cancel()
        playingClip = nil
        pendingTexts = []
        captionMarks = []
        audio.stopPlayback()
        level = 0
    }

    // MARK: Audio sources (stream → whole clip → iPhone voice)

    private func fill(_ clip: AudioClip) async {
        if useStream, useHermesVoice, let companion {
            let decoder = MP3StreamDecoder()
            var bytes = 0
            let t0 = Date()
            do {
                for try await chunk in companion.speakStream(clip.text, profile: profile, voice: clip.voice,
                                                             speed: VoiceChoice.speed) {
                    if Task.isCancelled || clip.cancelled { return }
                    bytes += chunk.count
                    clip.add(decoder.feed(chunk))
                }
                clip.add(decoder.finish())
                VoiceDiag.log(String(format: "stream ok bytes=%d buffers=%d %.2fs voice=%@", bytes, clip.buffers.count,
                                     Date().timeIntervalSince(t0), clip.voice ?? "default"))
            } catch {
                VoiceDiag.log("stream failed after \(bytes) bytes: \(error)")
                if Task.isCancelled || clip.cancelled { return }
                if !clip.hasAudio, Self.streamUnsupported(error) { useStream = false }
            }
            if clip.hasAudio { return }
        }
        if useHermesVoice, let companion, !clip.cancelled {
            if let data = try? await companion.speak(clip.text, profile: profile, voice: clip.voice,
                                                     speed: VoiceChoice.speed) {
                if clip.cancelled { return }
                let decoder = MP3StreamDecoder()
                clip.add(decoder.feed(data))
                clip.add(decoder.finish())
                if clip.hasAudio { return }
            } else if !Task.isCancelled, !clip.cancelled {
                useHermesVoice = false   // don't retry every sentence once it fails
            }
        }
        guard !clip.cancelled else { return }
        VoiceDiag.log("falling back to on-device voice")
        await synthesizeOnDevice(clip)
    }

    /// Old relay (404) or a Mac voice that isn't Edge (409): use the whole-clip route from now on.
    private static func streamUnsupported(_ error: Error) -> Bool {
        if case CompanionError.relayOutdated = error { return true }
        if case HermesError.http(let code, _) = error { return code == 409 || code == 405 }
        return false
    }

    /// The iPhone's own voice, rendered to buffers so it goes through the echo canceller too.
    private func synthesizeOnDevice(_ clip: AudioClip) async {
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: clip.text)
        u.voice = DeviceVoice.pick(spanish: clip.spanish)
        u.rate = DeviceVoice.rate(speed: VoiceChoice.speed)
        let reformat = PCMReformatter()
        let stream = AsyncStream<BufferBox> { continuation in
            Self.render(synth, u) { box in
                if let box { continuation.yield(box) } else { continuation.finish() }
            }
        }
        clip.keepAlive = synth
        for await box in stream {
            if clip.cancelled { synth.stopSpeaking(at: .immediate); return }
            if let pcm = reformat.convert(box.buffer) { clip.add([pcm]) }
        }
    }

    nonisolated private static func render(_ synth: AVSpeechSynthesizer, _ u: AVSpeechUtterance,
                                           _ out: @escaping @Sendable (BufferBox?) -> Void) {
        synth.write(u) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { out(nil); return }
            out(BufferBox(buffer: pcm))
        }
    }

    // MARK: Mute, interruptions, Live Activity

    private func applyMute() {
        if let live {
            live.setMuted(muted)
            level = 0
            pushLiveActivity(force: true)
            return
        }
        if muted {
            stopRecognition()
            recognitionGeneration += 1
            if phase == .listening { phase = .paused }
            level = 0
        } else if phase == .thinking || phase == .speaking {
            startRecognition()
        }
        pushLiveActivity(force: true)
    }

    private func audioRestarted() {
        VoiceDiag.log("audio restarted after config change: \(audio.describe())")
        // Route change (AirPods, car): the engine was rebuilt; restart recognition on the new input.
        noise = VoiceLogic.NoiseFloor()
        switch phase {
        case .listening, .thinking, .speaking: if !muted { startRecognition() }
        default: break
        }
    }

    private func observeInterruptions() {
#if os(iOS)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.interrupted(began: raw == AVAudioSession.InterruptionType.began.rawValue) }
        }
#endif
    }

    /// A phone call or Siri took the audio: pause; pick up where we were when it ends.
    private func interrupted(began: Bool) {
        VoiceDiag.log("audio session interruption began=\(began)")
        if let live {
            if began {
                audio.stopPlayback()
                live.setMuted(true)
            } else {
                configureAudioSession()
                if !audio.isRunning { try? audio.start() }
                live.setMuted(muted)
            }
            return
        }
        if began {
            stopSpeaking()
            stopRecognition()
            phase = .paused
        } else if phase == .paused, !muted {
            configureAudioSession()
            do { try audio.start() } catch { phase = .error("Couldn't restart the microphone."); return }
            beginListening()
        }
    }

    private func pushLiveActivity(force: Bool) {
        guard phase != .idle, !previewOnly else { return }
        if !force, Date().timeIntervalSince(lastActivityPush) < 1 { return }
        lastActivityPush = Date()
        let name: String
        let line: String
        switch phase {
        case .listening: name = "listening"; line = "Listening"
        case .thinking: name = "thinking"; line = chat.liveStatus ?? "Thinking"
        case .speaking: name = "speaking"; line = "Speaking"
        case .paused: name = "muted"; line = "Muted"
        case .error(let m): name = "muted"; line = m
        case .idle: return
        }
        LiveActivityController.shared.voiceUpdate(sessionID: chat.sessionID, title: chat.title ?? title,
                                                  phase: name, status: line)
    }

    // MARK: Audio session + permissions

    private func configureAudioSession() {
        audio.configureSession()
    }

    nonisolated private static func recognize(
        _ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let error { VoiceDiag.log("recognition error: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)") }
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    nonisolated private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

extension VoiceSession: GeminiLiveHost {
    func liveSetPhase(_ p: Phase) { if phase != p { phase = p } }
    func liveHeard(_ text: String) { heard = text }
    func liveSpoken(_ text: String) { spoken = text }
    func liveLevel(_ l: Float) { level = level * 0.5 + l * 0.5 }
    func liveBargeIn() { bargeIns += 1 }
    func liveTurnSent() { playCue(.sent) }
    func liveCommand(_ command: String) async -> VoiceCommandResult {
        await onCommand?(command) ?? VoiceCommandResult(reply: "I can't do that from voice mode.")
    }
}

/// What a spoken command did: the line Otto says, and what to do once it's said.
struct VoiceCommandResult {
    var reply: String
    var then: (() -> Void)? = nil
}

/// One sentence of the reply: audio buffers filled in as they're downloaded/decoded.
@MainActor
final class AudioClip {
    let text: String
    /// Edge voice for this sentence (nil = the profile's voice) and whether it's Spanish.
    var voice: String?
    var spanish = false
    var buffers: [AVAudioPCMBuffer] = []
    private(set) var done = false
    private(set) var cancelled = false
    private(set) var hasAudio = false
    var task: Task<Void, Never>?
    /// Keeps the on-device synthesizer alive while it renders.
    var keepAlive: AnyObject?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(text: String) { self.text = text }

    func add(_ new: [AVAudioPCMBuffer]) {
        guard !new.isEmpty, !cancelled else { return }
        buffers.append(contentsOf: new)
        hasAudio = true
        wake()
    }

    func finish() { done = true; wake() }

    func cancel() {
        cancelled = true
        task?.cancel()
        finish()
    }

    func waitForChange() async {
        if done { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wake() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }
}

/// Carries a PCM buffer from the speech synthesizer's thread to the main actor.
struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

// MARK: - Headphone button

extension VoiceSession {
    /// Your turn is open (something said, not sent yet).
    private var turnOpen: Bool {
        live?.userTurnOpen ?? !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// On when the session first starts listening, off when it ends.
    fileprivate func headphonesPhaseChanged(from old: Phase) {
        guard !previewOnly, old == .idle, phase == .listening, !headphones.isActive else { return }
        headphones.onGesture = { [weak self] gesture, source, event in self?.headphonePress(gesture, source: source, event: event) }
        headphones.onUnmute = { [weak self] in self?.audio.clearInputMute() }
        headphones.activate(title: chat.title ?? title)
        playCue(.listening)
    }

    fileprivate func headphonesEnded() {
        guard headphones.isActive else { return }
        headphones.deactivate()
        VoiceCue.playSystem(.ended)
    }

    /// A headphone press (or end gesture), routed like the orb.
    func headphonePress(_ gesture: HeadphoneGestures.Gesture, source: HeadphoneSource, event: String) {
        let open = turnOpen
        let action = HeadphoneGestures.action(for: gesture, phase: phase, turnOpen: open)
        VoiceDiag.log("headphones: \(event) source=\(source.rawValue) phase=\(phase) turnOpen=\(open) -> \(action)")
        switch action {
        case .send, .resume, .retry:
            Task { await tap() }   // the "sent" cue comes from the turn actually being sent
        case .interrupt:
            Task {
                await tap()
                playCue(.interrupted)
            }
        case .nothingToSend:
            playCue(.nothing)
        case .end:
            requestEnd()
        case .ignore:
            break
        }
    }

    /// Close voice mode the way Stop on the Live Activity does (the screen or the hands-free session
    /// that owns this session ends it), and end it here if nothing did.
    private func requestEnd() {
        if let stop = HandsFreeHooks.stop {
            Task { await stop() }
        } else {
            NotificationCenter.default.post(name: HandsFreeHooks.stopNotification, object: nil)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.phase != .idle else { return }
            VoiceDiag.log("headphones: nothing closed voice mode; ending here")
            self.end()
        }
    }

    fileprivate func playCue(_ cue: VoiceCue) {
        guard headphones.isActive, let buffer = cue.buffer() else { return }
        audio.playCue(buffer)
    }
}
