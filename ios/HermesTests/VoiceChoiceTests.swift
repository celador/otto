import Foundation
import Testing
@testable import Hermes

/// Voice picker logic: language routing, the relay's voice list, request bodies. No audio.
@Suite struct VoiceChoiceTests {

    // MARK: Language routing

    @Test func spanishSentencesGoToTheSpanishVoice() {
        let es = VoiceChoice.voice(for: "Mañana va a llover en Montevideo, así que llevá paraguas.",
                                   main: "en-US-AriaNeural", spanish: "es-UY-MateoNeural", previousSpanish: false)
        #expect(es == SpeechSegment(text: es.text, voice: "es-UY-MateoNeural", spanish: true))
        let en = VoiceChoice.voice(for: "Tomorrow it will rain in Montevideo, so bring an umbrella.",
                                   main: "en-US-AriaNeural", spanish: "es-UY-MateoNeural", previousSpanish: true)
        #expect(en.voice == "en-US-AriaNeural" && !en.spanish)
        // Hermes default main voice → no voice sent.
        let def = VoiceChoice.voice(for: "Here is the summary of your week so far.",
                                    main: "", spanish: "es-UY-MateoNeural", previousSpanish: false)
        #expect(def.voice == nil)
        // "Same voice" for Spanish → the main voice reads Spanish too.
        let same = VoiceChoice.voice(for: "¿Querés que lo agende para el martes?", main: "en-GB-SoniaNeural",
                                     spanish: VoiceChoice.sameAsMain, previousSpanish: false)
        #expect(same.voice == "en-GB-SoniaNeural" && same.spanish)
    }

    @Test func shortSentencesKeepThePreviousLanguage() {
        #expect(VoiceChoice.isSpanish("Sí.") == nil)
        #expect(VoiceChoice.isSpanish("¡Dale!") == true)
        let afterEs = VoiceChoice.voice(for: "OK.", main: "", spanish: "es-UY-MateoNeural", previousSpanish: true)
        #expect(afterEs.voice == "es-UY-MateoNeural")
        let afterEn = VoiceChoice.voice(for: "OK.", main: "", spanish: "es-UY-MateoNeural", previousSpanish: false)
        #expect(afterEn.voice == nil)
    }

    @Test func planMergesNeighboursAndSplitsLanguages() {
        let text = "Here's what I found. It's a short list. Y ahora en español: la reunión es el jueves a las diez. Sí. Back to English, the call is on Friday."
        let plan = VoiceChoice.plan(text, main: "en-US-AriaNeural", spanish: "es-UY-MateoNeural")
        #expect(plan.map(\.voice) == ["en-US-AriaNeural", "es-UY-MateoNeural", "en-US-AriaNeural"])
        #expect(plan[0].text == "Here's what I found. It's a short list.")
        #expect(plan[1].text.hasSuffix("Sí."))
        // maxChars keeps requests small.
        let long = Array(repeating: "This is one sentence of a long English reply.", count: 20).joined(separator: " ")
        #expect(VoiceChoice.plan(long, main: "", spanish: "es-UY-MateoNeural", maxChars: 200).allSatisfy { $0.text.count <= 200 })
    }

    @Test func defaultsAreMateoAndHermesVoice() {
        #expect(VoiceChoice.defaultSpanish == "es-UY-MateoNeural")
        #expect(VoiceChoice.curatedSpanish.first?.label == "Mateo (Uruguay)")
        #expect(VoiceChoice.hermesDefault.isEmpty)
    }

    // MARK: Relay request body

    @Test func requestBodyCarriesVoiceAndRate() throws {
        let body = VoiceChoice.speakBody("Hola.", voice: "es-UY-MateoNeural", speed: 1.25)
        #expect(body["text"] as? String == "Hola.")
        #expect(body["voice"] as? String == "es-UY-MateoNeural")
        #expect(body["rate"] as? Double == 1.25)
        let plain = VoiceChoice.speakBody("Hi.", voice: nil, speed: 1.0)
        #expect(plain["voice"] == nil && plain["rate"] == nil)
        #expect(VoiceChoice.speakBody(String(repeating: "a", count: 5000), voice: "", speed: 0.8)["voice"] == nil)
        #expect(VoiceChoice.rate(for: 0.8) == 0.8)
        #expect(VoiceChoice.rate(for: 3) == 2.0)
        // Valid JSON for the relay.
        let data = try JSONSerialization.data(withJSONObject: body)
        let back = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(back?["voice"] as? String == "es-UY-MateoNeural")
    }

    // MARK: Voice list

    static let listJSON = """
    {"default": "en-US-AriaNeural", "provider": "edge", "voices": [
      {"short_name": "es-UY-MateoNeural", "locale": "es-UY", "gender": "Male", "name": "Mateo", "locale_name": "Spanish (Uruguay)"},
      {"short_name": "es-UY-ValentinaNeural", "locale": "es-UY", "gender": "Female", "name": "Valentina", "locale_name": "Spanish (Uruguay)"},
      {"short_name": "es-AR-TomasNeural", "locale": "es-AR", "gender": "Male", "name": "Tomas", "locale_name": "Spanish (Argentina)"},
      {"short_name": "en-US-AriaNeural", "locale": "en-US", "gender": "Female", "name": "Aria", "locale_name": "English (United States)"},
      {"short_name": "de-DE-KatjaNeural", "locale": "de-DE", "gender": "Female", "name": "Katja", "locale_name": "German (Germany)"},
      {"short_name": "af-ZA-AdriNeural", "locale": "af-ZA", "gender": "Female", "name": "Adri", "locale_name": "Afrikaans (South Africa)"}
    ]}
    """

    @Test func decodesAndGroupsVoices() throws {
        let r = try VoiceChoice.decodeVoices(Data(Self.listJSON.utf8))
        #expect(r.default == "en-US-AriaNeural" && r.voices.count == 6)
        #expect(r.voices[0].label == "Mateo (Uruguay)" && r.voices[0].language == "es")
        let groups = VoiceChoice.groups(r.voices)
        #expect(groups.map(\.title) == ["Spanish", "English", "Afrikaans", "German"])
        #expect(groups[0].voices.map(\.name) == ["Tomas", "Mateo", "Valentina"])
        // Search by country, language or name.
        #expect(VoiceChoice.groups(r.voices, query: "urug").flatMap(\.voices).count == 2)
        #expect(VoiceChoice.groups(r.voices, query: "german").map(\.title) == ["German"])
        #expect(VoiceChoice.groups(r.voices, query: "aria").flatMap(\.voices).map(\.shortName) == ["en-US-AriaNeural"])
        #expect(VoiceChoice.groups(r.voices, query: "zzz").isEmpty)
    }

    @Test func displayNames() {
        #expect(VoiceChoice.displayName("es-UY-MateoNeural") == "Mateo (Uruguay)")
        #expect(VoiceChoice.displayName("fr-FR-DeniseNeural") == "Denise (FR)")
        #expect(VoiceChoice.sample(language: "es", name: "Mateo").hasPrefix("Hola, soy Mateo"))
    }

    // MARK: On-device fallback

    @Test func deviceVoicePrefersUruguayanSpanish() {
        let c: [(id: String, language: String, quality: Int)] = [
            ("en", "en-US", 3), ("esES", "es-ES", 3), ("esMX", "es-MX", 1), ("esUY", "es-UY", 1)]
        #expect(VoiceChoice.deviceVoice(spanish: true, phoneLanguage: "en-US", candidates: c) == "esUY")
        #expect(VoiceChoice.deviceVoice(spanish: true, phoneLanguage: "en-US", candidates: Array(c.prefix(3))) == "esMX")
        #expect(VoiceChoice.deviceVoice(spanish: false, phoneLanguage: "en-US", candidates: c) == "en")
        #expect(VoiceChoice.deviceVoice(spanish: true, phoneLanguage: "en-US", candidates: [c[0]]) == nil)
    }
}
