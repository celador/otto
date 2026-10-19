import AVFoundation
import Foundation
import Testing
@testable import Hermes

/// Pure logic behind full-duplex voice mode. Nothing here touches audio.
@Suite struct VoiceLogicTests {

    // MARK: Endpointing

    @Test func finishedSentencesEndTheTurnSooner() {
        #expect(VoiceLogic.pause(after: "What's the weather tomorrow?", stableUpdates: 0) == .complete)
        #expect(VoiceLogic.pause(after: "Book a table for two and", stableUpdates: 3) == .midPhrase)
        #expect(VoiceLogic.pause(after: "Remind me to call, um", stableUpdates: 3) == .midPhrase)
        #expect(VoiceLogic.pause(after: "Send it to the", stableUpdates: 5) == .midPhrase)
        #expect(VoiceLogic.pause(after: "Turn off the lights,", stableUpdates: 5) == .midPhrase)
        #expect(VoiceLogic.pause(after: "Turn off the lights", stableUpdates: 0) == .unsure)
        #expect(VoiceLogic.pause(after: "Turn off the lights", stableUpdates: 2) == .likelyComplete)
        let done = VoiceLogic.endOfTurnDelay(after: "Is it raining?", stableUpdates: 0)
        let plain = VoiceLogic.endOfTurnDelay(after: "Turn off the lights", stableUpdates: 0)
        let mid = VoiceLogic.endOfTurnDelay(after: "Is it raining and", stableUpdates: 0)
        #expect(done == 2.0)
        #expect(plain == 2.6)
        #expect(mid == 3.5)
        #expect(VoiceLogic.endOfTurnDelay(after: "Remind me to call, um", stableUpdates: 0) == 3.5)
        #expect(VoiceLogic.endOfTurnDelay(after: "Turn off the lights,", stableUpdates: 0) == 3.5)
        // Recognizer punctuation on a dangling word doesn't make it finished (John, 2026-10-13).
        #expect(VoiceLogic.pause(after: "Do you have access to my?", stableUpdates: 0) == .midPhrase)
        #expect(VoiceLogic.pause(after: "Can you make me a.", stableUpdates: 0) == .midPhrase)
        // Real short answers still go fast.
        #expect(VoiceLogic.endOfTurnDelay(after: "Yes.", stableUpdates: 0) == 1.2)
    }

    @Test func turnEndsOnlyAfterTheRightPause() {
        let q = "Is it raining?"
        #expect(!VoiceLogic.shouldEndTurn(transcript: q, stableUpdates: 0, sinceWords: 0.7, sinceVoice: 0.7))
        #expect(!VoiceLogic.shouldEndTurn(transcript: q, stableUpdates: 0, sinceWords: 1.9, sinceVoice: 1.9))
        #expect(VoiceLogic.shouldEndTurn(transcript: q, stableUpdates: 0, sinceWords: 2.05, sinceVoice: 2.05))
        // Still voicing (a long word the recognizer hasn't caught yet): wait.
        #expect(!VoiceLogic.shouldEndTurn(transcript: q, stableUpdates: 0, sinceWords: 2.1, sinceVoice: 0.1))
        // No punctuation: 2.6 s.
        #expect(!VoiceLogic.shouldEndTurn(transcript: "Turn off the lights", stableUpdates: 3, sinceWords: 2.4, sinceVoice: 2.4))
        #expect(VoiceLogic.shouldEndTurn(transcript: "Turn off the lights", stableUpdates: 3, sinceWords: 2.7, sinceVoice: 2.7))
        // Mid-phrase needs the long pause.
        #expect(!VoiceLogic.shouldEndTurn(transcript: "Call my mom and", stableUpdates: 0, sinceWords: 2.7, sinceVoice: 2.7))
        #expect(!VoiceLogic.shouldEndTurn(transcript: "Call my mom and", stableUpdates: 0, sinceWords: 3.4, sinceVoice: 3.4))
        #expect(VoiceLogic.shouldEndTurn(transcript: "Call my mom and", stableUpdates: 0, sinceWords: 3.6, sinceVoice: 3.6))
        // Nothing said: never ends.
        #expect(!VoiceLogic.shouldEndTurn(transcript: "  ", stableUpdates: 9, sinceWords: 10, sinceVoice: 10))
        // "Stop" is quick.
        #expect(VoiceLogic.shouldEndTurn(transcript: "Stop", stableUpdates: 0, sinceWords: 0.55, sinceVoice: 0.55))
        // A stuck recognizer can't hold the turn open forever.
        #expect(VoiceLogic.shouldEndTurn(transcript: "and the", stableUpdates: 0, sinceWords: 7.1, sinceVoice: 0))
    }

    /// John walking home (build 55): "Trying to find a" and "Anything" went out while he was still talking.
    @Test func naturalPausesDontCutYouOff() {
        // Ends on an article: a 1.8 s pause isn't the end.
        #expect(!VoiceLogic.shouldEndTurn(transcript: "Trying to find a", stableUpdates: 3, sinceWords: 1.8, sinceVoice: 1.8))
        // One or two words that aren't an answer wait much longer.
        for s in ["Anything", "Working", "Trying to", "So"] {
            #expect(VoiceLogic.isTooShortToSend(s), "\(s)")
            #expect(!VoiceLogic.shouldEndTurn(transcript: s, stableUpdates: 5, sinceWords: 4.5, sinceVoice: 4.5), "\(s)")
            #expect(VoiceLogic.shouldEndTurn(transcript: s, stableUpdates: 5, sinceWords: 5.1, sinceVoice: 5.1), "\(s)")
        }
        // …but stop words, questions and real short answers go at the normal pace.
        for s in ["Stop", "Why?", "Yes", "No.", "Thank you", "Go ahead", "Sounds good", "42"] {
            #expect(!VoiceLogic.isTooShortToSend(s), "\(s)")
        }
        #expect(VoiceLogic.shouldEndTurn(transcript: "Yes.", stableUpdates: 0, sinceWords: 1.3, sinceVoice: 1.3))
        #expect(VoiceLogic.shouldEndTurn(transcript: "Why?", stableUpdates: 0, sinceWords: 2.1, sinceVoice: 2.1))
        #expect(!VoiceLogic.isTooShortToSend("Book a table"))
    }

    // MARK: Spoken commands

    @Test func spokenModelSwitchBecomesSlashModel() {
        #expect(VoiceLogic.voiceCommand("Hey, can you change your model to haiku?") == "/model haiku")
        #expect(VoiceLogic.voiceCommand("Switch the model to Sonnet") == "/model sonnet")
        #expect(VoiceLogic.voiceCommand("switch to the opus model please") == "/model opus")
        #expect(VoiceLogic.voiceCommand("Otto, set model to GPT 5") == "/model gpt 5")
        #expect(VoiceLogic.voiceCommand("Could you please use the haiku model") == "/model haiku")
        #expect(VoiceLogic.voiceCommand("Change your model to Claude Haiku 4.5.") == "/model claude haiku 4.5")
        #expect(VoiceLogic.voiceCommand("New chat") == "/new")
        #expect(VoiceLogic.voiceCommand("Let's start a new conversation.") == "/new")
        #expect(VoiceLogic.voiceCommand("Okay, start a new chat please") == "/new")
        // Normal messages stay messages.
        for s in ["How do I change the model in Xcode for my SwiftUI previews and tests?",
                  "What's the best model for coding?", "Tell me about new chat apps", "Change your model",
                  "Switch to a different model", "Anything new in the chat?"] {
            #expect(VoiceLogic.voiceCommand(s) == nil, "\(s)")
        }
        #expect(VoiceLogic.spokenModelName("claude-haiku-4-5-20251001") == "claude haiku 4.5")
        #expect(VoiceLogic.spokenModelName("anthropic/claude-sonnet-5-5") == "claude sonnet 5.5")
    }

    // MARK: Each sentence is spoken once

    /// Build 55 spoke every reply twice: the streamed message ("a-live-2") was replaced at run end by the
    /// stored one ("h73937"), and the new id restarted the reply from its beginning.
    @Test func storedCopyOfTheReplyKeepsItsPlace() {
        let streamed = "Yes, I'm here. But this is the first message I've received in this session, could you resend it?"
        let queued = "Yes, I'm here. But this is the first message I've received in this session,".count
        // Same text: continue exactly where we were.
        #expect(VoiceLogic.carriedOffset(old: streamed, spokenUpTo: queued, new: streamed) == queued)
        // Fully queued: nothing left to say.
        #expect(VoiceLogic.carriedOffset(old: streamed, spokenUpTo: streamed.count, new: streamed) == streamed.count)
        // Stored copy cleaned slightly differently (no curly quotes, extra space): still recognised.
        let stored = "Yes, I’m here.  But this is the first message I've received in this session, could you resend it? Thanks."
        let off = VoiceLogic.carriedOffset(old: streamed, spokenUpTo: queued, new: stored)!
        #expect(String(stored.dropFirst(off)).trimmingCharacters(in: .whitespaces) == "could you resend it? Thanks.")
        // Stored as two messages around a tool call; the last one is a tail of what streamed.
        let tail = "could you resend it?"
        #expect(VoiceLogic.carriedOffset(old: streamed, spokenUpTo: streamed.count, new: tail) == tail.count)
        #expect(VoiceLogic.carriedOffset(old: streamed, spokenUpTo: queued, new: tail) == 0)
        // A different message (the answer after a steer): spoken from its start.
        #expect(VoiceLogic.carriedOffset(old: streamed, spokenUpTo: queued, new: "Got it, Tuesday it is.") == nil)
    }

    // MARK: Stop words / barge-in decision

    @Test func recognisesStopCommands() {
        for s in ["Stop", "stop.", "Wait", "Cancel that", "Hold on", "Never mind", "OK stop", "Stop talking",
                  "Wait a sec", "Otto, stop", "Please stop", "Enough", "Shut up"] {
            #expect(VoiceLogic.isStopCommand(s), "\(s)")
        }
        for s in ["Wait, make it Tuesday", "Stop the timer on the oven please", "Don't stop", "", "What's up",
                  "Hold the meeting at three"] {
            #expect(!VoiceLogic.isStopCommand(s), "\(s)")
        }
    }

    @Test func interruptionMeansTheRightThing() {
        #expect(VoiceLogic.turnAction(utterance: "Stop", runActive: true) == .stopRun)
        #expect(VoiceLogic.turnAction(utterance: "Stop", runActive: false) == .dismiss)
        #expect(VoiceLogic.turnAction(utterance: "Actually make it Tuesday", runActive: true) == .steer)
        #expect(VoiceLogic.turnAction(utterance: "And what about Sunday?", runActive: false) == .send)
    }

    @Test func bargeInNeedsRealSpeechNotEcho() {
        let playing = "Saturday looks sunny in Lisbon, around twenty-seven degrees."
        // You talking over it.
        #expect(VoiceLogic.shouldBargeIn(voiced: 0.4, heard: "what about Sunday", playing: playing, audioPlaying: true))
        // Echo of the reply leaking into the mic.
        #expect(!VoiceLogic.shouldBargeIn(voiced: 0.6, heard: "sunny in Lisbon", playing: playing, audioPlaying: true))
        // A cough: voice energy, no words.
        #expect(!VoiceLogic.shouldBargeIn(voiced: 0.5, heard: "", playing: playing, audioPlaying: true))
        // One stray word while it talks isn't enough...
        #expect(!VoiceLogic.shouldBargeIn(voiced: 0.5, heard: "hmm", playing: playing, audioPlaying: true))
        // ...unless it's "stop".
        #expect(VoiceLogic.shouldBargeIn(voiced: 0.2, heard: "stop", playing: playing, audioPlaying: true))
        // Too short a burst.
        #expect(!VoiceLogic.shouldBargeIn(voiced: 0.1, heard: "what about Sunday", playing: playing, audioPlaying: true))
        // Lots of leaked echo earlier doesn't hide you starting to talk.
        #expect(VoiceLogic.shouldBargeIn(voiced: 0.4, heard: "Saturday looks sunny in Lisbon around what about Sunday",
                                         playing: playing, audioPlaying: true))
        #expect(VoiceLogic.shouldBargeIn(voiced: 0.2, heard: "sunny in Lisbon stop", playing: playing, audioPlaying: true))
        // While it's only thinking (nothing playing), any real speech counts.
        #expect(VoiceLogic.shouldBargeIn(voiced: 0.25, heard: "also check Sunday", playing: "", audioPlaying: false))
        // ...but a lone "hmm" while you wait isn't a steer.
        #expect(!VoiceLogic.shouldBargeIn(voiced: 0.25, heard: "hmm", playing: "", audioPlaying: false))
    }

    @Test func echoPrefixIsStrippedFromYourTurn() {
        let playing = "Saturday looks sunny in Lisbon, around twenty-seven degrees."
        #expect(VoiceLogic.stripEcho(heard: "sunny in Lisbon wait make it Tuesday", playing: playing) == "wait make it Tuesday")
        #expect(VoiceLogic.stripEcho(heard: "what about Sunday", playing: playing) == "what about Sunday")
        // A single shared word isn't treated as echo.
        #expect(VoiceLogic.stripEcho(heard: "Saturday is fine", playing: playing) == "Saturday is fine")
        #expect(VoiceLogic.looksLikeEcho(heard: "looks sunny in Lisbon", playing: playing))
        #expect(!VoiceLogic.looksLikeEcho(heard: "book me a flight to Lisbon", playing: playing))
    }

    // MARK: Voice activity

    @Test func noiseFloorAdaptsToTheRoom() {
        var quiet = VoiceLogic.NoiseFloor()
        for _ in 0..<VoiceLogic.NoiseFloor.calibrationBuffers { quiet.observe(-62, playing: false) }
        #expect(quiet.calibrated)
        #expect(!quiet.isVoice(-58, playing: false))
        #expect(quiet.isVoice(-40, playing: false))

        var noisy = VoiceLogic.NoiseFloor()
        for _ in 0..<VoiceLogic.NoiseFloor.calibrationBuffers { noisy.observe(-38, playing: false) }
        // A café: the same -40 dB is just the room.
        #expect(!noisy.isVoice(-40, playing: false))
        #expect(noisy.isVoice(-25, playing: false))
        // While the reply plays the bar is higher (echo residue).
        #expect(noisy.threshold(playing: true) > noisy.threshold(playing: false))
        // Nothing is voice before calibration.
        var fresh = VoiceLogic.NoiseFloor()
        let early = fresh.observe(-10, playing: false)
        #expect(!early)
    }

    @Test func calibrationIgnoresAStrayLoudBuffer() {
        var f = VoiceLogic.NoiseFloor()
        for i in 0..<VoiceLogic.NoiseFloor.calibrationBuffers { f.observe(i == 3 ? -15 : -60, playing: false) }
        #expect(f.floor < -55)
    }

    @Test func noiseFloorLearnsSustainedBabble() {
        // Calibrated in a quiet spot, then the terminal: babble at -40 dBFS that is "voice" by the
        // old floor. Before, the floor never moved and babble stayed voice forever.
        var f = VoiceLogic.NoiseFloor()
        for _ in 0..<VoiceLogic.NoiseFloor.calibrationBuffers { f.observe(-60, playing: false) }
        var g = SplitMix(seed: 9)
        for _ in 0..<(6 * 47) { f.observe(-40 + Float(g.unit() * 6 - 3), playing: false) }  // 6 s
        #expect(f.floor > -47)
        #expect(!f.isVoice(-40, playing: false))
        #expect(f.isVoice(-25, playing: false))
        // Quiet again: follows down quickly.
        for _ in 0..<47 { f.observe(-62, playing: false) }
        #expect(f.floor < -58)
    }

    @Test func babblePlusUtteranceEndsWithinTheDelayPlusASecond() {
        // Local engine in an airport: babble at -40 dBFS, a 2 s question at -25, and the recognizer
        // keeps transcribing people nearby afterwards. Simulates the session's bookkeeping.
        var noise = VoiceLogic.NoiseFloor()
        var g = SplitMix(seed: 3)
        let dt = VoiceLogic.NoiseFloor.defaultDuration
        var t: TimeInterval = 0
        var lastVoice = -100.0, heardChanged = 0.0, heard = "", firstWords: TimeInterval?
        var ended: TimeInterval?
        let speechStart = 4.0, speechEnd = 6.0
        var nextUpdate = speechStart + 0.4
        while t < 14, ended == nil {
            let talking = t >= speechStart && t < speechEnd
            let db: Float = talking ? -25 + Float(g.unit() * 4 - 2) : -40 + Float(g.unit() * 6 - 3)
            if noise.observe(db, playing: false, duration: dt) { lastVoice = t }
            // Recognizer: his words land ~0.4 s late; other people's every 0.7 s after he stops.
            var update: String?
            if t >= nextUpdate {
                if t < speechEnd + 0.4 {
                    update = String("What's the weather in Lisbon tomorrow?".prefix(Int((t - speechStart) * 16)))
                    nextUpdate = t + 0.3
                } else {
                    update = heard + " gate twelve"
                    nextUpdate = t + 0.7
                }
            }
            if let update, update != heard {
                let first = heard.isEmpty
                heard = update
                if first { firstWords = t }
                if VoiceLogic.countsAsTalking(firstWords: first, sinceVoice: t - lastVoice, floor: noise.floor) {
                    heardChanged = t
                }
            }
            if VoiceLogic.shouldEndTurn(transcript: heard, stableUpdates: 0, sinceWords: t - heardChanged,
                                        sinceVoice: t - lastVoice, turnAge: firstWords.map { t - $0 } ?? 0) {
                ended = t
            }
            t += dt
        }
        let end = try! #require(ended)
        #expect(end > speechEnd)
        let delay = VoiceLogic.endOfTurnDelay(after: heard, stableUpdates: 0)
        #expect(end - speechEnd <= delay + 1 + 0.4, "ended \(end - speechEnd) s after he stopped")
    }

    @Test func farFieldWordsCountOnlyInAQuietRoomOrWithVoice() {
        #expect(VoiceLogic.countsAsTalking(firstWords: true, sinceVoice: 9, floor: -38))
        #expect(!VoiceLogic.countsAsTalking(firstWords: false, sinceVoice: 3, floor: -38))
        #expect(VoiceLogic.countsAsTalking(firstWords: false, sinceVoice: 0.4, floor: -38))
        #expect(VoiceLogic.countsAsTalking(firstWords: false, sinceVoice: 3, floor: -60), "quiet room: unchanged")
    }

    @Test func turnHasAMaximumLength() {
        let s = "and then we went to the gate and"
        #expect(VoiceLogic.endTurnReason(transcript: s, stableUpdates: 0, sinceWords: 0.2, sinceVoice: 0.1, turnAge: 24) == nil)
        #expect(VoiceLogic.endTurnReason(transcript: s, stableUpdates: 0, sinceWords: 0.2, sinceVoice: 0.4, turnAge: 25.1) == "max 25s")
        #expect(VoiceLogic.endTurnReason(transcript: s, stableUpdates: 0, sinceWords: 0.2, sinceVoice: 0, turnAge: 35) == "max 25s")
    }

    @Test func voicedRunSurvivesShortGaps() {
        var r = VoiceLogic.VoicedRun()
        for _ in 0..<10 { r.add(isVoice: true, duration: 0.02) }
        r.add(isVoice: false, duration: 0.1)       // gap between syllables
        for _ in 0..<5 { r.add(isVoice: true, duration: 0.02) }
        #expect(abs(r.voiced - 0.3) < 0.001)
        r.add(isVoice: false, duration: 0.35)      // real silence
        #expect(r.voiced == 0)
    }

    // MARK: What to speak first

    @Test func mp3DecodesProgressivelyInSmallChunks() throws {
        let mp3 = try #require(Data(base64Encoded: VoiceFixtures.okayDoneMP3, options: .ignoreUnknownCharacters))
        let decoder = MP3StreamDecoder()
        var frames: AVAudioFrameCount = 0
        var firstAudioAfter: Int?
        var offset = 0
        // Feed it like the network does: 700-byte chunks.
        while offset < mp3.count {
            let chunk = mp3.subdata(in: offset..<min(offset + 700, mp3.count))
            offset += chunk.count
            let out = decoder.feed(chunk)
            if firstAudioAfter == nil, !out.isEmpty { firstAudioAfter = offset }
            for b in out {
                #expect(b.format == VoiceAudio.playbackFormat)
                frames += b.frameLength
            }
        }
        frames += decoder.finish().reduce(0) { $0 + $1.frameLength }
        // ~2.1 s at 24 kHz, and playable long before the whole clip arrived.
        #expect(abs(Double(frames) / 24_000 - 2.11) < 0.15)
        #expect((firstAudioAfter ?? .max) <= 2_100)
    }

    // MARK: What to speak first

    @Test func firstChunkIsShortSoAudioStartsSooner() {
        let reply = "Sure. Your briefing ran at seven and everything is fine. Also, the"
        let (a, n) = VoiceLogic.nextChunk(reply, flush: false, isFirst: true)
        #expect(a == "Sure.")
        #expect(n == 5)
        let (b, _) = VoiceLogic.nextChunk(String(reply.dropFirst(n)), flush: false, isFirst: false)
        #expect(b == "Your briefing ran at seven and everything is fine.")
    }

    @Test func longFirstSentenceSpeaksItsFirstClause() {
        let reply = "Saturday looks mostly sunny in Lisbon this weekend, with highs around twenty-seven degrees and a light breeze off the river in the afternoon. More"
        let (a, n) = VoiceLogic.nextChunk(reply, flush: false, isFirst: true)
        #expect(a == "Saturday looks mostly sunny in Lisbon this weekend,")
        #expect(n == 51)
        // Unfinished long sentence still streaming: the clause goes out early too.
        let (b, _) = VoiceLogic.nextChunk("Here's what I found after checking your calendar for the week, your inbox and the team board", flush: false, isFirst: true)
        #expect(b == "Here's what I found after checking your calendar for the week,")
        // Short unfinished text waits.
        #expect(VoiceLogic.nextChunk("Let me check", flush: false, isFirst: true).0.isEmpty)
        #expect(VoiceLogic.nextChunk("Let me check", flush: true, isFirst: true).0 == "Let me check")
    }
}
