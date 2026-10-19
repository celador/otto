import AVFoundation
import Foundation

/// Which engine runs voice mode.
enum VoiceEngine: String, CaseIterable, Identifiable, Sendable {
    /// Gemini Live talks with you (speech to speech) and hands real work to the agent.
    case gemini
    /// ChatGPT's voice (on John's ChatGPT subscription, through the Mac) talks with you and hands
    /// real work to the agent. Same client as Gemini: the Mac bridge speaks Gemini Live's wire format.
    case chatgpt
    /// On-device speech recognition → the agent → Hermes's voice (Edge TTS).
    case classic

    nonisolated static let key = "hermes.voiceEngine"
    nonisolated static let geminiVoiceKey = "hermes.geminiVoice"
    nonisolated static let defaultGeminiVoice = "Charon"
    nonisolated static let chatgptVoiceKey = "hermes.chatgptVoice"
    nonisolated static let defaultChatGPTVoice = "cove"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .gemini: "Gemini Live"
        case .chatgpt: "ChatGPT voice"
        case .classic: "Otto voice (local)"
        }
    }

    nonisolated static var current: VoiceEngine {
        VoiceEngine(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .gemini
    }
    nonisolated static var geminiVoice: String {
        let v = UserDefaults.standard.string(forKey: geminiVoiceKey) ?? ""
        return v.isEmpty ? defaultGeminiVoice : v
    }
    /// Empty = the Mac's default (CHATGPT_LIVE_VOICE, else cove).
    nonisolated static var chatgptVoice: String {
        UserDefaults.standard.string(forKey: chatgptVoiceKey) ?? ""
    }
    /// A speech-to-speech engine run by `GeminiLive` (Gemini Live, or ChatGPT through the bridge).
    var isLive: Bool { self != .classic }
    /// The voice setting for this engine ("" = server default).
    nonisolated var savedVoice: String {
        switch self {
        case .gemini: VoiceEngine.geminiVoice
        case .chatgpt: VoiceEngine.chatgptVoice
        case .classic: ""
        }
    }
}

/// What the voice screen shows; `VoiceSession` implements it.
@MainActor
protocol GeminiLiveHost: AnyObject {
    func liveSetPhase(_ phase: VoiceSession.Phase)
    func liveHeard(_ text: String)
    func liveSpoken(_ text: String)
    func liveLevel(_ level: Float)
    func liveBargeIn()
    /// Your turn was closed and sent (tap or end-of-turn detection).
    func liveTurnSent()
    func liveCommand(_ command: String) async -> VoiceCommandResult
}

// MARK: - Relay API

struct GeminiLiveStatus: Decodable, Sendable {
    struct Voice: Decodable, Sendable, Hashable { let name: String; let style: String }
    let available: Bool
    let reason: String?
    let model: String?
    let defaultVoice: String?
    let voices: [Voice]?
}

struct GeminiLiveToken: Decodable, Sendable {
    let token: String
    let wsUrl: String
    let model: String
    let voice: String
    /// The BidiGenerateContentSetup to send first, as JSON (the relay owns the persona and tools).
    let setup: LiveJSON
}

extension CompanionClient {
    func geminiLiveStatus() async throws -> GeminiLiveStatus {
        try HermesClient.decoder.decode(GeminiLiveStatus.self, from: try await rawRequest("GET", "/hermes/voice-live/gemini"))
    }

    func geminiLiveToken(voice: String) async throws -> GeminiLiveToken {
        try await liveToken(.gemini, voice: voice)
    }

    /// Status of a live engine on the Mac: `/hermes/voice-live/gemini` or `/chatgpt`.
    func liveStatus(_ engine: VoiceEngine) async throws -> GeminiLiveStatus {
        try HermesClient.decoder.decode(GeminiLiveStatus.self, from: try await rawRequest("GET", "/hermes/voice-live/" + engine.rawValue))
    }

    /// A single-use token + setup. ChatGPT's token opens the Mac bridge (wss, same tailnet host).
    func liveToken(_ engine: VoiceEngine, voice: String) async throws -> GeminiLiveToken {
        let body = try JSONSerialization.data(withJSONObject: voice.isEmpty ? [:] : ["voice": voice])
        let data = try await rawRequest("POST", "/hermes/voice-live/\(engine.rawValue)/token", body: body)
        return try HermesClient.decoder.decode(GeminiLiveToken.self, from: data)
    }

    /// Gemini's blocking web_search / weather functions, served by the relay (DuckDuckGo, Open-Meteo).
    func voiceLookup(_ kind: VoiceLookup, _ value: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [kind.field: value])
        let data = try await rawRequest("POST", "/hermes/voice-live/" + kind.rawValue, body: body)
        struct Out: Decodable { let result: String }
        return try HermesClient.decoder.decode(Out.self, from: data).result
    }
}

enum VoiceLookup: String, Sendable {
    case search, weather
    var field: String { self == .search ? "query" : "place" }
}

/// Arbitrary JSON carried through untouched (the setup message).
enum LiveJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([LiveJSON]), object([String: LiveJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([LiveJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: LiveJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Plain Foundation object (for JSONSerialization).
    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? Int64(n) as Any : n
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }
}

// MARK: - Wire format (pure, unit-tested)

enum GeminiWire {
    /// Server message → events the session acts on, in order.
    enum Event: Equatable {
        case setupComplete
        case audio(Data)
        case inputText(String)
        case outputText(String)
        case interrupted
        case turnComplete
        case toolCall(id: String, name: String, args: [String: String])
        case toolCancel([String])
        case goAway
        case resumeHandle(String)
        case error(String)
    }

    nonisolated static func parse(_ data: Data) -> [Event] {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [Event] = []
        if msg["setupComplete"] != nil { out.append(.setupComplete) }
        if let sc = msg["serverContent"] as? [String: Any] {
            if let it = (sc["inputTranscription"] as? [String: Any])?["text"] as? String, !it.isEmpty { out.append(.inputText(it)) }
            if let parts = (sc["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
                for p in parts {
                    if let inline = p["inlineData"] as? [String: Any], let b64 = inline["data"] as? String,
                       let pcm = Data(base64Encoded: b64) { out.append(.audio(pcm)) }
                }
            }
            if let ot = (sc["outputTranscription"] as? [String: Any])?["text"] as? String, !ot.isEmpty { out.append(.outputText(ot)) }
            if sc["interrupted"] as? Bool == true { out.append(.interrupted) }
            if sc["turnComplete"] as? Bool == true { out.append(.turnComplete) }
        }
        if let calls = (msg["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
            for c in calls {
                let args = (c["args"] as? [String: Any] ?? [:]).compactMapValues { v -> String? in
                    if let s = v as? String { return s }
                    if let n = v as? NSNumber { return n.stringValue }
                    return nil
                }
                out.append(.toolCall(id: c["id"] as? String ?? "", name: c["name"] as? String ?? "", args: args))
            }
        }
        if let ids = (msg["toolCallCancellation"] as? [String: Any])?["ids"] as? [String] { out.append(.toolCancel(ids)) }
        if msg["goAway"] != nil { out.append(.goAway) }
        if let r = msg["sessionResumptionUpdate"] as? [String: Any], r["resumable"] as? Bool == true,
           let h = r["newHandle"] as? String, !h.isEmpty { out.append(.resumeHandle(h)) }
        if let e = msg["error"] as? [String: Any] { out.append(.error(e["message"] as? String ?? "error")) }
        return out
    }

    /// `context`: for the ChatGPT bridge the chat's last turns ride in the setup (its sessions take
    /// history only at start); Gemini gets them as clientContent after setup instead.
    /// `clientTurns`: noisy-room mode, Gemini's VAD off (the phone sends activityStart/activityEnd).
    nonisolated static func setupMessage(_ setup: LiveJSON, resumeHandle: String?,
                                         context: [(user: Bool, text: String)]? = nil,
                                         clientTurns: Bool = false) -> Data? {
        guard var obj = setup.any as? [String: Any] else { return nil }
        if let resumeHandle { obj["sessionResumption"] = ["handle": resumeHandle] }
        if clientTurns {
            var rc = obj["realtimeInputConfig"] as? [String: Any] ?? [:]
            rc["automaticActivityDetection"] = ["disabled": true]
            obj["realtimeInputConfig"] = rc
        }
        if let context, !context.isEmpty {
            obj["context"] = context.map { ["role": $0.user ? "user" : "assistant", "text": $0.text] }
        }
        return try? JSONSerialization.data(withJSONObject: ["setup": obj])
    }

    nonisolated static func audioMessage(_ pcm16k: Data) -> Data {
        let json = #"{"realtimeInput":{"audio":{"mimeType":"audio/pcm;rate=16000","data":""# + pcm16k.base64EncodedString() + #""}}}"#
        return Data(json.utf8)
    }

    nonisolated static let audioStreamEnd = Data(#"{"realtimeInput":{"audioStreamEnd":true}}"#.utf8)
    /// Client-driven turns (automaticActivityDetection disabled): John started / stopped talking.
    /// activityStart while Otto talks interrupts it (the server sends `interrupted`).
    nonisolated static let activityStart = Data(#"{"realtimeInput":{"activityStart":{}}}"#.utf8)
    nonisolated static let activityEnd = Data(#"{"realtimeInput":{"activityEnd":{}}}"#.utf8)

    /// `scheduling`: WHEN_IDLE (say it after the current sentence), INTERRUPT, SILENT.
    /// `willContinue`: a progress update for a NON_BLOCKING call; more responses for the same id follow
    /// and the last one goes without it.
    nonisolated static func toolResponse(id: String, name: String, result: String, scheduling: String,
                                         willContinue: Bool = false) -> Data? {
        var response: [String: Any] = ["id": id, "name": name, "response": ["result": result, "scheduling": scheduling]]
        if willContinue { response["willContinue"] = true }
        return try? JSONSerialization.data(withJSONObject: ["toolResponse": ["functionResponses": [response]]])
    }

    /// Earlier chat as context, so "what did you just say about the build" works. No reply is triggered.
    nonisolated static func contextMessage(_ turns: [(user: Bool, text: String)]) -> Data? {
        guard !turns.isEmpty else { return nil }
        let content = turns.map { ["role": $0.user ? "user" : "model", "parts": [["text": $0.text]]] as [String: Any] }
        return try? JSONSerialization.data(withJSONObject: ["clientContent": ["turns": content, "turnComplete": false]])
    }

    /// Little-endian PCM16 mono 24 kHz → a playback buffer.
    nonisolated static func playbackBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: VoiceAudio.playbackFormat,
                                                     frameCapacity: AVAudioFrameCount(frames)),
              let dst = buf.floatChannelData?[0] else { return nil }
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                dst[i] = Float(v) / 32768
            }
        }
        buf.frameLength = AVAudioFrameCount(frames)
        return buf
    }
}

// MARK: - Progress while the agent works (pure, unit-tested)

/// Decides which progress updates Gemini gets while an ask_otto run is going: nothing in the first
/// 3 s, at most one every 6 s, never the same text twice, never while John is talking. What the agent
/// says between tools ("interim" text) is real news (WHEN_IDLE: Gemini may mention it); a tool status
/// line is minor (SILENT: Gemini just knows).
struct AgentProgress: Sendable {
    struct Update: Equatable, Sendable {
        let result: String
        let scheduling: String
    }

    nonisolated static let quietStart: TimeInterval = 3
    nonisolated static let minGap: TimeInterval = 6

    let started: Date
    private(set) var lastSent: Date?
    private var said: Set<String> = []

    nonisolated init(started: Date) { self.started = started }

    /// `status`: chat.liveStatus; `interim`: the newest finished agent message in this turn.
    nonisolated mutating func next(now: Date, status: String?, interim: String?, userTalking: Bool) -> Update? {
        guard !userTalking, now.timeIntervalSince(started) >= Self.quietStart else { return nil }
        if let lastSent, now.timeIntervalSince(lastSent) < Self.minGap { return nil }
        let candidates: [(String?, String)] = [(interim, "WHEN_IDLE"), (status, "SILENT")]
        for (raw, scheduling) in candidates {
            guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let clipped = String(text.prefix(400))
            guard !said.contains(clipped) else { continue }
            said.insert(clipped)
            lastSent = now
            return Update(result: "partial: " + clipped, scheduling: scheduling)
        }
        return nil
    }
}

// MARK: - End of turn on the phone (pure, unit-tested)

/// Who ends John's turns in a live session.
enum LiveTurns: String, Sendable {
    /// Gemini's own voice activity detection (quiet rooms). The phone only backs it up.
    case server
    /// Otto's detector sends activityStart / activityEnd (Gemini's VAD off); for ChatGPT it gates
    /// the mic and sends audioStreamEnd. Babble and PA announcements keep server VAD "in speech"
    /// forever, and audioStreamEnd doesn't close the turn either (relay/probe_vad.py, airport fixture).
    case client

    /// A room whose floor is above this (dBFS) is noisy.
    nonisolated static let noisyFloor: Float = -45
    /// The floor has to stay up this long mid-session before switching.
    nonisolated static let noisyHold: TimeInterval = 3

    nonisolated static func decide(_ room: VoiceLogic.NoiseFloor) -> LiveTurns {
        room.calibrated && room.floor > noisyFloor ? .client : .server
    }
}

/// During a server-VAD session: the room got loud (walked into a terminal) and stayed loud.
struct NoisyRoomWatch: Sendable {
    private(set) var loud: TimeInterval = 0
    nonisolated init() {}
    nonisolated mutating func feed(_ room: VoiceLogic.NoiseFloor, duration: TimeInterval) -> Bool {
        loud = room.calibrated && room.floor > LiveTurns.noisyFloor ? loud + duration : 0
        return loud >= LiveTurns.noisyHold
    }
}

/// The phone's own end-of-turn detection over the mic chunks we stream (Python mirror with the same
/// numbers: relay/turn_detect.py, which relay/probe_vad.py runs against live Gemini).
///
/// Server mode backs up Gemini's VAD: once John has talked (>= 0.3 s clearly above the room) and the
/// mic has stayed well below his voice for 1.5 s while the server still hasn't answered, end the turn
/// (`audioStreamEnd`). "Well below his voice": under the room floor + 8 dB, or 15 dB under his own
/// talking level, so a quieter voice in the background counts as quiet.
///
/// Client mode (noisy rooms) decides the whole turn. The floor follows the room's quiet moments and
/// the room median is its typical level (babble sits a few dB over its floor). A turn opens on
/// >= 0.3 s (within 0.6 s) of chunks over floor+8 / median+6; a 0.2 s word over floor+6 / median+4
/// and within 8 dB of his own level keeps it open (far-field talkers are ~10 dB under near-field
/// speech); it is quiet once back under floor+4 / median+2 or 8 dB under his level. 1.5 s of quiet
/// ends it, and so does 25 s (it sends what it has).
struct TurnEndpointer: Sendable {
    enum Event: Equatable, Sendable {
        /// Client mode: John started talking (send activityStart + the pre-roll).
        case start
        /// End the turn now; the reason goes to the voice log.
        case end(String)
    }

    nonisolated static let quietToEnd: TimeInterval = 1.5
    nonisolated static let minSpeech: TimeInterval = 0.3
    nonisolated static let speechOverFloor: Float = 12
    nonisolated static let quietOverFloor: Float = 8
    nonisolated static let belowSpeech: Float = 15
    nonisolated static let maxTurn: TimeInterval = 25

    nonisolated static let clientQuietToEnd: TimeInterval = 1.5
    nonisolated static let clientOnset: Float = 8
    nonisolated static let clientTalk: Float = 6
    nonisolated static let clientQuiet: Float = 4
    nonisolated static let clientOnsetOverMedian: Float = 6
    nonisolated static let clientTalkOverMedian: Float = 4
    nonisolated static let clientQuietOverMedian: Float = 2
    nonisolated static let clientBelowSpeech: Float = 12
    nonisolated static let clientNear: Float = 8
    nonisolated static let clientWord: TimeInterval = 0.2
    nonisolated static let onsetWindow: TimeInterval = 0.6
    nonisolated static let onsetSpeech: TimeInterval = 0.3

    private(set) var room = VoiceLogic.NoiseFloor()
    /// Seconds of John's speech since the turn opened.
    private(set) var speech: TimeInterval = 0
    /// His talking level this turn (dBFS).
    private(set) var speechLevel: Float?
    private(set) var quiet: TimeInterval = 0
    /// Client mode: an activity is open.
    private(set) var active = false
    /// Seconds since this turn's first speech.
    private(set) var turnTime: TimeInterval = 0
    /// The room's median level, learned between turns.
    private(set) var roomMedian: Float?
    private var talkRun: TimeInterval = 0
    private var recent: [(speech: Bool, db: Float, duration: TimeInterval)] = []

    nonisolated init() {}

    /// He has said something this turn (tap to send has something to send).
    nonisolated var heardSpeech: Bool { speech >= Self.minSpeech }

    /// dBFS of a little-endian PCM16 chunk.
    nonisolated static func level(_ pcm: Data) -> Float {
        let n = pcm.count / 2
        guard n > 0 else { return -100 }
        var sum: Double = 0
        pcm.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += v * v
            }
        }
        let rms = (sum / Double(n)).squareRoot() / 32768
        return rms > 0 ? max(-100, Float(20 * log10(rms))) : -100
    }

    nonisolated func describe() -> String {
        "floor=\(room.describe()) median=\(roomMedian.map { "\(Int($0.rounded()))dB" } ?? "-")"
    }

    /// One mic chunk. `serverHeard` (server mode): the server is transcribing this turn (it heard
    /// words, so the turn is real). `client`: noisy-room mode. `playing`: Otto's reply is playing
    /// (full duplex), so starting a turn needs a louder voice (echo residue).
    nonisolated mutating func feed(db: Float, duration: TimeInterval, serverHeard: Bool,
                                   client: Bool = false, playing: Bool = false) -> Event? {
        let floor = room.floor
        let calibrated = room.calibrated
        room.observe(db, playing: playing, duration: duration)
        guard calibrated else { return nil }
        if !active, let m = room.median { roomMedian = m }
        let (isSpeech, isQuiet) = client ? classifyClient(db, floor: floor, playing: playing)
                                         : classifyServer(db, floor: floor)
        if client && !active {
            recent.append((isSpeech, db, duration))
            var total = recent.reduce(0) { $0 + $1.duration }
            while let first = recent.first, total - first.duration >= Self.onsetWindow {
                total -= first.duration
                recent.removeFirst()
            }
            let voiced = recent.filter(\.speech)
            let voicedTime = voiced.reduce(0) { $0 + $1.duration }
            guard voicedTime >= Self.onsetSpeech - 1e-6 else { return nil }
            active = true
            speech = voicedTime
            speechLevel = voiced.reduce(0) { $0 + $1.db } / Float(voiced.count)
            quiet = 0
            turnTime = 0
            talkRun = 0
            recent = []
            return .start
        }
        if speech > 0 || active { turnTime += duration }
        if isSpeech {
            speechLevel = speechLevel.map { trackLevel($0, db, client: client) } ?? db
            speech += duration
            talkRun += duration
            // Client mode: one loud chunk (a babble peak) doesn't reset the quiet timer; a word does.
            if !client || talkRun >= Self.clientWord - 1e-6 { quiet = 0 }
        } else {
            talkRun = 0
            if isQuiet {
                quiet += duration
            } else if !client {
                quiet = 0 // in between: maybe a soft word, keep waiting
            } // client mode, in between (a babble peak near his level): hold the timer
        }
        if client {
            if quiet >= Self.clientQuietToEnd { return endTurn(heardSpeech ? "quiet" : "short") }
            if turnTime >= Self.maxTurn { return endTurn("max \(Int(Self.maxTurn))s") }
            return nil
        }
        if heardSpeech, turnTime >= Self.maxTurn { return endTurn("max \(Int(Self.maxTurn))s") }
        guard heardSpeech, serverHeard, quiet >= Self.quietToEnd else { return nil }
        return endTurn("quiet \(Self.quietToEnd)s")
    }

    nonisolated private func classifyServer(_ db: Float, floor: Float) -> (Bool, Bool) {
        let underVoice = speechLevel.map { db < $0 - Self.belowSpeech } ?? false
        let isSpeech = db > max(floor + Self.speechOverFloor, -50) && !underVoice
        return (isSpeech, !isSpeech && (db < floor + Self.quietOverFloor || underVoice))
    }

    nonisolated private func classifyClient(_ db: Float, floor: Float, playing: Bool) -> (Bool, Bool) {
        let median = roomMedian ?? floor
        let under = speechLevel.map { db < $0 - Self.clientBelowSpeech } ?? false
        let near = speechLevel.map { db >= $0 - Self.clientNear } ?? true
        var bar = active ? max(floor + Self.clientTalk, median + Self.clientTalkOverMedian)
                         : max(floor + Self.clientOnset, median + Self.clientOnsetOverMedian)
        if playing { bar += 6 }
        let isSpeech = db > max(bar, playing ? -40 : -50) && !under && near
        let quietBar = max(floor + Self.clientQuiet, median + Self.clientQuietOverMedian)
        return (isSpeech, !isSpeech && (db < quietBar || under || !near))
    }

    /// His talking level. Client mode: rises quickly, and only a chunk near it pulls it down, so a
    /// far-field talker counted as speech doesn't drag it toward the room.
    nonisolated private func trackLevel(_ level: Float, _ db: Float, client: Bool) -> Float {
        if !client || db > level { return level + (db - level) * 0.2 }
        if db >= level - 4 { return level + (db - level) * 0.05 }
        return level
    }

    /// The turn ended (the server answered, or we ended it): wait for new speech.
    @discardableResult
    nonisolated mutating func endTurn(_ reason: String = "") -> Event {
        speech = 0
        speechLevel = nil
        quiet = 0
        active = false
        turnTime = 0
        talkRun = 0
        recent = []
        return .end(reason)
    }
}

// MARK: - Mic → 16 kHz PCM16

/// Converts mic buffers (any rate/channels) to 16 kHz mono little-endian PCM16 and hands out ~100 ms
/// chunks. Runs on the audio thread.
final class LiveMicEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?
    private var pending = Data()
    private let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let chunkBytes: Int
    private let emit: @Sendable (Data) -> Void

    init(chunkMs: Int = 100, emit: @escaping @Sendable (Data) -> Void) {
        chunkBytes = 16_000 * 2 * chunkMs / 1000
        self.emit = emit
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        var ready: [Data] = []
        lock.withLock {
            if from != buffer.format {
                from = buffer.format
                converter = AVAudioConverter(from: buffer.format, to: out)
            }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
            guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            _ = converter.convert(to: dst, error: &error) { _, s in
                if given { s.pointee = .noDataNow; return nil }
                given = true
                s.pointee = .haveData
                return buffer
            }
            guard dst.frameLength > 0, let p = dst.int16ChannelData?[0] else { return }
            pending.append(Data(bytes: p, count: Int(dst.frameLength) * 2))
            while pending.count >= chunkBytes {
                ready.append(pending.prefix(chunkBytes))
                pending.removeFirst(chunkBytes)
            }
        }
        ready.forEach(emit)
    }

    func reset() { lock.withLock { pending = Data() } }
}

// MARK: - Session

/// One Gemini Live conversation over the voice screen. Gemini owns listening, speaking, turn-taking
/// and barge-in; anything real goes to the agent through `ask_otto`, whose run lands in this chat as
/// usual, and Gemini says the answer.
@MainActor
final class GeminiLive {
    private weak var host: GeminiLiveHost?
    private let chat: ChatModel
    private let companion: CompanionClient
    private let audio: VoiceAudio
    let engine: VoiceEngine

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var setup: LiveJSON?
    private var resumeHandle: String?
    private var reconnects = 0
    private var closed = false
    private var connected = false
    private var setupWaiter: CheckedContinuation<Bool, Never>?
    private var openGeneration = 0
    private lazy var encoder = LiveMicEncoder { [weak self] chunk in
        Task { @MainActor in self?.sendAudio(chunk) }
    }

    private(set) var muted = false
    private var heard = ""
    private var spoken = ""
    /// Model audio arrived since the user's words: the next transcription starts a new user turn.
    private var userTurnClosed = true
    private var modelTurnClosed = true
    private var cancelledCalls: Set<String> = []
    /// ask_otto calls waiting for the agent's run.
    private var waiting = 0
    private var micLevel: Float = 0
    private var outLevel: Float = 0
    private var lastAudioIn = Date.distantPast
    /// When Gemini last transcribed John's speech (no progress updates while he talks).
    private var lastHeard = Date.distantPast
    /// The phone's end-of-turn detection: backup for the server's (quiet rooms), or the whole of it.
    private var endpointer = TurnEndpointer()
    /// Who ends turns this session (decided from the room at connect; server → client if it gets loud).
    private(set) var turns: LiveTurns = .server
    /// The room as heard before the socket opens (mic buffers from engine start).
    private var preRoom = VoiceLogic.NoiseFloor()
    private var roomWatch = NoisyRoomWatch()
    /// The last 0.6 s of mic chunks: sent right after activityStart so the first word isn't lost.
    private var preroll: [Data] = []
    /// The last ~20 s of mic chunks, to replay a turn after switching to client turns.
    private var recentChunks: [(at: Date, pcm: Data)] = []
    /// Server mode: first speech of the open turn (what a replay starts from).
    private var turnOpenedAt: Date?
    private var lastTurnEnd = Date.distantPast
    /// Server mode: we ended the turn and expect an answer by then; none → Gemini's VAD is stuck.
    private var replyDeadline: Date?
    private var switching = false
    private var lastRoomLog = Date.distantPast
    var voiceName = ""

    init(host: GeminiLiveHost, chat: ChatModel, companion: CompanionClient, audio: VoiceAudio,
         engine: VoiceEngine = .gemini) {
        self.host = host
        self.chat = chat
        self.companion = companion
        self.audio = audio
        self.engine = engine == .classic ? .gemini : engine
    }

    private func mint() async throws -> GeminiLiveToken {
        try await companion.liveToken(engine, voice: voiceName.isEmpty ? engine.savedVoice : voiceName)
    }

    // MARK: Lifecycle

    /// Mints a token on the relay and opens the socket. False → use the classic engine.
    func connect() async -> Bool {
        do {
            let t = try await mint()
            voiceName = t.voice
            setup = t.setup
            VoiceDiag.log("gemini: token ok engine=\(engine.rawValue) model=\(t.model) voice=\(t.voice)")
            // Learn the room from the mic (running since engine start) before choosing turn-taking.
            for _ in 0..<8 where !preRoom.calibrated { try? await Task.sleep(for: .milliseconds(100)) }
            turns = LiveTurns.decide(preRoom)
            VoiceDiag.log("gemini: room floor=\(preRoom.describe()) turns=\(turns.rawValue)"
                          + (turns == .client ? " (noisy: above \(Int(LiveTurns.noisyFloor))dB)" : ""))
            guard await open(t) else { return false }
            sendContext()
            audio.pcmSink.set { [encoder] buf in encoder.append(buf) }
            startTicker()
            return true
        } catch {
            VoiceDiag.log("gemini: token failed: \(error)")
            return false
        }
    }

    private func open(_ t: GeminiLiveToken) async -> Bool {
        guard var comps = URLComponents(string: t.wsUrl) else { return false }
        comps.queryItems = [URLQueryItem(name: "access_token", value: t.token)]
        guard let url = comps.url, let setup,
              let first = GeminiWire.setupMessage(setup, resumeHandle: resumeHandle,
                                                  context: engine == .chatgpt ? contextTurns() : nil,
                                                  clientTurns: turns == .client && engine == .gemini) else { return false }
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        connected = false
        task.resume()
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        do { try await task.send(.data(first)) } catch {
            VoiceDiag.log("gemini: setup send failed: \(error)")
            return false
        }
        openGeneration += 1
        let gen = openGeneration
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            setupWaiter = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.openGeneration == gen else { return }
                self.finishSetupWait(false)
            }
        }
        VoiceDiag.log("gemini: setup \(ok ? "complete" : "failed") resumed=\(resumeHandle != nil) turns=\(turns.rawValue)")
        return ok
    }

    private func finishSetupWait(_ ok: Bool) {
        if ok { connected = true }
        setupWaiter?.resume(returning: ok)
        setupWaiter = nil
    }

    func close() {
        closed = true
        audio.pcmSink.set(nil)
        ticker?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        finishSetupWait(false)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let data: Data
                switch msg {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                for e in GeminiWire.parse(data) { handle(e) }
            } catch {
                guard task === socket, !closed else { return }
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                VoiceDiag.log("gemini: socket closed code=\(task.closeCode.rawValue) reason=\(reason) error=\(error.localizedDescription)")
                if setupWaiter != nil { finishSetupWait(false); return }
                await reconnect()
                return
            }
        }
    }

    /// The server rotates connections (~10 min) and tokens expire (30 min): resume with a new token.
    private func reconnect() async {
        guard !closed else { return }
        reconnects += 1
        if reconnects > 4 {
            host?.liveSetPhase(.error("Lost the voice connection. Tap to try again."))
            return
        }
        connected = false
        do {
            let t = try await mint()
            setup = t.setup
            if await open(t) {
                reconnects = 0
                return
            }
            if resumeHandle != nil {
                // The handle may have expired: start fresh with the chat as context.
                resumeHandle = nil
                let t2 = try await mint()
                if await open(t2) { sendContext(); reconnects = 0; return }
            }
        } catch {
            VoiceDiag.log("gemini: reconnect failed: \(error)")
        }
        try? await Task.sleep(for: .seconds(1))
        await reconnect()
    }

    /// Tap to retry after the connection gave up.
    func retry() async {
        reconnects = 0
        resumeHandle = nil
        do {
            let t = try await mint()
            setup = t.setup
            if await open(t) { sendContext(); updatePhase(); return }
        } catch {
            VoiceDiag.log("gemini: retry failed: \(error)")
        }
        host?.liveSetPhase(.error("Couldn't reach \(engine.label)."))
    }

    // MARK: Sending

    private func send(_ data: Data) {
        guard let socket, connected else { return }
        socket.send(.data(data)) { error in
            if let error { Task { @MainActor in VoiceDiag.log("gemini: send failed: \(error.localizedDescription)") } }
        }
    }

    private func sendAudio(_ chunk: Data) {
        guard !muted else { return }
        let now = Date()
        remember(chunk, at: now)
        guard connected, !switching else { return }
        // Half-duplex (no echo cancellation on this route): don't let Gemini hear itself.
        if !audio.fullDuplex, audio.isPlaying { return }
        lastAudioIn = now
        let db = TurnEndpointer.level(chunk)
        let duration = Double(chunk.count) / 32_000
        logRoom(now)
        if turns == .client { clientTurnAudio(chunk, db: db, duration: duration, now: now); return }
        send(GeminiWire.audioMessage(chunk))
        if audio.isPlaying { // Otto talking: not John's turn
            endpointer.endTurn()
            turnOpenedAt = nil
            return
        }
        // ChatGPT's bridge sends John's transcript late, so there only the mic counts.
        let serverHeard = engine == .chatgpt || (!userTurnClosed && !heard.isEmpty)
        let hadSpeech = endpointer.speech > 0
        let event = endpointer.feed(db: db, duration: duration, serverHeard: serverHeard)
        if !hadSpeech, endpointer.speech > 0, turnOpenedAt == nil { turnOpenedAt = now }
        if case .end(let reason) = event { endTurn(reason: reason) }
        if let deadline = replyDeadline, now >= deadline {
            // We ended the turn and nothing came back: Gemini's VAD still thinks he's talking
            // (babble). Take over turn-taking and replay what he said.
            switchToClientTurns(reason: "no answer after end of turn", replay: true)
        } else if roomWatch.feed(endpointer.room, duration: duration), endpointer.speech == 0, replyDeadline == nil {
            switchToClientTurns(reason: "room got loud", replay: false)
        }
    }

    /// Noisy-room mode: Otto's detector opens and closes John's turns; audio goes out only inside one.
    private func clientTurnAudio(_ chunk: Data, db: Float, duration: TimeInterval, now: Date) {
        let event = endpointer.feed(db: db, duration: duration, serverHeard: true, client: true,
                                    playing: audio.isPlaying)
        switch event {
        case .start:
            VoiceDiag.log("gemini: turn start (client) db=\(Int(db)) \(endpointer.describe()) playing=\(audio.isPlaying)")
            if engine == .gemini { send(GeminiWire.activityStart) }
            for c in preroll.dropLast() { send(GeminiWire.audioMessage(c)) }
            send(GeminiWire.audioMessage(chunk))
            turnOpenedAt = now
        case .end(let reason):
            send(GeminiWire.audioMessage(chunk))
            finishClientTurn(reason: reason)
        case nil:
            if endpointer.active { send(GeminiWire.audioMessage(chunk)) }
        }
    }

    private func finishClientTurn(reason: String) {
        VoiceDiag.log("gemini: end of turn (client, \(reason)) \(endpointer.describe()) heard=\"\(heard.suffix(60))\"")
        send(engine == .gemini ? GeminiWire.activityEnd : GeminiWire.audioStreamEnd)
        lastTurnEnd = Date()
        turnOpenedAt = nil
    }

    /// Keeps the pre-roll and the replay buffer.
    private func remember(_ chunk: Data, at now: Date) {
        preroll.append(chunk)
        if preroll.count > 6 { preroll.removeFirst(preroll.count - 6) }
        recentChunks.append((now, chunk))
        if let first = recentChunks.first, now.timeIntervalSince(first.at) > 20 {
            recentChunks.removeAll { now.timeIntervalSince($0.at) > 20 }
        }
    }

    private func logRoom(_ now: Date) {
        guard now.timeIntervalSince(lastRoomLog) >= 10 else { return }
        lastRoomLog = now
        VoiceDiag.log("gemini: room \(endpointer.describe()) turns=\(turns.rawValue)")
    }

    /// John is done: tell the server to close his turn now (it answers right away). The mic keeps
    /// streaming; the next audio opens a new turn.
    private func endTurn(reason: String) {
        VoiceDiag.log("gemini: end of turn (\(reason)) \(endpointer.describe()) heard=\"\(heard.suffix(60))\"")
        endpointer.endTurn()
        send(GeminiWire.audioStreamEnd)
        lastTurnEnd = Date()
        host?.liveTurnSent()
        // Gemini answers ~1 s after this in a quiet room; silence well past that means it never
        // closed the turn. A tap is John waiting, so give up on the server sooner.
        if engine == .gemini { replyDeadline = Date().addingTimeInterval(reason == "tap" ? 2.5 : 4) }
    }

    /// The server answered (audio, a tool call, turn complete): John's turn is closed.
    private func serverReplied() {
        replyDeadline = nil
        if turns == .server {
            endpointer.endTurn()
            turnOpenedAt = nil
        }
    }

    /// Hand turn-taking to Otto for the rest of the session. Gemini: a new connection with its VAD off
    /// (chat as context), then replay John's last turn as one activity if it never got answered.
    /// ChatGPT: same connection, the mic is just gated.
    private func switchToClientTurns(reason: String, replay: Bool) {
        guard turns == .server, !switching, !closed else { return }
        let since = (turnOpenedAt ?? lastTurnEnd.addingTimeInterval(-10)).addingTimeInterval(-0.5)
        let chunks = replay ? recentChunks.filter { $0.at >= since }.map(\.pcm) : []
        turns = .client
        VoiceDiag.log("gemini: switching to client turns (\(reason)) \(endpointer.describe()) replay=\(String(format: "%.1f", Double(chunks.count) / 10))s")
        endpointer.endTurn()
        replyDeadline = nil
        turnOpenedAt = nil
        guard engine == .gemini else { return }
        switching = true
        let old = socket
        // A resumed session silently ignores activityStart/End when the VAD config changes (probe,
        // 2026-10-18): start a fresh session and give it the chat as context instead.
        resumeHandle = nil
        Task {
            defer { switching = false }
            do {
                let t = try await mint()
                setup = t.setup
                if await open(t) {
                    old?.cancel(with: .normalClosure, reason: nil)
                    sendContext()
                    if !chunks.isEmpty {
                        send(GeminiWire.activityStart)
                        for c in chunks { send(GeminiWire.audioMessage(c)) }
                        send(GeminiWire.activityEnd)
                        lastTurnEnd = Date()
                        VoiceDiag.log("gemini: replayed \(chunks.count * 100) ms as one turn")
                    }
                    return
                }
            } catch {
                VoiceDiag.log("gemini: switch failed: \(error)")
            }
            old?.cancel(with: .normalClosure, reason: nil)
            await reconnect()
        }
    }

    func setMuted(_ on: Bool) {
        guard on != muted else { return }
        muted = on
        if on {
            encoder.reset()
            if turns == .client {
                // Gemini's VAD is off: close an open activity; audioStreamEnd is for server VAD only.
                if endpointer.active { endpointer.endTurn(); finishClientTurn(reason: "muted") }
                else if engine == .chatgpt { send(GeminiWire.audioStreamEnd) }
            } else {
                send(GeminiWire.audioStreamEnd)
            }
        }
        updatePhase()
    }

    /// The last few chat messages, so Gemini knows what this conversation is about. (ChatGPT got
    /// them in the setup.)
    private func sendContext() {
        guard engine == .gemini else { return }
        if let msg = GeminiWire.contextMessage(contextTurns()) { send(msg) }
    }

    private func contextTurns() -> [(user: Bool, text: String)] {
        var turns: [(user: Bool, text: String)] = []
        for item in chat.transcript.items.suffix(8) {
            switch item {
            case .user(let m) where !m.text.isEmpty: turns.append((true, String(m.text.prefix(800))))
            case .assistant(_, let text, _) where !text.isEmpty: turns.append((false, String(text.prefix(1200))))
            default: break
            }
        }
        return turns
    }

    // MARK: Receiving

    private func handle(_ e: GeminiWire.Event) {
        switch e {
        case .setupComplete:
            finishSetupWait(true)
        case .resumeHandle(let h):
            resumeHandle = h
        case .audio(let pcm):
            serverReplied()
            if !userTurnClosed { userTurnClosed = true }
            if modelTurnClosed { modelTurnClosed = false; spoken = ""; host?.liveSpoken("") }
            if let buf = GeminiWire.playbackBuffer(pcm) { audio.schedule(buf) }
            updatePhase()
        case .inputText(let t):
            if userTurnClosed { userTurnClosed = false; heard = "" }
            heard += t
            lastHeard = Date()
            host?.liveHeard(heard.trimmingCharacters(in: .whitespaces))
            updatePhase()
        case .outputText(let t):
            if modelTurnClosed { modelTurnClosed = false; spoken = "" }
            spoken += t
            host?.liveSpoken(spoken.trimmingCharacters(in: .whitespaces))
        case .interrupted:
            VoiceDiag.log("gemini: interrupted (barge-in)")
            audio.stopPlayback()
            modelTurnClosed = true
            host?.liveBargeIn()
            updatePhase()
        case .turnComplete:
            serverReplied()
            modelTurnClosed = true
            if waiting == 0, !chat.isRunning, !spoken.isEmpty {
                // Exchange over: the screen goes back to "Go ahead, I'm listening."
                heard = ""
                host?.liveHeard("")
            }
            updatePhase()
        case .toolCall(let id, let name, let args):
            serverReplied()
            VoiceDiag.log("gemini: tool \(name) id=\(id) args=\(args.mapValues { String($0.prefix(120)) })")
            Task { await runTool(id: id, name: name, args: args) }
        case .toolCancel(let ids):
            VoiceDiag.log("gemini: tool calls cancelled \(ids)")
            cancelledCalls.formUnion(ids)
        case .goAway:
            VoiceDiag.log("gemini: goAway; reconnecting with resumption")
            let old = socket
            Task {
                await reconnect()
                old?.cancel(with: .normalClosure, reason: nil)
            }
        case .error(let m):
            VoiceDiag.log("gemini: server error \(m)")
        }
    }

    // MARK: Tools → the agent

    private func runTool(id: String, name: String, args: [String: String]) async {
        let result: String
        var scheduling = "WHEN_IDLE"
        switch name {
        case "ask_otto":
            let request = (args["request"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !request.isEmpty else { result = "No request given."; break }
            if chat.isRunning {
                // Mid-task correction: it goes to the running agent as a steer; the answer comes with
                // the call that started the task.
                await chat.send(OutgoingMessage(text: request, voice: true))
                result = "Sent to the agent as an update to the task it's already working on. Its answer will come with that task."
                scheduling = "SILENT"
            } else {
                result = await askAgent(request, callID: id)
            }
        case "web_search", "weather":
            // Blocking functions: Gemini waits for these, so answer right away when they land.
            let kind: VoiceLookup = name == "web_search" ? .search : .weather
            let value = (args[kind.field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                result = try await companion.voiceLookup(kind, value)
            } catch {
                result = "The \(kind == .search ? "web search" : "weather lookup") failed (\(error.localizedDescription)). Say you couldn't look it up."
            }
            scheduling = "INTERRUPT"
        case "stop_otto":
            if chat.isRunning {
                await chat.stop()
                result = "Stopped the agent."
            } else {
                result = "Nothing was running."
            }
        case "otto_command":
            let cmd = (args["command"] ?? "").trimmingCharacters(in: .whitespaces)
            let r = await host?.liveCommand(cmd.hasPrefix("/") ? cmd : "/" + cmd) ?? VoiceCommandResult(reply: "Not available.")
            result = r.reply
            if let then = r.then {
                Task { try? await Task.sleep(for: .seconds(2.5)); then() }
            }
        default:
            result = "Unknown function \(name)."
        }
        guard !cancelledCalls.contains(id) else { return }
        VoiceDiag.log("gemini: tool \(name) -> \(result.count) chars: \"\(result.prefix(100))\"")
        if let msg = GeminiWire.toolResponse(id: id, name: name, result: result, scheduling: scheduling) { send(msg) }
    }

    /// Starts a turn in this chat and waits for the agent's answer. While it works, Gemini gets
    /// throttled progress (`AgentProgress`) as extra responses for the same call (willContinue). The
    /// answer is handed over the moment `run.completed` lands (it carries the final text).
    private func askAgent(_ request: String, callID: String) async -> String {
        waiting += 1
        updatePhase()
        defer { waiting -= 1; updatePhase() }
        let before = lastAssistant()?.id
        await chat.send(OutgoingMessage(text: request, voice: true))
        let started = Date()
        var progress = AgentProgress(started: started)
        var sawRun = chat.isRunning
        while !closed {
            if chat.isRunning { sawRun = true }
            if sawRun, !chat.isRunning || chat.transcript.terminalStatus != nil { break }
            if !sawRun, Date().timeIntervalSince(started) > 20 {
                return "Couldn't reach the agent (\(chat.errorMessage ?? "no connection")). Nothing was done."
            }
            if !sawRun, let e = chat.errorMessage { return "The agent couldn't start: \(e)" }
            if Date().timeIntervalSince(started) > 30 * 60 { return "The agent is still working; the answer will be in the chat." }
            if sawRun, !cancelledCalls.contains(callID),
               let u = progress.next(now: Date(), status: chat.liveStatus, interim: interimSinceRequest(),
                                     userTalking: userTalking) {
                VoiceDiag.log("gemini: progress \(u.scheduling) \"\(u.result.prefix(80))\"")
                if let msg = GeminiWire.toolResponse(id: callID, name: "ask_otto", result: u.result,
                                                     scheduling: u.scheduling, willContinue: true) { send(msg) }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let reply = lastAssistant(), reply.id != before, !reply.text.isEmpty else {
            return chat.errorMessage.map { "The agent stopped with an error: \($0)" } ?? "The agent finished without an answer."
        }
        return String(reply.text.prefix(6000))
    }

    /// John is speaking (Gemini transcribed him within the last 1.5 s and hasn't answered yet).
    private var userTalking: Bool {
        !userTurnClosed && Date().timeIntervalSince(lastHeard) < 1.5
    }

    /// The newest finished agent message of the current turn (what it said between tools), if any.
    private func interimSinceRequest() -> String? {
        for item in chat.transcript.items.reversed() {
            switch item {
            case .user(let m) where !m.isSteer: return nil
            case .assistant(_, let text, let streaming) where !streaming && !text.isEmpty: return text
            default: continue
            }
        }
        return nil
    }

    private func lastAssistant() -> (id: String, text: String)? {
        for item in chat.transcript.items.reversed() {
            if case .assistant(let id, let text, _) = item { return (id, text) }
            if case .user = item { return nil }
        }
        return nil
    }

    // MARK: Phase + levels

    func micLevel(db: Float, duration: TimeInterval = VoiceLogic.NoiseFloor.defaultDuration) {
        if !connected { preRoom.observe(db, playing: false, duration: duration) }
        micLevel = max(0, min(1, (db + 50) / 40))
        if !audio.isPlaying { host?.liveLevel(muted ? 0 : micLevel) }
    }

    func outputLevel(_ l: Float) {
        outLevel = l
        if audio.isPlaying { host?.liveLevel(l) }
    }

    private func updatePhase() {
        guard !closed, connected || setupWaiter == nil else { return }
        if audio.isPlaying { host?.liveSetPhase(.speaking) }
        else if muted { host?.liveSetPhase(.paused) }
        else if waiting > 0 || chat.isRunning, heard.isEmpty || userTurnClosed { host?.liveSetPhase(.thinking) }
        else { host?.liveSetPhase(.listening) }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                // Cancelled by close() mid-sleep: don't restart the engine (the mic stayed on after voice ended).
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.updatePhase()
                if !self.audio.isRunning, !self.muted {
                    VoiceDiag.log("gemini: engine stopped; recovering")
                    self.audio.configureSession()
                    self.audio.recover()
                }
            }
        }
    }

    #if DEBUG
    func debugSendText(_ text: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: ["clientContent": [
            "turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": true]]) else { return }
        heard = text
        host?.liveHeard(text)
        send(d)
    }
    #endif

    /// You've said something and haven't been answered yet.
    var userTurnOpen: Bool { endpointer.heardSpeech || endpointer.active || (!userTurnClosed && !heard.isEmpty) }

    /// Orb tap. While Otto talks: cut it off locally (the server learns when you speak). While you
    /// talk: send now (end your turn without waiting for the pause). Returns true if it sent.
    @discardableResult
    func tap() -> Bool {
        if audio.isPlaying {
            audio.stopPlayback()
            modelTurnClosed = true
            host?.liveBargeIn()
            updatePhase()
            return false
        }
        if turns == .client {
            let sent = tapClientTurn()
            updatePhase()
            return sent
        }
        let sent = userTurnOpen
        if sent { endTurn(reason: "tap") }
        updatePhase()
        return sent
    }

    /// Tap in noisy-room mode: close the open turn now. If none is open (his voice never rose far
    /// enough over the room to start one), send what the mic heard since the last turn (<= 8 s).
    private func tapClientTurn() -> Bool {
        if endpointer.active {
            endpointer.endTurn()
            finishClientTurn(reason: "tap")
            return true
        }
        guard engine == .gemini, connected, !switching else { return false }
        let since = max(lastTurnEnd, Date().addingTimeInterval(-8))
        let chunks = recentChunks.filter { $0.at > since }.map(\.pcm)
        guard chunks.count >= 5 else { return false }
        send(GeminiWire.activityStart)
        for c in chunks { send(GeminiWire.audioMessage(c)) }
        VoiceDiag.log("gemini: tap with no open turn: sent the last \(chunks.count * 100) ms")
        finishClientTurn(reason: "tap, replayed")
        return true
    }
}
