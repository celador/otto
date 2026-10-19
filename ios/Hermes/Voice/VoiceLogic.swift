import Foundation

/// Pure decisions behind voice mode (endpointing, barge-in, voice activity, what to speak next),
/// kept free of audio and UI so they can be unit-tested.
enum VoiceLogic {

    // MARK: End of turn (adaptive endpointing)

    /// Words that mean the speaker hasn't finished ("book a table for two and…").
    nonisolated static let continuationWords: Set<String> = [
        "and", "or", "but", "so", "because", "cause", "the", "a", "an", "to", "of", "with", "for", "in", "on",
        "at", "by", "from", "into", "about", "than", "as", "if", "then", "that", "which", "who", "my", "your",
        "his", "her", "their", "our", "its", "is", "are", "was", "were", "be", "um", "uh", "er", "erm", "hmm",
        "like", "also", "plus", "maybe", "just", "some", "any", "this", "these", "those", "when", "where",
        "while", "until", "can", "could", "would", "should", "will", "i'm", "i", "we", "you", "it's", "let's",
    ]

    enum Pause: Equatable { case complete, likelyComplete, unsure, midPhrase }

    /// How finished the partial transcript looks.
    nonisolated static func pause(after transcript: String, stableUpdates: Int) -> Pause {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return .midPhrase }
        if last == "," || last == "-" || last == "…" || last == ":" { return .midPhrase }
        // A trailing "my", "and", "the"… means you're mid-thought even when the recognizer
        // stuck punctuation on it ("Do you have access to my?").
        if let word = lastWord(t), continuationWords.contains(word) { return .midPhrase }
        if ".?!".contains(last) { return .complete }
        return stableUpdates >= 2 ? .likelyComplete : .unsure
    }

    /// Seconds of quiet that end your turn. Patient on purpose: people pause mid-thought (walking,
    /// thinking), and a turn sent too early ("Trying to find a") costs a whole wasted reply.
    nonisolated static func endOfTurnDelay(after transcript: String, stableUpdates: Int) -> TimeInterval {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if isStopCommand(t) { return 0.5 }
        if isTooShortToSend(t) { return shortHold }
        if isShortAnswer(t) { return 1.2 }
        switch pause(after: t, stableUpdates: stableUpdates) {
        case .complete: return 2.0
        case .likelyComplete, .unsure: return 2.6
        case .midPhrase: return 3.5
        }
    }

    /// A one- or two-word fragment ("Anything", "Working") waits this long before it's sent on its own.
    nonisolated static let shortHold: TimeInterval = 5.0

    /// "Yes", "Go ahead", "Thank you": complete on their own, so they go quickly.
    nonisolated static func isShortAnswer(_ utterance: String) -> Bool {
        shortAnswers.contains(normalizedWords(utterance).joined(separator: " "))
    }

    /// Short answers that are complete on their own.
    nonisolated static let shortAnswers: Set<String> = [
        "yes", "no", "yeah", "yep", "yup", "nope", "nah", "sure", "ok", "okay", "thanks", "thank you", "go ahead",
        "do it", "perfect", "great", "correct", "right", "exactly", "sounds good", "got it", "cool", "nice",
        "please", "both", "neither", "the first", "the second", "first one", "second one", "all of them",
    ]

    /// ≤ 2 words that aren't a stop word, a question or a known short answer: probably the start of a
    /// sentence the speaker paused in.
    nonisolated static func isTooShortToSend(_ utterance: String) -> Bool {
        let t = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalizedWords(t)
        guard !words.isEmpty, words.count <= 2 else { return false }
        if t.hasSuffix("?") || isStopCommand(t) { return false }
        if words.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        return !shortAnswers.contains(words.joined(separator: " "))
    }

    /// Whether to end the turn now. `sinceWords` = time since the transcript last changed,
    /// `sinceVoice` = time since the mic last heard voice (keeps a long word from being cut off).
    nonisolated static func shouldEndTurn(transcript: String, stableUpdates: Int,
                                          sinceWords: TimeInterval, sinceVoice: TimeInterval,
                                          turnAge: TimeInterval = 0) -> Bool {
        endTurnReason(transcript: transcript, stableUpdates: stableUpdates, sinceWords: sinceWords,
                      sinceVoice: sinceVoice, turnAge: turnAge) != nil
    }

    /// A turn never runs longer than this (s since its first words): in a loud room the recognizer
    /// can keep transcribing other people. It sends what it has at the next breath.
    nonisolated static let maxTurn: TimeInterval = 25
    nonisolated static let hardMaxTurn: TimeInterval = 35

    /// Why the turn should end now (for the voice log), or nil to keep listening.
    nonisolated static func endTurnReason(transcript: String, stableUpdates: Int, sinceWords: TimeInterval,
                                          sinceVoice: TimeInterval, turnAge: TimeInterval = 0) -> String? {
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let delay = endOfTurnDelay(after: words, stableUpdates: stableUpdates)
        if turnAge >= hardMaxTurn || (turnAge >= maxTurn && sinceVoice >= 0.3) { return "max \(Int(maxTurn))s" }
        // Recognizer stuck (noise keeps the voice detector on, nothing new transcribed).
        if sinceWords >= max(7.0, delay + 2) { return "stuck" }
        if sinceWords >= max(3.0, delay + 0.8) && sinceVoice >= 0.3 { return "quiet (late)" }
        return sinceWords >= delay && sinceVoice >= min(delay, 0.6) ? "quiet \(delay)s" : nil
    }

    /// A noisy room: the floor is above this (dBFS). There, a transcript change only counts as you
    /// still talking if the mic heard near-field voice with it (`countsAsTalking`).
    nonisolated static let noisyFloor: Float = -45

    /// Whether a new transcript means you're still talking. In a loud room the recognizer also
    /// transcribes people nearby; their words come without a voiced burst above the (adapted) floor,
    /// since your near-field voice is ~10 dB over the babble (1 s allows for recognizer latency). The
    /// first words of a turn always count.
    nonisolated static func countsAsTalking(firstWords: Bool, sinceVoice: TimeInterval, floor: Float) -> Bool {
        firstWords || floor <= noisyFloor || sinceVoice <= 1.0
    }

    // MARK: Stop words and what an interruption means

    nonisolated static let stopCores: Set<String> = [
        "stop", "cancel", "wait", "hold", "nevermind", "enough", "quiet", "pause", "shush", "abort",
    ]
    nonisolated static let stopFillers: Set<String> = [
        "please", "ok", "okay", "on", "never", "mind", "it", "that", "now", "hey", "otto", "no", "a", "sec",
        "second", "minute", "up", "shut", "just", "be", "right", "there", "all", "thats", "that's", "talking",
    ]

    /// "Stop", "wait", "cancel that", "hold on", "never mind" — but not "wait, make it Tuesday".
    nonisolated static func isStopCommand(_ utterance: String) -> Bool {
        let words = normalizedWords(utterance)
        guard !words.isEmpty, words.count <= 5 else { return false }
        let joined = words.joined(separator: " ")
        let hasCore = words.contains { stopCores.contains($0) } || joined.contains("never mind")
            || joined.contains("shut up")
        return hasCore && words.allSatisfy { stopCores.contains($0) || stopFillers.contains($0) }
    }

    enum TurnAction: Equatable {
        /// A new turn (nothing is running).
        case send
        /// The agent is still working: add this to the running turn.
        case steer
        /// "Stop" while the agent works: stop the run.
        case stopRun
        /// "Stop" while it was only talking: stop talking, send nothing.
        case dismiss
    }

    nonisolated static func turnAction(utterance: String, runActive: Bool) -> TurnAction {
        if isStopCommand(utterance) { return runActive ? .stopRun : .dismiss }
        return runActive ? .steer : .send
    }

    // MARK: Barge-in (talking over the reply)

    /// Whether what the mic picked up should interrupt. `voiced` = seconds of sustained voice above the
    /// noise floor; `heard` = recognizer text since playback started; `playing` = the reply's text being spoken.
    nonisolated static func shouldBargeIn(voiced: TimeInterval, heard: String, playing: String,
                                          audioPlaying: Bool) -> Bool {
        let words = normalizedWords(heard)
        guard !words.isEmpty else { return false }
        // Judge the newest words: echo the recognizer caught earlier mustn't mask you starting to talk.
        let recent = words.suffix(4).joined(separator: " ")
        // "…sunny in Lisbon stop": the newest words are a stop command → judge just those.
        if voiced >= 0.15,
           let stop = (1...min(5, words.count)).lazy.map({ words.suffix($0).joined(separator: " ") }).first(where: isStopCommand) {
            return !looksLikeEcho(heard: stop, playing: playing)
        }
        if !audioPlaying { return voiced >= 0.2 && words.count >= 2 }   // thinking: nothing to echo
        guard voiced >= 0.3, words.count >= 2 else { return false }
        return !looksLikeEcho(heard: recent, playing: playing)
    }

    /// True when most recognized words are just the reply leaking back into the mic.
    nonisolated static func looksLikeEcho(heard: String, playing: String) -> Bool {
        let h = normalizedWords(heard)
        guard !h.isEmpty else { return false }
        let spoken = Set(normalizedWords(playing))
        guard !spoken.isEmpty else { return false }
        let hits = h.filter { spoken.contains($0) }.count
        return Double(hits) / Double(h.count) >= 0.6
    }

    /// Drops a leading run of reply words the recognizer caught before you spoke
    /// ("sunny in lisbon wait make it tuesday" → "wait make it tuesday").
    nonisolated static func stripEcho(heard: String, playing: String) -> String {
        let raw = heard.split(whereSeparator: \.isWhitespace).map(String.init)
        let norm = raw.map { normalize($0) }
        let spoken = normalizedWords(playing)
        guard raw.count >= 2, spoken.count >= 2 else { return heard }
        var best = 0
        // Longest prefix of `heard` that appears contiguously in the reply.
        for n in stride(from: min(norm.count - 1, spoken.count), through: 2, by: -1) {
            let prefix = Array(norm.prefix(n))
            if containsRun(spoken, prefix) { best = n; break }
        }
        guard best > 0 else { return heard }
        return raw.dropFirst(best).joined(separator: " ")
    }

    // MARK: Voice activity (adaptive noise floor)

    struct NoiseFloor: Equatable {
        /// Estimated background level, dBFS.
        private(set) var floor: Float = -60
        private(set) var calibrated = false
        private var samples: [Float] = []
        private var calibrationTime: TimeInterval = 0
        /// Recent levels (not while the reply plays) and their durations, for the percentile tracker.
        private var windowLevels: [Float] = []
        private var windowDurations: [TimeInterval] = []
        private var windowTime: TimeInterval = 0
        /// "Voice" on without a 0.3 s gap for this long.
        private var sustained: TimeInterval = 0
        private var gap: TimeInterval = 0

        /// Buffers used to learn the room before voice detection starts (~0.5 s at 1024/48k).
        nonisolated static let calibrationBuffers = 24
        nonisolated static let defaultDuration: TimeInterval = 1024.0 / 48_000
        nonisolated static let calibrationSeconds: TimeInterval = 0.5
        /// Seconds of levels the percentile tracker looks at.
        nonisolated static let window: TimeInterval = 4
        /// "Voice" this long without a level drop is the room (babble, PA, engine), not a person.
        nonisolated static let sustainedNoise: TimeInterval = 2.5
        nonisolated static let percentile: Float = 0.2
        /// Time constants (s): toward that percentile; down to a quieter room; creeping up.
        nonisolated static let tauPercentile: TimeInterval = 1.5
        nonisolated static let tauDown: TimeInterval = 0.2   // 0.1 per 21 ms buffer
        nonisolated static let tauUp: TimeInterval = 2.1     // 0.01 per 21 ms buffer
        nonisolated static let maxFloor: Float = -20

        nonisolated init() {}

        /// Above this, the mic hears a voice. While the reply plays, echo residue needs a higher bar.
        nonisolated func threshold(playing: Bool) -> Float {
            max(floor + (playing ? 16 : 10), playing ? -44 : -52)
        }

        nonisolated func describe() -> String { calibrated ? "\(Int(floor.rounded()))dB" : "calibrating" }

        nonisolated func isVoice(_ db: Float, playing: Bool) -> Bool {
            calibrated && db >= threshold(playing: playing)
        }

        /// The room's typical level over the last few seconds (babble sits a few dB over the floor).
        nonisolated var median: Float? {
            guard !windowLevels.isEmpty else { return nil }
            return windowLevels.sorted()[windowLevels.count / 2]
        }

        /// Feeds one buffer's level; returns whether it was voice.
        @discardableResult
        nonisolated mutating func observe(_ db: Float, playing: Bool,
                                          duration: TimeInterval = NoiseFloor.defaultDuration) -> Bool {
            let db = max(-100, min(0, db))
            if !calibrated {
                samples.append(db)
                calibrationTime += duration
                if calibrationTime >= Self.calibrationSeconds - 1e-6, samples.count >= 5 {
                    // Median: robust to the first word or a door slam during calibration.
                    let sorted = samples.sorted()
                    floor = min(Self.maxFloor, sorted[sorted.count / 2])
                    calibrated = true
                    samples = []
                }
                return false
            }
            let voice = isVoice(db, playing: playing)
            if db < floor {
                floor += (db - floor) * Self.rate(duration, Self.tauDown)       // quieter room: follow quickly
            } else if !voice && !playing {
                floor += (db - floor) * Self.rate(duration, Self.tauUp)         // louder room: creep up
            }
            if !playing {
                windowLevels.append(db)
                windowDurations.append(duration)
                windowTime += duration
                while let first = windowDurations.first, windowTime - first >= Self.window {
                    windowTime -= first
                    windowDurations.removeFirst()
                    windowLevels.removeFirst()
                }
                if voice {
                    sustained += duration
                    gap = 0
                } else {
                    gap += duration
                    if gap >= 0.3 { sustained = 0 }
                }
                // Steady babble above floor+10 used to stay "voice" forever with the floor stuck at
                // its calibration value. Voice that never drops for 2.5 s is the room: move the floor
                // toward the quiet end (20th percentile) of the last 4 s.
                if sustained >= Self.sustainedNoise {
                    let sorted = windowLevels.sorted()
                    let p = sorted[Int(Float(sorted.count) * Self.percentile)]
                    if p > floor { floor += (p - floor) * Self.rate(duration, Self.tauPercentile) }
                }
            }
            floor = max(-90, min(Self.maxFloor, floor))
            return voice
        }

        nonisolated private static func rate(_ duration: TimeInterval, _ tau: TimeInterval) -> Float {
            Float(1 - exp(-duration / tau))
        }
    }

    /// Seconds of sustained voice, with a short hangover so gaps between syllables don't reset it.
    struct VoicedRun: Equatable {
        private(set) var voiced: TimeInterval = 0
        private var quiet: TimeInterval = 0

        nonisolated init() {}

        nonisolated mutating func add(isVoice: Bool, duration: TimeInterval) {
            if isVoice {
                voiced += duration
                quiet = 0
            } else {
                quiet += duration
                if quiet >= 0.3 { voiced = 0 }
            }
        }

        nonisolated mutating func reset() { voiced = 0; quiet = 0 }
    }

    // MARK: What to speak next

    /// Splits off text ready to speak from a growing reply. The first chunk is kept short so audio starts
    /// sooner: the first sentence, or its first clause when that sentence is long. Later chunks group
    /// sentences to ~60+ chars. `flush` (reply finished) returns everything left.
    nonisolated static func nextChunk(_ s: String, flush: Bool, isFirst: Bool) -> (String, Int) {
        let chars = Array(s)
        var end = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if ".!?\n".contains(c), i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" {
                end = i + 1
                if isFirst || end >= 60 { break }
            }
            i += 1
        }
        if isFirst {
            // A long first sentence (or a long unfinished one): speak its first clause now.
            let limit = end > 0 ? end : chars.count
            if limit > 90, let comma = firstClauseEnd(chars, from: 25, to: min(limit, 140)) {
                return (String(chars[0..<comma]).trimmingCharacters(in: .whitespacesAndNewlines), comma)
            }
        }
        if flush { return (s.trimmingCharacters(in: .whitespacesAndNewlines), s.count) }
        guard end > 0 else { return ("", 0) }
        return (String(chars[0..<end]).trimmingCharacters(in: .whitespacesAndNewlines), end)
    }

    /// Index just past the first ", " / "; " / " — " between `from` and `to`.
    nonisolated private static func firstClauseEnd(_ chars: [Character], from: Int, to: Int) -> Int? {
        guard from < to else { return nil }
        for i in from..<min(to, chars.count - 1) where ",;—".contains(chars[i]) && chars[i + 1] == " " {
            return i + 1
        }
        return nil
    }

    // MARK: Spoken commands ("switch your model to haiku", "new chat")

    /// The slash command a spoken utterance means, or nil for a normal message. Only short, whole
    /// requests count, so "tell me about switching the model in Xcode" still goes to the agent.
    nonisolated static func voiceCommand(_ utterance: String) -> String? {
        var t = utterance.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !t.isEmpty, normalizedWords(t).count <= 12 else { return nil }
        // Politeness/wake words in front and behind.
        let lead = #"^(?:(?:hey|hi|ok|okay|so|um|uh|otto|please|now|and|alright|all right)[,\s]+)*"#
            + #"(?:(?:can|could|would|will) you(?: please)?\s+|please\s+|i want you to\s+|i'd like you to\s+|let's\s+)?"#
        t = t.replacingOccurrences(of: lead, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[,\s]+(?:please|thanks|thank you|otto)$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        let verbs = "(?:change|switch|set|swap|move|put|use)"
        let patterns = [
            // "change your model to haiku", "switch the model over to sonnet 4.5"
            verbs + #"\s+(?:your|the|my|this chat's|the chat's)?\s*model\s+(?:over\s+)?(?:to|for|with)\s+(?:the\s+)?(.+?)(?:\s+model)?$"#,
            // "switch to the haiku model", "use the opus model"
            verbs + #"\s+(?:over\s+)?(?:to\s+)?(?:the\s+)?(.+?)\s+model$"#,
            // "model haiku"
            #"^model\s+(.+)$"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: "^" + p.replacingOccurrences(of: "^", with: ""), options: []),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range(at: 1), in: t) {
                let name = t[r].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard !name.isEmpty, normalizedWords(name).count <= 4,
                      !["a", "another", "a different", "different", "the", "my", "your"].contains(name) else { continue }
                return "/model " + name
            }
        }
        let newChat = #"^(?:start|open|make|begin|create)?\s*(?:a\s+)?(?:new|fresh)\s+(?:chat|conversation|session|thread)(?:\s+please)?$"#
        if t.range(of: newChat, options: .regularExpression) != nil { return "/new" }
        return nil
    }

    /// "claude-haiku-4-5-20251001" → "claude haiku 4.5" (what Otto says back).
    nonisolated static func spokenModelName(_ model: String) -> String {
        var t = model.split(separator: "/").last.map(String.init) ?? model
        t = t.replacingOccurrences(of: #"[-_]\d{8}$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\d+)[-_](\d+)"#, with: "$1.$2", options: .regularExpression)
        return t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Reply bookkeeping

    /// The reply message changed id (the streamed message was replaced by the stored one when the run
    /// ended, or split around tool calls). Returns how many characters of `new` were already queued for
    /// speech, given that the first `spokenUpTo` characters of `old` were; nil when `new` is a different
    /// message (e.g. the answer after a steer), which is then spoken from its start.
    nonisolated static func carriedOffset(old: String, spokenUpTo: Int, new: String) -> Int? {
        let oldTokens = tokens(old)
        let newTokens = tokens(new)
        guard !oldTokens.isEmpty, !newTokens.isEmpty else { return nil }
        let spokenWords = oldTokens.filter { $0.end <= spokenUpTo }.count
        // Where does `new` start inside `old`? (0 = same message; later = the stored tail of it.)
        let probe = Array(newTokens.prefix(min(4, newTokens.count)).map(\.word))
        let oldWords = oldTokens.map(\.word)
        guard probe.count <= oldWords.count,
              let start = (0...(oldWords.count - probe.count)).first(where: { Array(oldWords[$0..<($0 + probe.count)]) == probe })
        else { return nil }
        let consumed = spokenWords - start
        if consumed <= 0 { return 0 }
        if consumed >= newTokens.count { return new.count }
        // Past the last consumed word and its trailing punctuation.
        let chars = Array(new)
        var end = newTokens[consumed - 1].end
        while end < chars.count, !chars[end].isWhitespace, !chars[end].isLetter, !chars[end].isNumber { end += 1 }
        return end
    }

    /// Words of `s` (normalized) with the character offset just past each.
    nonisolated static func tokens(_ s: String) -> [(word: String, end: Int)] {
        var out: [(String, Int)] = []
        var current = ""
        var i = 0
        func flush() {
            let w = normalize(current)
            if !w.isEmpty { out.append((w, i)) }
            current = ""
        }
        for c in s.replacingOccurrences(of: "’", with: "'") {
            if c.isWhitespace || c == "," || c == "." || c == "!" || c == "?" { flush() } else { current.append(c) }
            i += 1
        }
        flush()
        return out
    }

    // MARK: Helpers

    nonisolated static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == "'" })
            .replacingOccurrences(of: "’", with: "'")
    }

    nonisolated static func normalizedWords(_ s: String) -> [String] {
        s.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "!" || $0 == "?" })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func lastWord(_ s: String) -> String? {
        normalizedWords(s).last
    }

    nonisolated private static func containsRun(_ hay: [String], _ needle: [String]) -> Bool {
        guard needle.count <= hay.count else { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
