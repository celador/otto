import Foundation
import Testing
@testable import Hermes

/// ChatGPT voice engine: the phone reuses the Gemini Live client against the Mac bridge
/// (relay/chatgpt_live*.py). These pin the contract between the two.
@Suite struct ChatGPTVoiceTests {
    @Test func engineIsLiveAndLabelled() {
        #expect(VoiceEngine.chatgpt.isLive)
        #expect(VoiceEngine.gemini.isLive)
        #expect(!VoiceEngine.classic.isLive)
        #expect(VoiceEngine.chatgpt.label == "ChatGPT voice")
        #expect(VoiceEngine(rawValue: "chatgpt") == .chatgpt)
        #expect(VoiceEngine.allCases.contains(.chatgpt))
    }

    @Test func savedVoicePerEngine() {
        let d = UserDefaults.standard
        let oldG = d.string(forKey: VoiceEngine.geminiVoiceKey), oldC = d.string(forKey: VoiceEngine.chatgptVoiceKey)
        defer {
            d.set(oldG, forKey: VoiceEngine.geminiVoiceKey)
            d.set(oldC, forKey: VoiceEngine.chatgptVoiceKey)
        }
        d.removeObject(forKey: VoiceEngine.geminiVoiceKey)
        d.removeObject(forKey: VoiceEngine.chatgptVoiceKey)
        #expect(VoiceEngine.gemini.savedVoice == "Charon")
        #expect(VoiceEngine.chatgpt.savedVoice == "")  // the Mac picks its default
        d.set("maple", forKey: VoiceEngine.chatgptVoiceKey)
        #expect(VoiceEngine.chatgpt.savedVoice == "maple")
        #expect(VoiceEngine.classic.savedVoice == "")
    }

    /// The bridge's token response decodes as a Gemini token (same shape).
    @Test func bridgeTokenDecodes() throws {
        let json = #"{"token":"eyJ.sig","ws_url":"wss://my-mac.example.ts.net:8657/live","model":"chatgpt-voice-v3","voice":"cove","expires_at":"2026-10-15T19:35:08Z","setup":{"engine":"chatgpt","voice":"cove"}}"#
        let t = try HermesClient.decoder.decode(GeminiLiveToken.self, from: Data(json.utf8))
        #expect(t.wsUrl == "wss://my-mac.example.ts.net:8657/live")
        #expect(t.voice == "cove")
        #expect(t.setup == .object(["engine": .string("chatgpt"), "voice": .string("cove")]))
    }

    @Test func bridgeStatusDecodes() throws {
        let json = #"{"available":false,"reason":"Run scripts/setup_chatgpt_live.sh on your Mac.","model":"ChatGPT voice (v3)","default_voice":"cove","voices":[{"name":"cove","style":"Composed, direct"}]}"#
        let s = try HermesClient.decoder.decode(GeminiLiveStatus.self, from: Data(json.utf8))
        #expect(!s.available)
        #expect(s.defaultVoice == "cove")
        #expect(s.voices?.first?.name == "cove")
    }

    /// ChatGPT takes history only at session start: the chat's turns ride in the setup.
    @Test func setupCarriesContextForChatGPT() throws {
        let setup = LiveJSON.object(["engine": .string("chatgpt"), "voice": .string("cove")])
        let data = try #require(GeminiWire.setupMessage(setup, resumeHandle: nil,
                                                        context: [(true, "My name is John."), (false, "Hi John.")]))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let s = try #require(obj["setup"] as? [String: Any])
        #expect(s["engine"] as? String == "chatgpt")
        let ctx = try #require(s["context"] as? [[String: String]])
        #expect(ctx == [["role": "user", "text": "My name is John."], ["role": "assistant", "text": "Hi John."]])
        // Empty or absent context adds nothing (Gemini's setup is unchanged).
        let plain = try #require(try JSONSerialization.jsonObject(with: GeminiWire.setupMessage(setup, resumeHandle: nil, context: [])!) as? [String: Any])
        #expect((plain["setup"] as? [String: Any])?["context"] == nil)
    }

    /// Messages exactly as chatgpt_live.Translator / audio_message emit them.
    @Test func parsesBridgeMessages() {
        let lines = [
            #"{"toolCall": {"functionCalls": [{"id": "item_EZJ1", "name": "ask_otto", "args": {"request": "What is my next meeting?"}}]}}"#,
            #"{"serverContent": {"inputTranscription": {"text": " What"}}}"#,
            #"{"serverContent": {"outputTranscription": {"text": " Four."}}}"#,
            #"{"serverContent": {"turnComplete": true}}"#,
            #"{"serverContent": {"interrupted": true}}"#,
            #"{"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "AQD/fw=="}}]}}}"#,
            #"{"setupComplete": {}}"#,
            #"{"goAway": {"timeLeft": "0s"}}"#,
            #"{"error": {"message": "ChatGPT voice: usage limit"}}"#,
        ]
        let events = lines.flatMap { GeminiWire.parse(Data($0.utf8)) }
        #expect(events == [
            .toolCall(id: "item_EZJ1", name: "ask_otto", args: ["request": "What is my next meeting?"]),
            .inputText(" What"), .outputText(" Four."), .turnComplete, .interrupted,
            .audio(Data([0x01, 0x00, 0xff, 0x7f])), .setupComplete, .goAway,
            .error("ChatGPT voice: usage limit"),
        ])
    }

    /// What the phone sends back for ask_otto is what the bridge's parse_phone/on_tool_response read.
    @Test func toolResponseShapeForBridge() throws {
        let data = try #require(GeminiWire.toolResponse(id: "item_EZJ1", name: "ask_otto", result: "Angie at 3 pm", scheduling: "WHEN_IDLE"))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let r = try #require(((obj["toolResponse"] as? [String: Any])?["functionResponses"] as? [[String: Any]])?.first)
        #expect(r["id"] as? String == "item_EZJ1")
        #expect((r["response"] as? [String: Any])?["result"] as? String == "Angie at 3 pm")
        #expect(r["willContinue"] == nil)
    }
}
