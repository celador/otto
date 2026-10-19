import AVFoundation
import Observation
import Speech

/// Speech-to-text into the composer, like the mic in the ChatGPT and Claude
/// apps. Text streams in live; tapping the mic again (or Send) stops it.
@MainActor
@Observable
final class Dictation {
    private(set) var isRecording = false
    /// 0…1, smoothed input loudness for the recording indicator.
    private(set) var level: Float = 0
    var errorMessage: String?

    /// Called with the full draft (text typed before recording + transcript).
    var onText: ((String) -> Void)?
    /// Set → after you stop with the mic button, Parakeet on the Mac re-transcribes what you said
    /// (more accurate than Apple's live text) and `onRefined(old, new)` swaps it in.
    var companion: CompanionClient?
    var onRefined: ((_ expected: String, _ refined: String) -> Void)?
    private var lastText = ""
    @ObservationIgnored private var recorded = TurnAudio(keep: 600)
    @ObservationIgnored private var encoder: LiveMicEncoder?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var prefix = ""
    /// Bumped on every start/stop; results from an older session are dropped.
    private var generation = 0

    func toggle(current: String) async {
        if isRecording { stopAndRefine() } else { await start(current: current) }
    }

    /// Mic button pressed again: stop, then replace Apple's text with Parakeet's if the draft is untouched.
    func stopAndRefine() {
        guard isRecording else { return }
        let pcm = recorded.slice(since: .distantPast)
        let expected = lastText
        let prefix = self.prefix
        stop()
        guard LocalVoice.enabled, let companion, pcm.count >= 16_000 / 2, !expected.isEmpty else { return }
        let gen = generation
        Task {
            guard let text = try? await companion.localTranscribe(pcm16k: pcm) else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard gen == generation, !clean.isEmpty, prefix + clean != expected else { return }
            onRefined?(expected, prefix + clean)
        }
    }

    func start(current: String) async {
        guard !isRecording else { return }
        errorMessage = nil
        guard await Self.requestPermissions() else {
            errorMessage = "Allow Microphone and Speech Recognition for Otto in Settings to dictate."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Dictation isn't available right now."
            return
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        prefix = trimmed.isEmpty ? "" : trimmed + " "

#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
#endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            errorMessage = "No microphone available."
            return
        }
        recorded = TurnAudio(keep: 600)
        let recorded = self.recorded
        let encoder = LiveMicEncoder { recorded.append($0) }
        self.encoder = encoder
        lastText = ""
        Self.installTap(on: input, format: format, request: request, encoder: encoder) { [weak self] level in
            Task { @MainActor in self?.level = self.map { $0.level * 0.6 + level * 0.4 } ?? level }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }

        self.engine = engine
        self.request = request
        isRecording = true
        generation += 1
        let gen = generation
        task = Self.recognize(recognizer, request: request) { [weak self] text, isFinal, failed in
            Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed, generation: gen) }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        level = 0
        // Anything the recognizer sends after this point is ignored, so a
        // late final result can't refill the box after the message was sent.
        generation += 1
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        engine = nil
        request = nil
        let stale = task
        task = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            stale?.cancel()
#if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool, generation gen: Int) {
        guard gen == generation, isRecording else { return }
        if let text, !text.isEmpty {
            lastText = prefix + text
            onText?(lastText)
        }
        if (failed && text == nil) || isFinal {
            // Recognizer finished or gave up (e.g. long silence); keep the text.
            stop()
        }
    }

    // MARK: Off-main helpers (their closures run on audio / speech threads)

    nonisolated private static func installTap(
        on input: AVAudioInputNode, format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest, encoder: LiveMicEncoder,
        level: @escaping @Sendable (Float) -> Void
    ) {
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            encoder.append(buffer)
            level(Self.rms(buffer))
        }
    }

    nonisolated private static func recognize(
        _ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        // Map roughly -50 dB…-10 dB to 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 40))
    }

    nonisolated private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
