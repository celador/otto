import XCTest
@testable import Hermes

/// Voice mode speed: progress updates (willContinue), the throttle, and the fast voice model.
final class VoiceRealtimeTests: XCTestCase {
    func testToolResponseWillContinueEncoding() throws {
        let partial = try XCTUnwrap(GeminiWire.toolResponse(id: "call_1", name: "ask_otto", result: "partial: Reading mail",
                                                            scheduling: "SILENT", willContinue: true))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: partial) as? [String: Any])
        let r = try XCTUnwrap(((obj["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)
        XCTAssertEqual(r["id"] as? String, "call_1")
        XCTAssertEqual(r["name"] as? String, "ask_otto")
        XCTAssertEqual(r["willContinue"] as? Bool, true)
        let response = try XCTUnwrap(r["response"] as? [String: Any])
        XCTAssertEqual(response["result"] as? String, "partial: Reading mail")
        XCTAssertEqual(response["scheduling"] as? String, "SILENT")

        // The final answer goes without willContinue.
        let final = try XCTUnwrap(GeminiWire.toolResponse(id: "call_1", name: "ask_otto", result: "Done", scheduling: "WHEN_IDLE"))
        let f = try XCTUnwrap(((JSONSerialization.jsonObject(with: final) as? [String: Any])?["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])
        XCTAssertNil(f[0]["willContinue"])
    }

    func testProgressThrottle() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var p = AgentProgress(started: t0)
        // Quiet for the first 3 s.
        XCTAssertNil(p.next(now: t0.addingTimeInterval(2.9), status: "Running a command", interim: nil, userTalking: false))
        // Never while John talks.
        XCTAssertNil(p.next(now: t0.addingTimeInterval(3.5), status: "Running a command", interim: nil, userTalking: true))
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(3.5), status: "Running a command", interim: nil, userTalking: false),
                       .init(result: "partial: Running a command", scheduling: "SILENT"))
        // At most one every 6 s.
        XCTAssertNil(p.next(now: t0.addingTimeInterval(9.0), status: "Reading a file", interim: nil, userTalking: false))
        // Interim text is real news and wins over a status line.
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(9.6), status: "Reading a file", interim: "Found 3 invoices, checking totals.",
                              userTalking: false),
                       .init(result: "partial: Found 3 invoices, checking totals.", scheduling: "WHEN_IDLE"))
        // No repeats: the same interim is skipped, the next new thing goes.
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(16), status: "Reading a file", interim: "Found 3 invoices, checking totals.",
                              userTalking: false),
                       .init(result: "partial: Reading a file", scheduling: "SILENT"))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(30), status: "Reading a file", interim: "Found 3 invoices, checking totals.",
                            userTalking: false))
        XCTAssertNil(p.next(now: t0.addingTimeInterval(40), status: nil, interim: "  ", userTalking: false))
    }

    func testVoiceTurnsRunOnHaikuWithLowEffortForThatRunOnly() {
        let chosen = ModelChoice(provider: "anthropic", model: "claude-opus-5-5")
        let voice = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi", voice: true), model: chosen, fast: true)
        XCTAssertEqual(voice["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(voice["provider"] as? String, "anthropic")
        XCTAssertEqual((voice["model_options"] as? [String: Any])?["reasoning_effort"] as? String, "low")
        XCTAssertNil((voice["model_options"] as? [String: Any])?["fast"], "Haiku has no Fast Mode on the gateway")
        XCTAssertTrue((voice["instructions"] as? String)?.contains("background") == true)
        XCTAssertEqual((voice["model_options"] as? [String: Any])?["memory"] as? Bool, false,
                       "voice turns skip Honcho for that run")

        let fastVoice = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi", voice: true), model: nil, voiceFast: true)
        XCTAssertEqual((fastVoice["model_options"] as? [String: Any])?["fast"] as? Bool, true)

        // A typed turn keeps the chat's own model and Fast setting.
        let typed = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi"), model: chosen, fast: true)
        XCTAssertEqual(typed["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual((typed["model_options"] as? [String: Any])?["fast"] as? Bool, true)
        XCTAssertNil((typed["model_options"] as? [String: Any])?["reasoning_effort"])
        XCTAssertNil((typed["model_options"] as? [String: Any])?["memory"], "typed turns keep Honcho")
        let plain = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi"), model: nil)
        XCTAssertNil(plain["model_options"])
    }

    @MainActor
    func testVoiceTurnLeavesTheChatModelAlone() {
        let prefsKey = "voice-model-test-\(UUID().uuidString)"
        let chosen = ModelChoice(provider: "anthropic", model: "claude-sonnet-5-5")
        ModelPrefs.set(chosen, sessionID: prefsKey)
        _ = HermesClient.runBody(sessionID: prefsKey, message: OutgoingMessage(text: "hi", voice: true), model: chosen)
        XCTAssertEqual(ModelPrefs.get(sessionID: prefsKey), chosen)
        ModelPrefs.set(nil, sessionID: prefsKey)
    }
}
