import AVFoundation
import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

/// A hands-free voice conversation on the wrist: one tap, then talk → Otto answers out loud → the mic
/// reopens (with a tap on the wrist) → talk again… until you go quiet for ~8 s, tap the orb, or say
/// "stop" / "bye". Goes through the iPhone when it's nearby (works with the phone locked in a pocket);
/// otherwise straight to the Mac if the watch can reach it. Replies play in AirPods when they're
/// connected to the watch, else on the watch speaker.
@MainActor
@Observable
final class WatchModel: NSObject {
    enum Phase: Equatable {
        case idle, recording, sending, thinking, speaking
        case error(String)

        var loop: WatchTalkLoop.Phase {
            switch self {
            case .idle: .idle
            case .recording: .listening
            case .sending: .sending
            case .thinking: .thinking
            case .speaking: .speaking
            case .error: .error
            }
        }
    }

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var said: String
        var reply: String?
    }

    private(set) var phase: Phase = .idle
    private(set) var turns: [Turn] = []
    private(set) var level: Float = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var liveStatus: String?
    /// A hands-free conversation is running (the mic reopens after each reply).
    private(set) var handsFree = false
    /// Why the last conversation ended, for the line under the orb.
    private(set) var endedLine: String?
    /// Replies are playing in AirPods (or other Bluetooth headphones) rather than the watch speaker.
    private(set) var onHeadphones = false
    var speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") }
    }
    var hasConversation: Bool { sessionID != nil }
    var currentSessionID: String? { sessionID }

    private var sessionID: String? = UserDefaults.standard.string(forKey: "watchSession").flatMap { $0.isEmpty ? nil : $0 }
    private var runID: String?
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var playDone: CheckedContinuation<Void, Never>?
    private var stopSpeech = false
    private var meter = WatchTalkLoop.Meter()
    /// The reply in flight is the last one: don't listen again after it.
    private var endAfterReply = false
    /// "Didn't catch that" in a row.
    private var misses = 0
    /// Long-form (Bluetooth) playback: nil = not tried this conversation, false = no headphones.
    private var longFormOK: Bool?
    private var recordURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("hermes-turn.m4a") }

    static let shared = WatchModel()

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        synth.delegate = self
        limits = SharedVault.limits()
    }

    // MARK: Actions

    /// The orb (and the "Talk to Otto" complication): start, interrupt a reply, or end the conversation.
    func primaryTap() async {
        switch WatchTalkLoop.tapAction(phase: phase.loop, looping: handsFree, heardVoice: meter.heardVoice) {
        case .start: await startConversation()
        case .interrupt: await startTalking()   // talk over the reply: it stops and the mic opens
        case .sendAndEnd:
            endAfterReply = true
            finishRecording(manual: true)
        case .end: endConversation(.tap)
        case .endAfterReply:
            endAfterReply = true
            WKInterfaceDevice.current().play(.click)
        }
    }

    /// One tap → a hands-free conversation.
    func startConversation() async {
        handsFree = true
        endAfterReply = false
        misses = 0
        longFormOK = nil
        endedLine = nil
        await startTalking()
    }

    /// Ends the hands-free loop: stops listening or speaking now. If Otto is still working, its answer
    /// still arrives (and is spoken), but the mic doesn't reopen.
    func endConversation(_ reason: WatchTalkLoop.EndReason) {
        let wasLooping = handsFree
        handsFree = false
        endAfterReply = false
        if phase == .recording {
            meterTask?.cancel()
            recorder?.stop()
            recorder = nil
            level = 0
        }
        if phase == .speaking { stopSpeaking() }
        if phase == .recording || phase == .speaking || phase == .idle { phase = .idle }
        endedLine = WatchTalkLoop.endLine(reason)
        if wasLooping { WKInterfaceDevice.current().play(.stop) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func newConversation() {
        endConversation(.tap)
        stopSpeaking()
        pollTask?.cancel()
        sessionID = nil
        UserDefaults.standard.removeObject(forKey: "watchSession")
        UserDefaults.standard.removeObject(forKey: "watchTitle")
        title = nil
        turns = []
        endedLine = nil
        phase = .idle
        WKInterfaceDevice.current().play(.click)
    }

    func cancel() async {
        if let runID { await send([WatchWire.op: WatchWire.stop, "run": runID]) }
        pollTask?.cancel()
        stopSpeaking()
        handsFree = false
        phase = .idle
    }

    /// A tapped answer (the Yes / No buttons) skips the recorder; voice only otherwise.
    func ask(text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        stopSpeaking()
        turns.append(Turn(said: t))
        phase = .sending
        await submit([WatchWire.op: WatchWire.ask, "text": t])
    }

    // MARK: Recording

    func startTalking() async {
        stopSpeaking()
        endedLine = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            handsFree = false
            fail("Allow the microphone for Otto in Settings → Privacy & Security on your watch.")
            return
        }
        do { try Self.prepareRecording() } catch {
            handsFree = false
            fail("The microphone is busy.")
            return
        }
        // Small mono AAC: ~2 KB per second, so a long question still fits in one message to the phone.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 16_000,
        ]
        guard let r = try? AVAudioRecorder(url: recordURL, settings: settings) else {
            handsFree = false
            fail("Couldn't start recording.")
            return
        }
        r.isMeteringEnabled = true
        r.record(forDuration: WatchTalkLoop.maxTurn + 1)
        recorder = r
        meter = WatchTalkLoop.Meter()
        elapsed = 0
        phase = .recording
        WKInterfaceDevice.current().play(.start)
        let started = Date()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                guard let r = self.recorder, r.isRecording else {
                    if self.phase == .recording { self.finishRecording(manual: false) }
                    return
                }
                r.updateMeters()
                // Wall-clock time: the recorder's own clock can stall (no input) and must not keep the mic open.
                self.track(db: r.averagePower(forChannel: 0), at: Date().timeIntervalSince(started))
            }
        }
    }

    private func track(db: Float, at t: TimeInterval) {
        elapsed = t
        let decision = meter.feed(db: db, at: t)
        level = meter.level
        switch decision {
        case .keepListening: break
        case .endTurn: finishRecording(manual: false)
        case .noSpeech:
            // Said nothing after the mic reopened: the conversation is over.
            if handsFree { endConversation(.silence) } else { finishRecording(manual: false) }
        }
    }

    func finishRecording(manual: Bool) {
        guard phase == .recording, let r = recorder else { return }
        meterTask?.cancel()
        let duration = r.currentTime
        r.stop()
        recorder = nil
        level = 0
        WKInterfaceDevice.current().play(.click)
        let audio = (try? Data(contentsOf: recordURL)) ?? Data()
        // A tap always sends what was recorded; only a silent auto-stop is dropped.
        let worthSending = audio.count > 800 && (manual ? duration > 0.6 : meter.heardVoice)
        guard worthSending else {
            if handsFree { endConversation(.silence); return }
            fail(manual ? "That was too short. Tap, talk, then tap again." : "I didn't hear anything.")
            return
        }
        turns.append(Turn(said: "…"))
        phase = .sending
        Task { await submit([WatchWire.op: WatchWire.ask, "audio": audio, "loop": handsFree]) }
    }

    // MARK: Talking to Hermes

    private func submit(_ message: [String: Any]) async {
        var msg = message
        if let sessionID { msg["session"] = sessionID }
        let r = await send(msg, timeout: 45)
        if r["ended"] as? Bool == true {
            // "Stop" / "bye": no run was started.
            dropPendingTurn()
            phase = .idle
            endConversation(.goodbye)
            return
        }
        if let e = r["error"] as? String {
            dropPendingTurn()
            // Mumbled or too far from the mic: listen again rather than drop the conversation.
            if handsFree, e.hasPrefix("I didn't catch") || e.hasPrefix("Didn't catch") {
                misses += 1
                if misses <= WatchTalkLoop.maxMisses { phase = .idle; await startTalking(); return }
                phase = .idle
                endConversation(.misses)
                return
            }
            handsFree = false
            fail(e)
            return
        }
        guard let sid = r["session"] as? String, let run = r["run"] as? String, !run.isEmpty else {
            dropPendingTurn()
            handsFree = false
            fail("Otto didn't answer. Is your iPhone nearby?")
            return
        }
        misses = 0
        if let said = r["transcript"] as? String, !said.isEmpty, !turns.isEmpty { turns[turns.count - 1].said = said }
        sessionID = sid
        UserDefaults.standard.set(sid, forKey: "watchSession")
        runID = run
        liveStatus = nil
        phase = .thinking
        publish(.working, "Thinking…")
        poll(run: run)
    }

    private func dropPendingTurn() {
        if turns.last?.reply == nil, !turns.isEmpty { turns.removeLast() }
    }

    private func poll(run: String) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let started = Date()
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self else { return }
                let r = await self.send([WatchWire.op: WatchWire.status, "run": run])
                if r["error"] != nil {
                    misses += 1
                    if misses >= 8 { self.handsFree = false; self.fail("Lost touch with Otto. The answer will be in the app on your iPhone."); return }
                    continue
                }
                misses = 0
                if let ev = r["event"] as? String, let line = WatchText.status(ev), line != self.liveStatus {
                    self.liveStatus = line
                    self.publish(ev.contains("approval") ? .needsYou : .working, line)
                }
                let status = r["status"] as? String ?? "running"
                if ["completed", "failed", "cancelled", "interrupted"].contains(status) {
                    let out = (r["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if status != "completed" || out.isEmpty || out == "[SILENT]" {
                        self.handsFree = false
                        self.fail(status == "cancelled" ? "Stopped." : "That didn't finish. Try again.")
                    } else {
                        await self.deliver(out)
                    }
                    return
                }
                if Date().timeIntervalSince(started) > 600 { self.handsFree = false; self.fail("Still working. Check your iPhone."); return }
            }
        }
    }

    private func deliver(_ text: String) async {
        let plain = WatchText.plain(text)
        if !turns.isEmpty { turns[turns.count - 1].reply = plain }
        runID = nil
        liveStatus = nil
        publish(.done, WatchSnippet.firstLine(text))
        WKInterfaceDevice.current().play(.success)
        var interrupted = false
        if speakReplies {
            phase = .speaking
            stopSpeech = false
            await preparePlayback()
            // A sentence or two at a time: each clip stays small enough to pass through the phone,
            // and speech starts sooner than waiting for the whole answer to be voiced.
            for sentence in WatchText.sentences(plain) where !stopSpeech {
                await speak(sentence)
            }
            // Tapped over the reply (the mic is opening) or the conversation was ended.
            interrupted = stopSpeech
        }
        guard !interrupted else { return }
        phase = .idle
        if WatchTalkLoop.reopensMic(looping: handsFree, endAfterReply: endAfterReply, interrupted: false) {
            await startTalking()   // the start haptic says "your turn"
        } else if handsFree {
            endConversation(.tap)
        }
    }

    private func speak(_ text: String) async {
        let r = await send([WatchWire.op: WatchWire.speak, "text": text], timeout: 20)
        if stopSpeech { return }
        if let audio = r["audio"] as? Data, let p = try? AVAudioPlayer(data: audio) {
            player = p
            p.delegate = self
            await withCheckedContinuation { c in
                playDone = c
                if !p.play() { finishPlayback() }
            }
        } else {
            // The watch's own voice when Hermes's voice can't be fetched.
            await withCheckedContinuation { c in
                playDone = c
                let u = AVSpeechUtterance(string: text)
                u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
                synth.speak(u)
            }
        }
    }

    private func stopSpeaking() {
        stopSpeech = true
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        finishPlayback()
    }

    fileprivate func finishPlayback() {
        let c = playDone
        playDone = nil
        c?.resume()
    }

    private func fail(_ message: String) {
        if phase == .thinking || phase == .sending { publish(.failed, "Didn't finish") }
        phase = .error(message)
        runID = nil
        liveStatus = nil
        WKInterfaceDevice.current().play(.failure)
    }

    // MARK: Audio route (AirPods when connected to the watch, else the watch speaker)

    /// The mic: AirPods' mic on watchOS 11+ when they're connected, else the watch's own.
    private static func prepareRecording() throws {
        let session = AVAudioSession.sharedInstance()
        if #available(watchOS 11.0, *) {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.duckOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
        } else {
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        }
        try session.setActive(true)
    }

    private static var routeIsBluetooth: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { WatchTalkLoop.isBluetooth(port: $0.portType.rawValue) }
    }

    /// Replies: stay on a Bluetooth route if the mic session already has one (watchOS 11+); otherwise
    /// ask watchOS for long-form audio, which plays in the connected AirPods. If there are none (or the
    /// route picker is dismissed) the watch speaker is used for the rest of this conversation.
    private func preparePlayback() async {
        if Self.routeIsBluetooth { onHeadphones = true; return }
        let session = AVAudioSession.sharedInstance()
        if longFormOK != false {
            do {
                try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
                let ok = try await session.activate(options: [])
                longFormOK = ok && Self.routeIsBluetooth
            } catch {
                longFormOK = false
            }
            if longFormOK == true { onHeadphones = true; return }
        }
        onHeadphones = false
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .default, options: [])
        try? session.setActive(true)
    }

    // MARK: Recent chats

    private(set) var chats: [HermesLite.ChatRow] = []
    private(set) var chatsLoading = false
    private(set) var title: String? = UserDefaults.standard.string(forKey: "watchTitle")

    func loadChats() async {
        chatsLoading = true
        defer { chatsLoading = false }
        let r = await send([WatchWire.op: WatchWire.chats], timeout: 20)
        if let d = r["chats"] as? Data, let rows = try? JSONDecoder().decode([HermesLite.ChatRow].self, from: d) {
            chats = rows
        }
    }

    /// Make a chat from any device the conversation on the watch: show its last exchange, reply by voice.
    func open(_ chat: HermesLite.ChatRow) async {
        stopSpeaking()
        pollTask?.cancel()
        sessionID = chat.id
        title = chat.title
        UserDefaults.standard.set(chat.id, forKey: "watchSession")
        UserDefaults.standard.set(chat.title, forKey: "watchTitle")
        turns = [Turn(said: "…", reply: nil)]
        phase = .sending
        let r = await send([WatchWire.op: WatchWire.chat, "session": chat.id], timeout: 20)
        phase = .idle
        guard let d = r["exchange"] as? Data, let ex = try? JSONDecoder().decode(HermesLite.Exchange.self, from: d) else {
            turns = []
            fail("Couldn't open that chat.")
            return
        }
        turns = [Turn(said: ex.asked.map { WatchSnippet.firstLine($0, max: 90) } ?? "…",
                      reply: ex.answer.map(WatchText.plain))]
        if ex.asked == nil && ex.answer == nil { turns = [] }
    }

    /// Hear one answer in full (Hermes's voice), whether or not replies are spoken automatically.
    func readAloud(_ turn: Turn) async {
        guard let reply = turn.reply else { return }
        stopSpeaking()
        phase = .speaking
        stopSpeech = false
        await preparePlayback()
        for sentence in WatchText.sentences(reply) where !stopSpeech { await speak(sentence) }
        if phase == .speaking { phase = .idle }
    }

    // MARK: Scheduled jobs (run from the wrist; output goes wherever the job delivers it)

    private(set) var jobs: [JobLite] = []
    private(set) var jobsLoading = false
    private(set) var jobsError: String?
    /// job id → "Running…", "Done · sent to Telegram", "Failed: …"
    private(set) var jobNotes: [String: String] = [:]
    private var kicks: [String: JobKick] = [:]
    private var jobPoll: Task<Void, Never>?

    func loadJobs() async {
        jobsLoading = true
        defer { jobsLoading = false }
        let r = await send([WatchWire.op: WatchWire.jobs], timeout: 25)
        if let d = r["jobs"] as? Data, let list = try? JSONDecoder().decode([JobLite].self, from: d) {
            jobs = list
            jobsError = nil
            settleKicks()
        } else if jobs.isEmpty {
            jobsError = (r["error"] as? String) ?? "Couldn't load your jobs."
        }
    }

    func isRunning(_ job: JobLite) -> Bool { kicks[job.id] != nil }

    func run(_ job: JobLite) async {
        guard kicks[job.id] == nil, let data = try? JSONEncoder().encode(job) else { return }
        jobNotes[job.id] = "Starting…"
        let r = await send([WatchWire.op: WatchWire.runJob, "job": data], timeout: 25)
        if let e = r["error"] as? String {
            jobNotes[job.id] = "Couldn't start: \(e)"
            WKInterfaceDevice.current().play(.failure)
            return
        }
        WKInterfaceDevice.current().play(.start)
        kicks[job.id] = JobKick(jobID: job.id, at: Date(), previousLastRun: job.lastRunAt)
        jobNotes[job.id] = "Running · output to \(job.deliveryLabel)"
        pollJobs()
    }

    /// Check the job list every few seconds until every started job has a new last run.
    private func pollJobs() {
        guard jobPoll == nil else { return }
        jobPoll = Task { [weak self] in
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard let self else { return }
                await self.loadJobs()
                if self.kicks.isEmpty || Date().timeIntervalSince(started) > 20 * 60 { break }
            }
            self?.jobPoll = nil
        }
    }

    private func settleKicks() {
        for (id, kick) in kicks {
            guard let job = jobs.first(where: { $0.id == id }), kick.finished(in: job) else { continue }
            kicks[id] = nil
            if job.lastFailed {
                jobNotes[id] = "Failed" + (job.lastError.map { ": " + WatchSnippet.firstLine($0, max: 80) } ?? "")
                WKInterfaceDevice.current().play(.failure)
            } else {
                jobNotes[id] = job.deliver == "local" ? "Done · saved on your Mac" : "Done · sent to \(job.deliveryLabel)"
                WKInterfaceDevice.current().play(.success)
            }
        }
    }

    // MARK: Live line → complications

    private var lastReload = Date.distantPast

    /// This watch's own runs drive the live line directly.
    private func publish(_ state: LiveStatus.State, _ line: String) {
        let s = LiveStatus(state: state, line: line, title: title, sessionID: sessionID, steps: 0,
                           startedAt: state == .working ? (SharedVault.status().state == .working ? SharedVault.status().startedAt : Date()) : SharedVault.status().startedAt,
                           updatedAt: Date())
        SharedVault.saveStatus(s)
        reloadComplications(force: state != .working)
    }

    func reloadComplications(force: Bool) {
        guard force || Date().timeIntervalSince(lastReload) > 15 else { return }
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Pushed from the iPhone (its chats' runs, fresh limits).
    nonisolated fileprivate func receive(_ info: [String: Any]) {
        if let s = LiveStatus.from(info) { SharedVault.saveStatus(s) }
        if let d = info["limits"] as? Data, let snap = try? JSONDecoder().decode(LimitsSnapshot.self, from: d) {
            SharedVault.saveLimits(snap)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Transport: phone first, then direct

    /// Wraps the reply dictionary so it can cross back to the main actor.
    final class Box: @unchecked Sendable { let value: [String: Any]; init(_ v: [String: Any]) { value = v } }

    @discardableResult
    private func send(_ message: [String: Any], timeout: TimeInterval = 30) async -> [String: Any] {
        let s = WCSession.default
        if WCSession.isSupported(), s.activationState == .activated, s.isReachable {
            if let viaPhone = await Self.viaPhone(s, Box(message))?.value { return viaPhone }
        }
        return await direct(message, timeout: timeout)
    }

    nonisolated private static func viaPhone(_ s: WCSession, _ box: Box) async -> Box? {
        let message = box.value
        return await withCheckedContinuation { (c: CheckedContinuation<Box?, Never>) in
            let once = Once()
            s.sendMessage(message, replyHandler: { reply in
                if once.claim() { c.resume(returning: Box(reply)) }
            }, errorHandler: { _ in
                if once.claim() { c.resume(returning: nil) }
            })
        }
    }

    private var directConfig: (URL, URL, String)? {
        #if DEBUG
        let d = UserDefaults.standard
        if let g = d.string(forKey: "hermes.url").flatMap(URL.init(string:)), let k = d.string(forKey: "hermes.key"),
           var c = URLComponents(url: g, resolvingAgainstBaseURL: false) {
            c.port = 8651
            if let relay = c.url { return (g, relay, k) }
        }
        #endif
        let ctx = WCSession.isSupported() ? WCSession.default.receivedApplicationContext : [:]
        guard let g = (ctx[WatchWire.gatewayURL] as? String).flatMap(URL.init(string:)),
              let rl = (ctx[WatchWire.relayURL] as? String).flatMap(URL.init(string:)),
              let k = ctx[WatchWire.apiKey] as? String else { return nil }
        return (g, rl, k)
    }

    private func direct(_ message: [String: Any], timeout: TimeInterval) async -> [String: Any] {
        guard let (g, rl, k) = directConfig else {
            return ["error": "Open Otto on your iPhone once so the watch can connect."]
        }
        let lite = HermesLite(gateway: g, relay: rl, apiKey: k, timeout: timeout)
        do {
            switch message[WatchWire.op] as? String {
            case WatchWire.ask:
                let t = try await lite.ask(audio: message["audio"] as? Data, text: message["text"] as? String,
                                           sessionID: message["session"] as? String,
                                           endsOnGoodbye: message["loop"] as? Bool ?? false)
                return WatchWire.reply(t)
            case WatchWire.status:
                let st = try await lite.status(runID: message["run"] as? String ?? "")
                var out: [String: Any] = ["status": st.status]
                if let o = st.output { out["output"] = o }
                if let e = st.lastEvent { out["event"] = e }
                return out
            case WatchWire.speak:
                return ["audio": try await lite.speak(message["text"] as? String ?? "")]
            case WatchWire.stop:
                await lite.stop(runID: message["run"] as? String ?? ""); return ["ok": true]
            case WatchWire.limits:
                let snap = try await LimitsAPI.fetch(relay: rl, apiKey: k, timeout: timeout)
                return ["limits": try JSONEncoder().encode(snap)]
            case WatchWire.jobs:
                return ["jobs": try JSONEncoder().encode(JobsAPI.ordered(try await JobsAPI.list(relay: rl, apiKey: k, timeout: timeout)))]
            case WatchWire.runJob:
                guard let d = message["job"] as? Data, let job = try? JSONDecoder().decode(JobLite.self, from: d) else {
                    return ["error": "unknown job"]
                }
                try await JobsAPI.run(job, relay: rl, apiKey: k, timeout: timeout)
                return ["ok": true]
            case WatchWire.chats:
                return ["chats": try JSONEncoder().encode(try await lite.recentChats())]
            case WatchWire.chat:
                return ["exchange": try JSONEncoder().encode(try await lite.lastExchange(sessionID: message["session"] as? String ?? ""))]
            default: return ["error": "unknown"]
            }
        } catch HermesLite.Failure.nothingHeard {
            return ["error": "I didn't catch that. Try again a little closer to the watch."]
        } catch {
            return ["error": "Can't reach your agent. Keep your iPhone nearby."]
        }
    }

    // MARK: Limits

    private(set) var limits: LimitsSnapshot?
    private(set) var limitsLoading = false

    /// Keeps the AI Limits complication fed: ask the phone for fresh numbers when ours are older
    /// than ~15 minutes (on launch, when the app comes forward, and from background refreshes).
    func refreshLimitsIfStale() async {
        if let d = SharedVault.limits()?.fetchedDate, Date().timeIntervalSince(d) < 15 * 60 { return }
        await loadLimits()
    }

    /// watchOS wakes the app roughly when asked (budget: a few per hour while a complication is on the face).
    static func scheduleBackgroundRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(30 * 60), userInfo: nil) { _ in }
    }

    func loadLimits() async {
        limitsLoading = true
        defer { limitsLoading = false }
        let r = await send([WatchWire.op: WatchWire.limits], timeout: 30)
        if let data = r["limits"] as? Data, let snap = try? JSONDecoder().decode(LimitsSnapshot.self, from: data) {
            limits = snap
            SharedVault.saveLimits(snap)
            reloadComplications(force: true)
        }
    }

    // MARK: Debug

    #if DEBUG
    func debugLaunch() async {
        // `-hermes.autotalk 1` starts a hands-free conversation; with `-hermes.autoask "…"` its first turn is that text.
        let talk = UserDefaults.standard.bool(forKey: "hermes.autotalk")
        if let q = UserDefaults.standard.string(forKey: "hermes.autoask") {
            if talk { handsFree = true }
            await ask(text: q)
        } else if talk {
            await startConversation()
        }
        if let id = UserDefaults.standard.string(forKey: "hermes.openChat"), !id.isEmpty {
            await open(.init(id: id, title: UserDefaults.standard.string(forKey: "hermes.openTitle") ?? "Chat", lastActive: nil, source: nil))
        }
    }
    #endif
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { receive(userInfo) }
}

extension WatchModel: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishPlayback() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finishPlayback() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finishPlayback() }
    }
}

/// Markdown → plain text for a small screen, plus sentence chunks for speech.
enum WatchText {
    static func plain(_ s: String) -> String {
        var t = s
        for (pattern, repl) in [("```[\\s\\S]*?```", ""), ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
                                ("(\\*\\*|__|~~|`)", ""), ("(?m)^#{1,6}\\s+", ""), ("(?m)^[-*+]\\s+", "• ")] {
            t = t.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sentences, merged so each spoken clip is a sensible length (not one word, not a paragraph).
    static func sentences(_ s: String) -> [String] {
        var parts: [String] = []
        s.enumerateSubstrings(in: s.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
        }
        var out: [String] = []
        for p in parts {
            if let last = out.last, last.count < 60 { out[out.count - 1] = last + " " + p } else { out.append(p) }
        }
        return out.isEmpty ? [s] : out
    }

    static func status(_ event: String) -> String? {
        if event.contains("approval") { return "Needs your approval" }
        if event.contains("tool") { return "Using tools…" }
        if event.contains("reasoning") || event.contains("thinking") { return "Thinking…" }
        if event.contains("delta") || event.contains("message") { return "Writing…" }
        return nil
    }
}

/// Resume a continuation exactly once from racing callbacks.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
