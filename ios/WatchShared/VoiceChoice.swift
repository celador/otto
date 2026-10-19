import Foundation
import NaturalLanguage

/// One Edge neural voice, as listed by the relay's `GET /hermes/voices`.
struct EdgeVoice: Codable, Hashable, Identifiable, Sendable {
    let shortName: String
    let locale: String
    let gender: String
    let name: String
    let localeName: String

    var id: String { shortName }
    /// "es" for "es-UY".
    var language: String { String(locale.split(separator: "-").first ?? "").lowercased() }
    /// "Uruguay" from "Spanish (Uruguay)"; falls back to the locale's region code.
    var region: String {
        if let open = localeName.lastIndex(of: "("), let close = localeName.lastIndex(of: ")"), open < close {
            return String(localeName[localeName.index(after: open)..<close])
        }
        return String(locale.split(separator: "-").last ?? "")
    }
    /// "Mateo (Uruguay)".
    var label: String { region.isEmpty ? name : "\(name) (\(region))" }
}

/// `GET /hermes/voices`: Edge's voice list plus the profile's own voice ("Hermes default").
struct VoicesResponse: Codable, Sendable {
    let `default`: String
    let provider: String
    let voices: [EdgeVoice]
}

/// Voices grouped by language for the picker.
struct VoiceGroup: Identifiable, Hashable, Sendable {
    let id: String          // language code
    let title: String       // "Spanish"
    let voices: [EdgeVoice]
}

/// One stretch of a reply and the voice that reads it.
struct SpeechSegment: Equatable, Sendable {
    var text: String
    /// nil = the profile's voice (no `voice` sent to the relay).
    var voice: String?
    var spanish: Bool
}

/// A hand-picked voice shown as a pill at the top of the picker (like Fícha's TV settings).
struct CuratedVoice: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

/// The voice the user picked for spoken replies and read-aloud, and the pure decisions around it:
/// which voice reads which sentence (Spanish → the Spanish voice), the relay request body,
/// grouping/search for the picker and the on-device fallback voice. No audio, no UI.
enum VoiceChoice {
    // MARK: Settings (UserDefaults; the phone and the TV each keep their own)

    nonisolated static let mainKey = "voice.main"
    nonisolated static let spanishKey = "voice.spanish"
    nonisolated static let speedKey = "voice.speed"
    /// "" in `mainKey` = the Hermes profile's own voice.
    nonisolated static let hermesDefault = ""
    /// "" in `spanishKey` = Spanish sentences use the main voice too.
    nonisolated static let sameAsMain = ""
    nonisolated static let defaultSpanish = "es-UY-MateoNeural"
    nonisolated static let speedRange: ClosedRange<Double> = 0.8...1.5

    nonisolated static var main: String { UserDefaults.standard.string(forKey: mainKey) ?? hermesDefault }
    nonisolated static var spanish: String { UserDefaults.standard.string(forKey: spanishKey) ?? defaultSpanish }
    nonisolated static var speed: Double {
        let v = UserDefaults.standard.object(forKey: speedKey) as? Double ?? 1.0
        return min(max(v, speedRange.lowerBound), speedRange.upperBound)
    }

    // MARK: Curated voices (pills at the top of the picker)

    nonisolated static let curatedMain: [CuratedVoice] = [
        // Kokoro, rendered on the Mac (no cloud).
        CuratedVoice(id: "kokoro:af_heart", label: "Heart (on your Mac)"),
        CuratedVoice(id: "kokoro:af_bella", label: "Bella (on your Mac)"),
        CuratedVoice(id: "kokoro:am_michael", label: "Michael (on your Mac)"),
        CuratedVoice(id: "kokoro:bf_emma", label: "Emma (UK, on your Mac)"),
        CuratedVoice(id: "kokoro:bm_george", label: "George (UK, on your Mac)"),
        CuratedVoice(id: "en-US-AriaNeural", label: "Aria (US)"),
        CuratedVoice(id: "en-US-AndrewNeural", label: "Andrew (US)"),
        CuratedVoice(id: "en-US-AvaMultilingualNeural", label: "Ava (US, multilingual)"),
        CuratedVoice(id: "en-GB-SoniaNeural", label: "Sonia (UK)"),
        CuratedVoice(id: "en-GB-RyanNeural", label: "Ryan (UK)"),
        CuratedVoice(id: "en-AU-NatashaNeural", label: "Natasha (Australia)"),
    ]

    nonisolated static let curatedSpanish: [CuratedVoice] = [
        CuratedVoice(id: "es-UY-MateoNeural", label: "Mateo (Uruguay)"),
        CuratedVoice(id: "es-UY-ValentinaNeural", label: "Valentina (Uruguay)"),
        CuratedVoice(id: "es-AR-TomasNeural", label: "Tomás (Argentina)"),
        CuratedVoice(id: "es-AR-ElenaNeural", label: "Elena (Argentina)"),
    ]

    /// A friendly name for a stored voice id: curated label, then the relay's list, then the id itself.
    nonisolated static func displayName(_ shortName: String, in voices: [EdgeVoice] = []) -> String {
        if let c = (curatedSpanish + curatedMain).first(where: { $0.id == shortName }) { return c.label }
        if let v = voices.first(where: { $0.shortName == shortName }) { return v.label }
        // "es-UY-MateoNeural" -> "Mateo (UY)"
        let parts = shortName.split(separator: "-")
        guard parts.count >= 3 else { return shortName }
        var name = String(parts.last!)
        if name.hasSuffix("Neural") { name.removeLast(6) }
        return "\(name) (\(parts[1]))"
    }

    // MARK: Language routing

    /// true = Spanish, false = clearly another language, nil = too short to tell.
    nonisolated static func isSpanish(_ text: String) -> Bool? {
        let letters = text.filter(\.isLetter)
        if text.contains("¿") || text.contains("¡") { return true }
        guard letters.count >= 12 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(text)
        let hyp = r.languageHypotheses(withMaximum: 2)
        guard let (top, p) = hyp.max(by: { $0.value < $1.value }) else { return nil }
        if top == .spanish { return p >= 0.5 }
        return p >= 0.5 ? false : nil
    }

    /// Which voice reads a sentence: Spanish → the Spanish voice (unless "same as main"),
    /// otherwise the main voice. Short sentences ("Sí.", "OK.") keep the previous language.
    nonisolated static func voice(for text: String, main: String, spanish: String,
                                  previousSpanish: Bool) -> SpeechSegment {
        let isEs = isSpanish(text) ?? previousSpanish
        let chosen = isEs && spanish != sameAsMain ? spanish : main
        return SpeechSegment(text: text, voice: chosen.isEmpty ? nil : chosen, spanish: isEs)
    }

    /// A reply split into sentences, each routed to a voice, with neighbours that share a voice
    /// merged (up to `maxChars`) so read-aloud makes few requests.
    nonisolated static func plan(_ text: String, main: String, spanish: String,
                                 maxChars: Int = 400) -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        var previous = false
        for sentence in sentences(text) {
            let seg = voice(for: sentence, main: main, spanish: spanish, previousSpanish: previous)
            previous = seg.spanish
            if var last = out.last, last.voice == seg.voice, last.spanish == seg.spanish,
               last.text.count + sentence.count + 1 <= maxChars {
                last.text += " " + sentence
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }

    nonisolated static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    // MARK: Relay request

    /// Speed multiplier to send, nil at normal speed (the profile's own speed applies).
    nonisolated static func rate(for speed: Double) -> Double? {
        let s = (min(max(speed, 0.5), 2.0) * 100).rounded() / 100
        return abs(s - 1.0) < 0.005 ? nil : s
    }

    /// Body for `POST /hermes/speak` and `/hermes/speak/stream`.
    nonisolated static func speakBody(_ text: String, voice: String?, speed: Double) -> [String: Any] {
        var body: [String: Any] = ["text": String(text.prefix(4000))]
        if let voice, !voice.isEmpty { body["voice"] = voice }
        if let r = rate(for: speed) { body["rate"] = r }
        return body
    }

    nonisolated static func decodeVoices(_ data: Data) throws -> VoicesResponse {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(VoicesResponse.self, from: data)
    }

    // MARK: Picker

    /// Voices matching `query`, grouped by language: Spanish and English first, then A–Z.
    nonisolated static func groups(_ voices: [EdgeVoice], query: String = "",
                                   locale: Locale = Locale(identifier: "en")) -> [VoiceGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let byLang = Dictionary(grouping: voices) { $0.language }
        func title(_ code: String) -> String { locale.localizedString(forLanguageCode: code) ?? code }
        var groups: [VoiceGroup] = byLang.compactMap { code, vs in
            let t = title(code)
            let hits = q.isEmpty || t.lowercased().contains(q) ? vs : vs.filter {
                [$0.name, $0.localeName, $0.shortName, $0.locale, $0.gender].contains { $0.lowercased().contains(q) }
            }
            guard !hits.isEmpty else { return nil }
            return VoiceGroup(id: code, title: t,
                              voices: hits.sorted { ($0.region, $0.name) < ($1.region, $1.name) })
        }
        let pinned = ["es", "en"]
        groups.sort { a, b in
            let ia = pinned.firstIndex(of: a.id) ?? pinned.count, ib = pinned.firstIndex(of: b.id) ?? pinned.count
            return ia != ib ? ia < ib : a.title < b.title
        }
        return groups
    }

    /// A short line in the voice's own language for the Preview button.
    nonisolated static func sample(for voice: EdgeVoice) -> String { sample(language: voice.language, name: voice.name) }

    nonisolated static func sample(language: String, name: String) -> String {
        switch language {
        case "es": return "Hola, soy \(name). Así suena mi voz cuando te leo las respuestas."
        case "pt": return "Olá, eu sou \(name). É assim que eu leio as suas respostas."
        case "fr": return "Bonjour, je suis \(name). Voici comment je lis vos réponses."
        case "de": return "Hallo, ich bin \(name). So klingt es, wenn ich deine Antworten vorlese."
        case "it": return "Ciao, sono \(name). Ecco come leggo le tue risposte."
        default: return "Hi, I'm \(name). This is how I'll sound reading your replies."
        }
    }

    // MARK: On-device fallback voice

    /// Best installed voice for a sentence: for Spanish es-UY, then es-AR, es-419/MX/US, es-ES,
    /// any es-*; otherwise the phone's language. Within a tier, the highest quality wins.
    /// `candidates`: (identifier, BCP-47 language, quality rank).
    nonisolated static func deviceVoice(spanish: Bool, phoneLanguage: String,
                                        candidates: [(id: String, language: String, quality: Int)]) -> String? {
        let tiers: [(String) -> Bool]
        if spanish {
            tiers = [{ $0 == "es-UY" }, { $0 == "es-AR" }, { ["es-419", "es-MX", "es-US"].contains($0) },
                     { $0 == "es-ES" }, { $0.hasPrefix("es") }]
        } else {
            let base = String(phoneLanguage.prefix(2))
            tiers = [{ $0 == phoneLanguage }, { $0.hasPrefix(base) }]
        }
        for tier in tiers {
            if let best = candidates.filter({ tier($0.language) }).max(by: { $0.quality < $1.quality }) {
                return best.id
            }
        }
        return nil
    }
}
