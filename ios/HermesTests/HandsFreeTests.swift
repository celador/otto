import AppIntents
import Foundation
import Testing
@testable import Hermes

/// Hands-free Otto: the watch's conversation loop, the screenless phone session's end rules and the
/// Siri / Action-button intent wiring.
@MainActor
struct HandsFreeTests {
    // MARK: Watch loop: taps

    @Test func tapStartsInterruptsOrEnds() {
        typealias L = WatchTalkLoop
        #expect(L.tapAction(phase: .idle, looping: false, heardVoice: false) == .start)
        #expect(L.tapAction(phase: .error, looping: false, heardVoice: false) == .start)
        #expect(L.tapAction(phase: .speaking, looping: true, heardVoice: false) == .interrupt)
        #expect(L.tapAction(phase: .listening, looping: true, heardVoice: false) == .end)
        #expect(L.tapAction(phase: .listening, looping: true, heardVoice: true) == .sendAndEnd)
        #expect(L.tapAction(phase: .thinking, looping: true, heardVoice: false) == .endAfterReply)
        #expect(L.tapAction(phase: .sending, looping: true, heardVoice: false) == .endAfterReply)
        #expect(L.tapAction(phase: .thinking, looping: false, heardVoice: false) == .end)
    }

    @Test func micReopensOnlyWhileLooping() {
        #expect(WatchTalkLoop.reopensMic(looping: true, endAfterReply: false, interrupted: false))
        #expect(!WatchTalkLoop.reopensMic(looping: false, endAfterReply: false, interrupted: false))
        #expect(!WatchTalkLoop.reopensMic(looping: true, endAfterReply: true, interrupted: false))
        #expect(!WatchTalkLoop.reopensMic(looping: true, endAfterReply: false, interrupted: true))
    }

    // MARK: Watch loop: end of turn and end of session

    /// Feeds `seconds` of readings at `db`, starting at `t`; returns the first non-listening decision.
    private func feed(_ m: inout WatchTalkLoop.Meter, db: Float, from t: inout TimeInterval, seconds: TimeInterval)
        -> WatchTalkLoop.Decision {
        let end = t + seconds
        while t < end - 0.0001 {
            t += 0.1
            let d = m.feed(db: db, at: t)
            if d != .keepListening { return d }
        }
        return .keepListening
    }

    @Test func turnEndsAfterTwoSecondsOfQuiet() {
        var m = WatchTalkLoop.Meter()
        var t: TimeInterval = 0
        #expect(feed(&m, db: -58, from: &t, seconds: 0.5) == .keepListening)   // room
        #expect(feed(&m, db: -30, from: &t, seconds: 2) == .keepListening)      // talking
        #expect(m.heardVoice)
        #expect(feed(&m, db: -58, from: &t, seconds: 1.7) == .keepListening)    // a mid-sentence pause survives
        #expect(feed(&m, db: -30, from: &t, seconds: 1) == .keepListening)      // more words
        #expect(feed(&m, db: -58, from: &t, seconds: 2.1) == .endTurn)
        #expect(WatchTalkLoop.endOfTurnSilence >= 1.8)
    }

    @Test func sayingNothingEndsTheConversationAfterAboutEightSeconds() {
        var m = WatchTalkLoop.Meter()
        var t: TimeInterval = 0
        #expect(feed(&m, db: -58, from: &t, seconds: 7.5) == .keepListening)
        #expect(feed(&m, db: -58, from: &t, seconds: 1) == .noSpeech)
        #expect(abs(t - WatchTalkLoop.idleTimeout) < 0.15)
    }

    @Test func longTurnIsCappedNotDropped() {
        var m = WatchTalkLoop.Meter()
        var t: TimeInterval = 0
        _ = feed(&m, db: -58, from: &t, seconds: 0.5)
        #expect(feed(&m, db: -30, from: &t, seconds: 40) == .endTurn)
        #expect(t <= WatchTalkLoop.maxTurn + 0.15)
    }

    @Test func goodbyesEndButRequestsDont() {
        for s in ["Stop", "bye", "Bye bye", "Goodbye, Otto", "OK bye", "That's all", "thanks, that's it",
                  "I'm done", "We're done, thank you", "never mind", "see you later"] {
            #expect(WatchTalkLoop.isGoodbye(s), "\(s)")
        }
        for s in ["Stop the timer", "thanks", "thank you", "Thanks, now book it for Tuesday", "Done with the email?",
                  "Say bye to Alex for me", "what time does the shop close", ""] {
            #expect(!WatchTalkLoop.isGoodbye(s), "\(s)")
        }
    }

    @Test func bluetoothPortsAreHeadphones() {
        #expect(WatchTalkLoop.isBluetooth(port: "BluetoothA2DPOutput"))
        #expect(WatchTalkLoop.isBluetooth(port: "BluetoothHFP"))
        #expect(WatchTalkLoop.isBluetooth(port: "BluetoothLE"))
        #expect(!WatchTalkLoop.isBluetooth(port: "Speaker"))
    }

    @Test func goodbyeOnTheWatchStartsNoRun() async throws {
        // Returns before any network call: the URLs are never contacted.
        let lite = HermesLite(gateway: URL(string: "https://invalid.example")!, relay: URL(string: "https://invalid.example")!,
                              apiKey: "x", timeout: 1)
        let t = try await lite.ask(audio: nil, text: "OK bye", sessionID: "s1", endsOnGoodbye: true)
        #expect(t.ended && t.runID.isEmpty && t.sessionID == "s1")
        let reply = WatchWire.reply(t)
        #expect(reply["ended"] as? Bool == true)
        #expect(WatchWire.reply(.init(sessionID: "s", runID: "r", transcript: "hi"))["ended"] == nil)
    }

    // MARK: Phone: when a screenless conversation ends

    @Test func geminiGoodbyeEndsAfterOttoSaysBye() {
        let t0 = Date()
        var st = HandsFreeEnd.State(now: t0)
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "OK bye", now: t0.addingTimeInterval(1)) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .speaking, heard: "OK bye", now: t0.addingTimeInterval(2)) == nil)
        // Gemini finished its own goodbye: the exchange is cleared.
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "", now: t0.addingTimeInterval(3.5)) == .goodbye)
    }

    @Test func byeMidSentenceDoesNotEnd() {
        let t0 = Date()
        var st = HandsFreeEnd.State(now: t0)
        _ = HandsFreeEnd.step(&st, phase: .listening, heard: "bye", now: t0.addingTimeInterval(1))
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "bye the way, what's on my calendar",
                                  now: t0.addingTimeInterval(1.5)) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .thinking, heard: "bye the way, what's on my calendar",
                                  now: t0.addingTimeInterval(12)) == nil)
    }

    @Test func goodbyeEndsEvenIfOttoStaysQuiet() {
        let t0 = Date()
        var st = HandsFreeEnd.State(now: t0)
        _ = HandsFreeEnd.step(&st, phase: .listening, heard: "stop", now: t0)
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "stop", now: t0.addingTimeInterval(4)) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "stop", now: t0.addingTimeInterval(HandsFreeEnd.goodbyeGrace)) == .goodbye)
    }

    @Test func longSilenceEndsButThinkingDoesNot() {
        let t0 = Date()
        var st = HandsFreeEnd.State(now: t0)
        // Otto working for a long time is not silence.
        #expect(HandsFreeEnd.step(&st, phase: .thinking, heard: "check my email", now: t0.addingTimeInterval(60)) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .speaking, heard: "check my email", now: t0.addingTimeInterval(70)) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "", now: t0.addingTimeInterval(80)) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "", now: t0.addingTimeInterval(80 + HandsFreeEnd.silenceTimeout - 1)) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .listening, heard: "", now: t0.addingTimeInterval(80 + HandsFreeEnd.silenceTimeout)) == .silence)
    }

    @Test func stuckErrorEnds() {
        let t0 = Date()
        var st = HandsFreeEnd.State(now: t0)
        #expect(HandsFreeEnd.step(&st, phase: .error, heard: "", now: t0) == nil)
        #expect(HandsFreeEnd.step(&st, phase: .error, heard: "", now: t0.addingTimeInterval(HandsFreeEnd.errorTimeout)) == .error)
    }

    // MARK: Intent wiring

    @Test func talkToOttoRunsLockedInTheBackground() {
        #expect(!TalkToOttoIntent.openAppWhenRun)
        #expect(TalkToOttoIntent.authenticationPolicy == .alwaysAllowed)
        #expect((TalkToOttoIntent() as Any) is any AudioRecordingIntent)
        // The existing Voice Chat intent (Action button / Control Center set-ups) takes the same path.
        #expect(!VoiceChatWithHermesIntent.openAppWhenRun)
        #expect(VoiceChatWithHermesIntent.authenticationPolicy == .alwaysAllowed)
        #expect((VoiceChatWithHermesIntent() as Any) is any AudioRecordingIntent)
        // Stop on the Live Activity runs without unlocking.
        #expect((StopOttoVoiceIntent() as Any) is any LiveActivityIntent)
        #expect(StopOttoVoiceIntent.authenticationPolicy == .alwaysAllowed)
        // Both may start the Live Activity from the background (iOS lets a background app record only
        // while one shows), and both can hand over to the app when the background start isn't possible.
        #expect((TalkToOttoIntent() as Any) is any LiveActivityIntent)
        #expect((VoiceChatWithHermesIntent() as Any) is any LiveActivityIntent)
        if #available(iOS 26.0, *) {
            for modes in [TalkToOttoIntent.supportedModes, VoiceChatWithHermesIntent.supportedModes] {
                #expect(modes.contains(.background))
                #expect(modes.contains(.foreground(.dynamic)))
            }
        }
    }

    // MARK: Action button: background start or hand over to the app

    @Test func noLiveActivityInTheBackgroundOpensTheApp() {
        #expect(HandsFreePlan.afterActivity(appActive: false, activityUp: true) == .background)
        #expect(HandsFreePlan.afterActivity(appActive: false, activityUp: false) == .foreground)
        // In front (headless test path) the activity is cosmetic.
        #expect(HandsFreePlan.afterActivity(appActive: true, activityUp: false) == .background)
    }

    @Test func micFailureInTheBackgroundOpensTheAppInsteadOfFailing() {
        #expect(HandsFreePlan.afterFailure("Couldn't start the microphone.", appActive: false) == .needsForeground)
        #expect(HandsFreePlan.afterFailure("Couldn't start the microphone.", appActive: true)
                == .failed("Couldn't start the microphone."))
    }

    @Test func handsFreeLaunchMapsOutcomes() async throws {
        let saved = HandsFreeHooks.start
        defer { HandsFreeHooks.start = saved }
        HandsFreeHooks.start = { .started }
        #expect(try await HandsFreeLaunch.run() == .done)
        HandsFreeHooks.start = { .alreadyRunning }
        #expect(try await HandsFreeLaunch.run() == .done)
        HandsFreeHooks.start = { .needsForeground }
        #expect(try await HandsFreeLaunch.run() == .openApp)
        HandsFreeHooks.start = { .failed("x") }
        await #expect(throws: HandsFreeIntentError.self) { _ = try await HandsFreeLaunch.run() }
    }

    @Test func backgroundSessionMixesInsteadOfInterrupting() {
        let bg = VoiceAudio.sessionOptions(background: true)
        #expect(bg.contains(.mixWithOthers))
        #expect(!bg.contains(.duckOthers))
        let fg = VoiceAudio.sessionOptions(background: false)
        // In front: non-mixable (like a call), so Otto is Now Playing and the headphone button reaches it.
        #expect(!fg.contains(.duckOthers) && !fg.contains(.mixWithOthers))
        for o in [bg, fg] {
            #expect(o.contains(.defaultToSpeaker) && o.contains(.allowBluetoothHFP) && o.contains(.allowBluetoothA2DP))
        }
    }

    @Test func audioErrorCodesReadAsFourCharCodes() {
        #expect(VoiceAudio.fourCC(560557684) == "!int")
        #expect(VoiceAudio.fourCC(561015905) == "!pla")
        #expect(VoiceAudio.fourCC(2003329396) == "what")
        #expect(VoiceAudio.fourCC(NSError(domain: NSOSStatusErrorDomain, code: 560557684)) == "!int")
        #expect(VoiceAudio.fourCC(-50) == "-50")
    }

    @Test func intentsDriveTheHandsFreeSession() async throws {
        HandsFreeVoice.install()
        #expect(HandsFreeHooks.start != nil && HandsFreeHooks.stop != nil)
        let saved = (HandsFreeHooks.start, HandsFreeHooks.stop)
        defer { HandsFreeHooks.start = saved.0; HandsFreeHooks.stop = saved.1 }

        var starts = 0
        HandsFreeHooks.start = { starts += 1; return .started }
        _ = try await TalkToOttoIntent().perform()
        _ = try await VoiceChatWithHermesIntent().perform()
        #expect(starts == 2)

        HandsFreeHooks.start = { .notConnected }
        await #expect(throws: HandsFreeIntentError.self) { _ = try await TalkToOttoIntent().perform() }

        var stops = 0
        HandsFreeHooks.stop = { stops += 1 }
        _ = try await StopOttoVoiceIntent().perform()
        #expect(stops == 1)
    }
}
