import Foundation

/// Hands-free conversation on the watch: one tap starts it, then listen → answer → listen again
/// until you go quiet, tap, or say goodbye. The decisions live here (no audio, no UI) so the
/// iPhone test target can check them; `WatchModel` drives the recorder and speaker from them.
enum WatchTalkLoop {
    /// You paused this long after talking: your turn is over and it's sent.
    static let endOfTurnSilence: TimeInterval = 2.0
    /// The mic reopened and you said nothing for this long: the conversation ends.
    static let idleTimeout: TimeInterval = 8
    /// Ignore the first moment of a turn (the start haptic, the wrist settling) when ending it.
    static let minimumTurn: TimeInterval = 1.2
    /// A turn can't run longer than this (keeps the clip small enough to cross to the phone).
    static let maxTurn: TimeInterval = 30
    /// "Didn't catch that" this many times in a row ends the conversation instead of looping.
    static let maxMisses = 2

    enum Phase: Equatable { case idle, listening, sending, thinking, speaking, error }

    enum TapAction: Equatable {
        /// Start a conversation.
        case start
        /// Talk over the reply: it stops and the mic opens (the conversation goes on).
        case interrupt
        /// Send what you said now; the reply is the last one.
        case sendAndEnd
        /// Stop now.
        case end
        /// Otto is working: let the answer come, then stop instead of listening again.
        case endAfterReply
    }

    static func tapAction(phase: Phase, looping: Bool, heardVoice: Bool) -> TapAction {
        switch phase {
        case .idle, .error: return .start
        case .speaking: return .interrupt
        case .listening: return heardVoice ? .sendAndEnd : .end
        case .sending, .thinking: return looping ? .endAfterReply : .end
        }
    }

    /// After a reply has been delivered (and spoken, if replies are spoken): open the mic again?
    static func reopensMic(looping: Bool, endAfterReply: Bool, interrupted: Bool) -> Bool {
        looping && !endAfterReply && !interrupted
    }

    enum EndReason: Equatable { case silence, tap, goodbye, misses, failure }

    /// What to show once the conversation is over.
    static func endLine(_ reason: EndReason) -> String {
        switch reason {
        case .silence: "Ended after a quiet moment · tap to talk"
        case .tap: "Conversation ended · tap to talk"
        case .goodbye: "Bye for now · tap to talk"
        case .misses: "I couldn't hear you · tap to try again"
        case .failure: "Tap to try again"
        }
    }

    // MARK: End of turn

    enum Decision: Equatable { case keepListening, endTurn, noSpeech }

    /// Voice detection relative to the room: a watch mic on the wrist is far quieter than a phone at
    /// your mouth, so the first half second sets the noise floor and voice is ~10 dB above it.
    struct Meter: Equatable {
        var noiseFloor: Float = -60
        var samples = 0
        var heardVoice = false
        var quietFor: TimeInterval = 0
        var level: Float = 0

        /// One meter reading (`step` seconds apart) at `t` seconds into the turn.
        mutating func feed(db: Float, at t: TimeInterval, step: TimeInterval = 0.1) -> Decision {
            samples += 1
            if samples <= 5 {
                noiseFloor = samples == 1 ? db : min(noiseFloor, db)
                return .keepListening
            }
            let threshold = max(noiseFloor + 10, -52)
            level = max(0, min(1, (db - noiseFloor) / 30))
            if db > threshold { heardVoice = true; quietFor = 0 } else { quietFor += step }
            if heardVoice {
                if quietFor >= WatchTalkLoop.endOfTurnSilence && t > WatchTalkLoop.minimumTurn { return .endTurn }
                if t >= WatchTalkLoop.maxTurn { return .endTurn }
            } else if t >= WatchTalkLoop.idleTimeout {
                return .noSpeech
            }
            return .keepListening
        }
    }

    // MARK: Goodbye

    static let goodbyeCores: Set<String> = [
        "stop", "bye", "goodbye", "byebye", "cancel", "enough", "done", "end", "finished", "quit", "nevermind",
    ]
    static let goodbyeFillers: Set<String> = [
        "ok", "okay", "otto", "hey", "please", "you", "that's", "thats", "it", "all", "for", "now", "i'm", "im",
        "we're", "were", "i", "am", "we", "are", "that", "is", "good", "great", "cool", "so", "then", "never",
        "mind", "talking", "conversation", "the", "a", "lot", "much", "very", "see", "ya", "later", "bye",
        "no", "nothing", "else", "just", "and", "alright", "right", "thanks", "thank",
    ]

    /// "Stop", "bye", "goodbye Otto", "that's all", "thanks, that's it", "I'm done" end the conversation;
    /// "stop the timer", "thanks, now book it" or a plain "thanks" are part of it and go to Otto.
    static func isGoodbye(_ utterance: String) -> Bool {
        let words = utterance.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "bye-bye", with: "byebye")
            .replacingOccurrences(of: "bye bye", with: "byebye")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 6 else { return false }
        let joined = words.joined(separator: " ")
        let hasCore = words.contains { goodbyeCores.contains($0) } || joined.contains("that's all")
            || joined.contains("thats all") || joined.contains("that's it") || joined.contains("thats it")
            || joined.contains("never mind") || joined == "see you" || joined.contains("see you later")
        return hasCore && words.allSatisfy { goodbyeCores.contains($0) || goodbyeFillers.contains($0) || $0 == "see" }
    }

    // MARK: Audio route

    /// AirPods and other Bluetooth headphones, by `AVAudioSession.Port` raw value.
    static func isBluetooth(port: String) -> Bool {
        ["BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE"].contains(port)
    }
}
