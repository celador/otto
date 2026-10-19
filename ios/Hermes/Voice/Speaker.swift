import AVFoundation
import Observation

/// "Read aloud" for replies, like the speaker button in ChatGPT and Claude. Uses the voice picked in
/// Settings → Voice through the relay (Spanish sentences in the Spanish voice), falling back to the
/// iPhone's own voice when the relay can't speak.
@MainActor
@Observable
final class Speaker: NSObject {
    static let shared = Speaker()

    /// The message currently being read, so its button can show "Stop".
    private(set) var speakingID: String?
    /// Set by the chat screen; nil = on-device voice only.
    @ObservationIgnored var companion: CompanionClient?
    @ObservationIgnored var profile = "default"

    private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var deviceDone: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(id: String, text: String) {
        if speakingID == id { stop(); return }
        stop()
        let spoken = SpeechText.clean(text)
        guard !spoken.isEmpty else { return }
#if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
        speakingID = id
        let segments = VoiceChoice.plan(spoken, main: VoiceChoice.main, spanish: VoiceChoice.spanish)
        task = Task { [weak self] in
            await self?.read(segments, id: id)
            guard let self, self.speakingID == id else { return }
            self.finished()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        resumeDevice()
        speakingID = nil
    }

    private func read(_ segments: [SpeechSegment], id: String) async {
        let speed = VoiceChoice.speed
        var useRelay = companion != nil
        var next: Task<Data?, Never>? = nil
        func fetch(_ seg: SpeechSegment) -> Task<Data?, Never>? {
            guard useRelay, let c = companion else { return nil }
            let profile = self.profile
            return Task { try? await c.speak(seg.text, profile: profile, voice: seg.voice, speed: speed) }
        }
        if let first = segments.first { next = fetch(first) }
        for (i, seg) in segments.enumerated() {
            let data = await next?.value
            next = i + 1 < segments.count ? fetch(segments[i + 1]) : nil
            if Task.isCancelled || speakingID != id { next?.cancel(); return }
            if let data, let p = try? AVAudioPlayer(data: data) {
                player = p
                p.play()
                while p.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                player = nil
            } else {
                if data == nil, useRelay { useRelay = false; next?.cancel(); next = nil }
                await speakOnDevice(seg, speed: speed)
            }
            if Task.isCancelled || speakingID != id { return }
        }
    }

    private func speakOnDevice(_ seg: SpeechSegment, speed: Double) async {
        let u = AVSpeechUtterance(string: seg.text)
        u.voice = DeviceVoice.pick(spanish: seg.spanish)
        u.rate = DeviceVoice.rate(speed: speed)
        await withCheckedContinuation { c in
            deviceDone = c
            synth.speak(u)
        }
    }

    private func resumeDevice() {
        let c = deviceDone
        deviceDone = nil
        c?.resume()
    }

    private func finished() {
        speakingID = nil
        task = nil
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeDevice() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeDevice() }
    }
}

/// The iPhone's own voice, used when the relay can't speak.
enum DeviceVoice {
    /// Spanish → es-UY/es-AR/… (best quality installed); otherwise the phone's language.
    static func pick(spanish: Bool) -> AVSpeechSynthesisVoice? {
        let phone = AVSpeechSynthesisVoice.currentLanguageCode()
        let all = AVSpeechSynthesisVoice.speechVoices()
        let id = VoiceChoice.deviceVoice(spanish: spanish, phoneLanguage: phone,
                                         candidates: all.map { ($0.identifier, $0.language, $0.quality.rawValue) })
        return id.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: spanish ? "es-UY" : phone)
            ?? AVSpeechSynthesisVoice(language: spanish ? "es-ES" : phone)
    }

    static func rate(speed: Double) -> Float {
        min(max(AVSpeechUtteranceDefaultSpeechRate * 1.05 * Float(speed), AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate)
    }
}

/// Settings → Voice → Preview: one short line in a voice, through the relay (or the iPhone voice).
@MainActor
@Observable
final class VoicePreview {
    static let shared = VoicePreview()
    /// The voice being fetched or played ("" = Hermes default).
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let synth = AVSpeechSynthesizer()

    func play(voice: String, sample: String, spanish: Bool, companion: CompanionClient?) {
        if playing == voice { stop(); return }
        stop()
        Speaker.shared.stop()
        playing = voice
        task = Task { [weak self] in
#if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
#endif
            let data = try? await companion?.speak(sample, profile: "default", voice: voice.isEmpty ? nil : voice,
                                                   speed: VoiceChoice.speed)
            guard let self, !Task.isCancelled, self.playing == voice else { return }
            if let data, let p = try? AVAudioPlayer(data: data) {
                self.player = p
                p.play()
                while p.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            } else {
                let u = AVSpeechUtterance(string: sample)
                u.voice = DeviceVoice.pick(spanish: spanish)
                u.rate = DeviceVoice.rate(speed: VoiceChoice.speed)
                self.synth.speak(u)
                try? await Task.sleep(for: .milliseconds(300))
                while self.synth.isSpeaking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            }
            if self.playing == voice { self.playing = nil }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        playing = nil
    }
}

/// Markdown → something pleasant to listen to.
enum SpeechText {
    static func clean(_ markdown: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in markdown.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if !inCode { out.append("(code omitted)") }
                inCode.toggle()
                continue
            }
            if inCode { continue }
            if t.hasPrefix("|") {
                // Table rows: read the cells, skip separator lines.
                if t.allSatisfy({ "|-: ".contains($0) }) { continue }
                out.append(MarkdownBlocks.cells(t).joined(separator: ", "))
                continue
            }
            out.append(inline(t))
        }
        return out.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inline(_ line: String) -> String {
        var s = line
        // Headings and list markers.
        s = s.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[-*+]\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^>\\s?", with: "", options: .regularExpression)
        // Images and links keep their text.
        s = s.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        // Emphasis, strikethrough, inline code.
        s = s.replacingOccurrences(of: "(\\*\\*|__|~~|\\*|`)", with: "", options: .regularExpression)
        // Bare URLs are noise when spoken.
        s = s.replacingOccurrences(of: "https?://\\S+", with: "link", options: .regularExpression)
        return s
    }
}
