import AVFoundation
import XCTest
@testable import Hermes

/// Gemini Live wire format, against messages captured from the real API (2026-10-14).
final class GeminiLiveTests: XCTestCase {
    func testParsesToolCallAndHandle() {
        let call = #"{"toolCall": {"functionCalls": [{"name": "ask_otto", "args": {"request": "What's the weather in Montevideo right now?"}, "id": "call_1187514"}]}}"#
        XCTAssertEqual(GeminiWire.parse(Data(call.utf8)),
                       [.toolCall(id: "call_1187514", name: "ask_otto", args: ["request": "What's the weather in Montevideo right now?"])])
        let handle = #"{"sessionResumptionUpdate": {"newHandle": "889f0e79", "resumable": true}}"#
        XCTAssertEqual(GeminiWire.parse(Data(handle.utf8)), [.resumeHandle("889f0e79")])
        XCTAssertEqual(GeminiWire.parse(Data(#"{"setupComplete": {}}"#.utf8)), [.setupComplete])
        XCTAssertEqual(GeminiWire.parse(Data("{}".utf8)), [])
        XCTAssertEqual(GeminiWire.parse(Data("not json".utf8)), [])
    }

    func testParsesServerContentInOrder() {
        let pcm = Data([0x00, 0x40, 0x00, 0xC0]) // +0.5, -0.5
        let msg = """
        {"serverContent": {"inputTranscription": {"text": "hola"}, "modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\(pcm.base64EncodedString())"}}]}, "outputTranscription": {"text": "Hi"}, "interrupted": true, "turnComplete": true}}
        """
        XCTAssertEqual(GeminiWire.parse(Data(msg.utf8)),
                       [.inputText("hola"), .audio(pcm), .outputText("Hi"), .interrupted, .turnComplete])
        let buf = GeminiWire.playbackBuffer(pcm)!
        XCTAssertEqual(buf.frameLength, 2)
        XCTAssertEqual(buf.format.sampleRate, 24_000)
        XCTAssertEqual(buf.floatChannelData![0][0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(buf.floatChannelData![0][1], -0.5, accuracy: 0.0001)
    }

    func testSetupAddsResumptionHandleAndKeepsIntegers() throws {
        let setup = try JSONDecoder().decode(LiveJSON.self, from: Data(#"""
        {"model": "models/gemini-3.8-live", "realtimeInputConfig": {"automaticActivityDetection": {"endOfSpeechSensitivity": "END_SENSITIVITY_HIGH", "silenceDurationMs": 900}}, "sessionResumption": {}}
        """#.utf8))
        let fresh = try JSONSerialization.jsonObject(with: GeminiWire.setupMessage(setup, resumeHandle: nil)!) as! [String: Any]
        let s1 = fresh["setup"] as! [String: Any]
        XCTAssertEqual((s1["sessionResumption"] as! [String: Any]).count, 0)
        let text = String(data: GeminiWire.setupMessage(setup, resumeHandle: "h1")!, encoding: .utf8)!
        XCTAssertTrue(text.contains(#""handle":"h1""#))
        XCTAssertTrue(text.contains(#""silenceDurationMs":900"#), text) // not 900.0
        XCTAssertTrue(text.contains("END_SENSITIVITY_HIGH"), text)
    }

    func testClientTurnsSetupDisablesServerVAD() throws {
        let setup = LiveJSON.object(["model": .string("models/x"), "realtimeInputConfig": .object([
            "automaticActivityDetection": .object(["startOfSpeechSensitivity": .string("START_SENSITIVITY_LOW")])])])
        let quiet = try XCTUnwrap(GeminiWire.setupMessage(setup, resumeHandle: nil))
        XCTAssertTrue(String(decoding: quiet, as: UTF8.self).contains("START_SENSITIVITY_LOW"))
        let data = try XCTUnwrap(GeminiWire.setupMessage(setup, resumeHandle: "h", clientTurns: true))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let s = try XCTUnwrap(obj["setup"] as? [String: Any])
        let aad = (s["realtimeInputConfig"] as? [String: Any])?["automaticActivityDetection"] as? [String: Any]
        XCTAssertEqual(aad?["disabled"] as? Bool, true)
        XCTAssertNil(aad?["startOfSpeechSensitivity"])
        XCTAssertEqual((s["sessionResumption"] as? [String: Any])?["handle"] as? String, "h")
        XCTAssertEqual(String(decoding: GeminiWire.activityStart, as: UTF8.self), #"{"realtimeInput":{"activityStart":{}}}"#)
        XCTAssertEqual(String(decoding: GeminiWire.activityEnd, as: UTF8.self), #"{"realtimeInput":{"activityEnd":{}}}"#)
    }

    func testToolResponseAndAudioMessages() throws {
        let r = try JSONSerialization.jsonObject(with: GeminiWire.toolResponse(id: "c1", name: "ask_otto", result: "Done.", scheduling: "WHEN_IDLE")!) as! [String: Any]
        let fr = ((r["toolResponse"] as! [String: Any])["functionResponses"] as! [[String: Any]])[0]
        XCTAssertEqual(fr["id"] as? String, "c1")
        XCTAssertEqual((fr["response"] as! [String: Any])["scheduling"] as? String, "WHEN_IDLE")
        let a = try JSONSerialization.jsonObject(with: GeminiWire.audioMessage(Data([1, 2, 3]))) as! [String: Any]
        let audio = (a["realtimeInput"] as! [String: Any])["audio"] as! [String: Any]
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertNil(GeminiWire.contextMessage([]))
        let ctx = try JSONSerialization.jsonObject(with: GeminiWire.contextMessage([(true, "hi"), (false, "hello")])!) as! [String: Any]
        let cc = ctx["clientContent"] as! [String: Any]
        XCTAssertEqual(cc["turnComplete"] as? Bool, false)
        XCTAssertEqual((cc["turns"] as! [[String: Any]]).map { $0["role"] as! String }, ["user", "model"])
    }

    func testMicEncoderMakes16kChunks() {
        final class Sink: @unchecked Sendable { let lock = NSLock(); var chunks: [Data] = [] }
        let sink = Sink()
        let enc = LiveMicEncoder(chunkMs: 100) { d in sink.lock.withLock { sink.chunks.append(d) } }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for _ in 0..<10 { // 10 × 4800 frames = 1 s
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
            b.frameLength = 4800
            for i in 0..<4800 { b.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.3 }
            enc.append(b)
        }
        let got = sink.lock.withLock { sink.chunks }
        XCTAssertGreaterThanOrEqual(got.count, 9)
        XCTAssertTrue(got.allSatisfy { $0.count == 3200 })
    }
}

/// The phone's backup end-of-turn detector (John: "it never stops and sends").
final class TurnEndpointerTests: XCTestCase {
    /// Feeds `seconds` of 100 ms chunks at `db` (or alternating levels); returns the time (s into
    /// this run) at which it ended the turn, if it did.
    @discardableResult
    private func run(_ e: inout TurnEndpointer, _ seconds: Double, _ levels: [Float], heard: Bool = true) -> Double? {
        let n = Int((seconds * 10).rounded())
        for i in 0..<n where e.feed(db: levels[i % levels.count], duration: 0.1, serverHeard: heard) != nil {
            return Double(i + 1) / 10
        }
        return nil
    }

    private func calibrated(_ db: Float = -60) -> TurnEndpointer {
        var e = TurnEndpointer()
        XCTAssertNil(run(&e, 2.5, [db]))
        XCTAssertTrue(e.room.calibrated)
        return e
    }

    func testLevelOfPCM16() {
        XCTAssertEqual(TurnEndpointer.level(Data(count: 3200)), -100)
        var half = Data()
        for _ in 0..<1600 { half.append(contentsOf: [0x00, 0x40]) } // +0.5 full scale, constant
        XCTAssertEqual(TurnEndpointer.level(half), -6.02, accuracy: 0.05)
        XCTAssertEqual(TurnEndpointer.level(Data()), -100)
    }

    func testQuietRoomEndsTurnAfterOneAndAHalfSeconds() {
        var e = calibrated()
        XCTAssertNil(run(&e, 1.0, [-20]))
        XCTAssertTrue(e.heardSpeech)
        XCTAssertEqual(run(&e, 3, [-58]), 1.5)
        XCTAssertFalse(e.heardSpeech) // reset: no second end without new speech
        XCTAssertNil(run(&e, 3, [-58]))
    }

    func testMidSentencePauseDoesNotEndTurn() {
        var e = calibrated()
        XCTAssertNil(run(&e, 1.2, [-22]))
        XCTAssertNil(run(&e, 0.6, [-58])) // "I want to know, um… "
        XCTAssertNil(run(&e, 0.6, [-58]))  // even 1.2 s
        XCTAssertNil(run(&e, 1.5, [-21]))  // "…what the tallest mountain is"
        XCTAssertNotNil(run(&e, 2, [-58]))
    }

    func testBackgroundTalkerStillEndsTurn() {
        // Someone talking across the room (-45…-36 dB) the whole time; John at -20.
        var e = calibrated(-44)
        let babble: [Float] = [-40, -45, -36, -42, -38, -44]
        XCTAssertNil(run(&e, 3, babble), "background alone is not a turn")
        XCTAssertNil(run(&e, 1.5, [-20, -18, -22]))
        XCTAssertEqual(run(&e, 3, babble), 1.5)
    }

    func testSteadyLoudRoom() {
        var e = calibrated(-32) // fan / wind
        XCTAssertNil(run(&e, 1, [-12]))
        XCTAssertEqual(run(&e, 3, [-31, -33]), 1.5)
    }

    func testNeedsTheServerToHaveHeardWordsAndRealSpeech() {
        var e = calibrated()
        XCTAssertNil(run(&e, 1, [-20], heard: false))
        XCTAssertNil(run(&e, 3, [-58], heard: false))
        var cough = calibrated()
        XCTAssertNil(run(&cough, 0.2, [-20]))
        XCTAssertNil(run(&cough, 3, [-58]), "0.2 s blip is not speech")
    }

    func testNothingBeforeTheRoomIsLearned() {
        var e = TurnEndpointer()
        XCTAssertNil(run(&e, 1, [-20]))
        XCTAssertNil(run(&e, 1.3, [-58]))
    }

    func testSoftWordsKeepTheTurnOpen() {
        // Trailing off, a bit softer than his normal level: still talking.
        var e = calibrated()
        XCTAssertNil(run(&e, 1, [-20]))
        XCTAssertNil(run(&e, 3, [-31, -58]), "a soft word every other chunk resets the quiet timer")
    }

    // MARK: Noisy rooms (client-driven turns)

    /// Feeds client-mode chunks; `level(i)` gives each chunk's dBFS. Returns (time, event) pairs.
    private func client(_ e: inout TurnEndpointer, _ seconds: Double, playing: Bool = false,
                        _ level: (Int) -> Float) -> [(Double, TurnEndpointer.Event)] {
        var out: [(Double, TurnEndpointer.Event)] = []
        for i in 0..<Int((seconds * 10).rounded()) {
            if let ev = e.feed(db: level(i), duration: 0.1, serverHeard: true, client: true, playing: playing) {
                out.append((Double(i + 1) / 10, ev))
            }
        }
        return out
    }

    /// Deterministic babble: `center` ± `spread` dB.
    private func babble(_ center: Float, _ spread: Float, seed: UInt64 = 1) -> (Int) -> Float {
        var g = SplitMix(seed: seed)
        return { _ in center + Float(g.unit() * 2 - 1) * spread }
    }

    func testSteadyBabblePlusUtteranceEndsSoonAfterHeStops() {
        // Airport: babble around -40 dBFS, John's 2 s question ~12 dB over it.
        var e = TurnEndpointer()
        XCTAssertTrue(client(&e, 3, babble(-40, 4)).isEmpty, "babble alone opens no turn")
        let talk = client(&e, 2, babble(-28, 3, seed: 2))
        XCTAssertEqual(talk.first?.1, .start)
        XCTAssertLessThanOrEqual(talk.first?.0 ?? 9, 0.5)
        let after = client(&e, 4, babble(-40, 4, seed: 3))
        XCTAssertEqual(after.first?.1, .end("quiet"))
        XCTAssertLessThanOrEqual(after.first?.0 ?? 9, TurnEndpointer.clientQuietToEnd + 1, "within the end-of-turn delay + 1 s")
    }

    func testFarFieldTalkerDoesNotHoldTheTurnOpen() {
        var e = TurnEndpointer()
        _ = client(&e, 2, babble(-42, 3))
        XCTAssertEqual(client(&e, 2) { [-27, -25, -29, -26][$0 % 4] }.first?.1, .start)
        // Someone talking nearby: louder than the room, ~12 dB under John.
        let after = client(&e, 4, babble(-38, 5, seed: 4))
        XCTAssertEqual(after.first?.1, .end("quiet"))
        XCTAssertLessThanOrEqual(after.first?.0 ?? 9, 2.5)
    }

    func testClientTurnHasAHardUpperBound() {
        var e = TurnEndpointer()
        _ = client(&e, 1) { _ in -60 }
        let events = client(&e, 30) { [-20, -22, -24, -21, -50][$0 % 5] }
        XCTAssertEqual(events.first?.1, .start)
        let max = events.first { $0.1 == .end("max 25s") }
        XCTAssertNotNil(max)
        XCTAssertLessThanOrEqual(max?.0 ?? 99, TurnEndpointer.maxTurn + 0.5)
    }

    func testQuietRoomClientTurnStillWorks() {
        var e = TurnEndpointer()
        _ = client(&e, 1) { _ in -60 }
        XCTAssertEqual(client(&e, 1) { _ in -22 }.first?.1, .start)
        XCTAssertEqual(client(&e, 3) { _ in -58 }.first?.0, 1.5)
    }

    func testStartingOverTheReplyNeedsALouderVoice() {
        var e = TurnEndpointer()
        _ = client(&e, 2, babble(-45, 2))
        XCTAssertTrue(client(&e, 1, playing: true) { _ in -36 }.isEmpty, "echo residue doesn't barge in")
        XCTAssertEqual(client(&e, 1, playing: true) { _ in -24 }.first?.1, .start)
    }

    func testTurnsModeFollowsTheRoom() {
        var quiet = VoiceLogic.NoiseFloor()
        var loud = VoiceLogic.NoiseFloor()
        for _ in 0..<VoiceLogic.NoiseFloor.calibrationBuffers {
            quiet.observe(-58, playing: false)
            loud.observe(-38, playing: false)
        }
        XCTAssertEqual(LiveTurns.decide(quiet), .server)
        XCTAssertEqual(LiveTurns.decide(loud), .client)
        XCTAssertEqual(LiveTurns.decide(VoiceLogic.NoiseFloor()), .server, "not calibrated: keep server VAD")
        var watch = NoisyRoomWatch()
        XCTAssertFalse(watch.feed(loud, duration: 2.9))
        XCTAssertTrue(watch.feed(loud, duration: 0.2))
        XCTAssertFalse(watch.feed(quiet, duration: 0.1), "resets when the room quietens")
    }
}

/// Small deterministic RNG for babble fixtures.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

final class LocalVoiceTests: XCTestCase {
    func testTurnAudioSlicesByTime() {
        let a = TurnAudio(keep: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        a.append(Data([1]), at: t0)
        a.append(Data([2]), at: t0.addingTimeInterval(1))
        a.append(Data([3]), at: t0.addingTimeInterval(2))
        XCTAssertEqual(a.slice(since: t0.addingTimeInterval(0.5)), Data([2, 3]))
        XCTAssertEqual(a.slice(since: .distantPast), Data([1, 2, 3]))
        a.append(Data([4]), at: t0.addingTimeInterval(11.5))  // drops chunks older than 10 s
        XCTAssertEqual(a.slice(since: .distantPast), Data([3, 4]))
        XCTAssertEqual(VoiceChoice.displayName("kokoro:af_heart"), "Heart (on your Mac)")
    }
}
