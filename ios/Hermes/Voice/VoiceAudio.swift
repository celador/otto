import AudioToolbox
import AVFoundation
import Speech
#if os(iOS)
import UIKit
#endif

/// One audio engine for the whole voice conversation: the mic and the reply share it, so the
/// voice-processing unit's echo canceller has the reply as its reference and the mic can stay on
/// while Otto talks (full duplex, barge-in).
///
/// Main-actor owned. The mic tap runs on the audio thread and only touches `RequestBox` (locked)
/// and the `onInput` callback.
@MainActor
final class VoiceAudio {
    /// Every reply buffer is converted to this before scheduling (Edge TTS is 24 kHz mono).
    nonisolated static let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                                          channels: 1, interleaved: false)!

    private var engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    /// Short UI cues (headphone press landed, turn sent). Separate from `player` so a cue never counts
    /// as Otto speaking, but in the same engine so the echo canceller removes it from the mic.
    private let cuePlayer = AVAudioPlayerNode()
    /// Mic levels are reported as silence until then (a cue just played; keeps it out of barge-in/VAD).
    private var inputSuppressedUntil = Date.distantPast
    private let requests = RequestBox()
    /// Raw mic buffers for Gemini Live (audio thread; nil = not streaming).
    let pcmSink = PCMSinkBox()
    private var configObserver: NSObjectProtocol?

    /// Mic level in dBFS and the buffer's duration (audio thread → main).
    var onInput: ((Float, TimeInterval) -> Void)?
    /// Playback level 0…1 for the orb.
    var onOutputLevel: ((Float) -> Void)?
    /// The engine had to be rebuilt (route change, e.g. AirPods connected).
    var onRestart: (() -> Void)?

    /// Echo cancellation on. Falls back to off when the voice-processing engine won't run on this
    /// device/route; then the mic is paused while Otto talks (tap to interrupt instead of talking over).
    private(set) var useVoiceProcessing = !UserDefaults.standard.bool(forKey: "hermes.voiceNoVP")
    var fullDuplex: Bool { useVoiceProcessing }

    private(set) var scheduled = 0
    private(set) var played = 0
    /// Bumped by `stopPlayback()`: completions from dropped buffers are ignored.
    private var playbackGeneration = 0
    var onBufferPlayed: ((Int) -> Void)?

    var isPlaying: Bool { played < scheduled }
    var isRunning: Bool { engine?.isRunning == true }

    /// How many voice-processing attempts failed this session; drives the fallback ladder:
    /// 0–1 session mode .voiceChat → 2 mode .default (engine VP only) → 3+ half-duplex.
    private(set) var vpAttempts = 0

    /// Audio session for a two-way conversation. Must be active BEFORE the engine touches `inputNode`
    /// (the I/O unit takes its formats from the session at that moment). Only changes what differs, so
    /// the watchdog calling it doesn't itself post route/config changes. Returns whether the session is
    /// active: a refused activation is NOT a voice-processing problem and must not climb the VP ladder.
    @discardableResult
    func configureSession() -> Bool {
#if os(iOS)
        let s = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = (useVoiceProcessing && vpAttempts >= 2) ? .default : .voiceChat
        let background = Self.inBackground
        var options = Self.sessionOptions(background: background)
        do {
            try activate(s, mode: mode, options: options)
            return true
        } catch {
            VoiceDiag.log("audio session setup failed: \(error) (\(Self.fourCC(error)), background=\(background))")
        }
        // '!int' (can't interrupt others) from the background: retry mixing instead of ducking.
        guard !options.contains(.mixWithOthers) || options.contains(.duckOthers) else { return false }
        options = Self.sessionOptions(background: true)
        options.remove(.duckOthers)
        do {
            try activate(s, mode: mode, options: options)
            VoiceDiag.log("audio session active after retry with mixWithOthers")
            return true
        } catch {
            VoiceDiag.log("audio session retry failed: \(error) (\(Self.fourCC(error)))")
            return false
        }
#else
        return true
#endif
    }

#if os(iOS)
    private func activate(_ s: AVAudioSession, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        if s.category != .playAndRecord || s.mode != mode || s.categoryOptions != options {
            try s.setCategory(.playAndRecord, mode: mode, options: options)
        }
        // The built-in mic runs at 48 kHz; ask for the same on output so the voice-processing unit
        // doesn't have to bridge 48k in / 44.1k out (seen on iPhone 16 Pro: the VP engine never ran).
        if s.preferredSampleRate != 48_000 { try? s.setPreferredSampleRate(48_000) }
        try s.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// In front: a non-mixable session (other audio pauses, like a call), which makes Otto the Now
    /// Playing app so the headphone play/pause button reaches it (a mixable/ducking session never gets
    /// remote commands). In the background (Action button, Siri, locked phone) iOS refuses to let a
    /// background app interrupt others ('!int'), so mix instead (the AirPods mute toggle still works).
    nonisolated static func sessionOptions(background: Bool) -> AVAudioSession.CategoryOptions {
        var o: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        if background { o.insert(.mixWithOthers) }
        return o
    }

    static var inBackground: Bool { UIApplication.shared.applicationState != .active }
#else
    static var inBackground: Bool { false }
#endif

    /// `NSOSStatusErrorDomain 560557684` -> "!int" (AVAudioSession/Core Audio four-char codes).
    nonisolated static func fourCC(_ error: Error) -> String {
        fourCC(Int32(truncatingIfNeeded: (error as NSError).code))
    }

    nonisolated static func fourCC(_ code: Int32) -> String {
        let u = UInt32(bitPattern: code)
        let bytes = [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(code) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func describeSession() -> String {
#if os(iOS)
        let s = AVAudioSession.sharedInstance()
        return "session cat=\(s.category.rawValue) mode=\(s.mode.rawValue) rate=\(Int(s.sampleRate)) pref=\(Int(s.preferredSampleRate)) io=\(String(format: "%.3f", s.ioBufferDuration)) inCh=\(s.inputNumberOfChannels) outCh=\(s.outputNumberOfChannels)"
#else
        return "session n/a"
#endif
    }

    func start() throws {
        stop()
        guard configureSession() else { throw VoiceAudioError.sessionRefused }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Voice processing = acoustic echo cancellation + noise suppression. Our own playback
        // goes through the same unit, so it's cancelled from the mic signal. Enabled while the engine
        // is stopped and before the graph is wired, so every format below is the VP one.
        if useVoiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) } catch {
                VoiceDiag.log("voice processing unavailable: \(error)")
                useVoiceProcessing = false
            }
        }
        if useVoiceProcessing, #available(iOS 17.0, macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        do { try wire(engine) } catch {
            if player.engine === engine { engine.detach(player) }
            if cuePlayer.engine === engine { engine.detach(cuePlayer) }
            throw error
        }
        engine.prepare()
        do { try engine.start() } catch {
            VoiceDiag.log("engine.start threw: \(error) \(describeSession())")
            engine.inputNode.removeTap(onBus: 0)
            player.removeTap(onBus: 0)
            engine.detach(player)
            engine.detach(cuePlayer)
            // From the background iOS refuses the I/O start itself ('what' at kAUStartIO): not a VP fault,
            // so don't burn the ladder (it then failed with '!int' on the retry). The caller falls back.
            if Self.inBackground {
                VoiceDiag.log("engine.start refused in the background (\(Self.fourCC(error))): not retrying voice processing")
                throw VoiceAudioError.backgroundRefused
            }
            if useVoiceProcessing { return try failVoiceProcessing(reason: "start threw") }
            throw error
        }
        self.engine = engine
        observeConfigChanges(engine)
        if !engine.isRunning {
            // Enabling VP reconfigures the I/O unit; the engine can come up stopped. Re-wire with the
            // formats it settled on and start the SAME engine (a new engine re-enables VP → same loop).
            VoiceDiag.log("engine not running right after start: \(describe()) \(describeSession())")
            if !restartInPlace(), useVoiceProcessing { return try failVoiceProcessing(reason: "not running after start") }
        }
        VoiceDiag.log("engine up (attempt \(vpAttempts), vp=\(useVoiceProcessing)): \(describe()) \(describeSession())")
    }

    /// One voice-processing setup failed: climb the ladder (other session mode, then half-duplex).
    private func failVoiceProcessing(reason: String) throws {
        vpAttempts += 1
        if vpAttempts >= 3 {
            VoiceDiag.log("voice processing failed (\(reason)) \(vpAttempts)x: half-duplex from now on")
            useVoiceProcessing = false
        } else {
            VoiceDiag.log("voice processing failed (\(reason)); retrying with session mode \(vpAttempts >= 2 ? "default" : "voiceChat")")
        }
        try start()
    }

    /// Player → main mixer → output, mic tap, level tap — all from the engine's CURRENT formats.
    private func wire(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceAudioError.noMicrophone }
        if player.engine == nil { engine.attach(player) }
        if cuePlayer.engine == nil { engine.attach(cuePlayer) }
        // The mixer feeds the output at the output's own rate (VP may not run it at the mic's rate);
        // the mixer converts the 24 kHz reply.
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let outFormat = hw.sampleRate > 0 && hw.channelCount > 0
            ? AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: min(hw.channelCount, 2))
            : nil
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outFormat)
        engine.connect(player, to: engine.mainMixerNode, format: Self.playbackFormat)
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: Self.playbackFormat)

        input.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        let box = requests
        Self.installInputTap(on: input, format: format, box: box, sink: pcmSink) { [weak self] db, duration in
            Task { @MainActor in
                guard let self else { return }
                self.onInput?(Date() < self.inputSuppressedUntil ? -100 : db, duration)
            }
        }
        Self.installLevelTap(on: player) { [weak self] level in
            Task { @MainActor in self?.onOutputLevel?(level) }
        }
    }

    /// Restart the current engine after a configuration change: re-wire with the new formats, start.
    @discardableResult
    func restartInPlace() -> Bool {
        guard let engine else { return false }
        if engine.isRunning { return true }
        engine.stop()
        do { try wire(engine) } catch {
            VoiceDiag.log("re-wire failed: \(error)")
            return false
        }
        engine.prepare()
        do { try engine.start() } catch {
            VoiceDiag.log("in-place restart threw: \(error)")
            return false
        }
        VoiceDiag.log("in-place restart: \(describe())")
        return engine.isRunning
    }

    private func observeConfigChanges(_ engine: AVAudioEngine) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAfterConfigChange() }
        }
    }

    func describe() -> String {
        guard let engine else { return "no engine" }
        let i = engine.inputNode.outputFormat(forBus: 0), o = engine.outputNode.outputFormat(forBus: 0)
#if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        return "running=\(engine.isRunning) vp=\(engine.inputNode.isVoiceProcessingEnabled) in=\(i.channelCount)ch@\(Int(i.sampleRate)) out=\(o.channelCount)ch@\(Int(o.sampleRate)) route=\(route.inputs.map(\.portType.rawValue))->\(route.outputs.map(\.portType.rawValue)) mixerVol=\(engine.mainMixerNode.outputVolume)"
#else
        return "running=\(engine.isRunning) vp=\(engine.inputNode.isVoiceProcessingEnabled) in=\(i.channelCount)ch@\(Int(i.sampleRate)) out=\(o.channelCount)ch@\(Int(o.sampleRate)) mixerVol=\(engine.mainMixerNode.outputVolume)"
#endif
    }

    func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        stopPlayback()
        requests.set(nil)
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        engine.stop()
        engine.detach(player)
        if cuePlayer.engine === engine { engine.detach(cuePlayer) }
        self.engine = nil
    }

    private var pendingRestart: Task<Void, Never>?

    /// Route/format changes (and enabling voice processing itself) stop the engine. Debounced: wait for
    /// the burst of change notifications to settle, then restart the same engine; only if that fails,
    /// build a new one.
    private func restartAfterConfigChange() {
        guard engine != nil else { return }
        pendingRestart?.cancel()
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.engine != nil else { return }
            VoiceDiag.log("config change settled: \(self.describe())")
            if self.engine?.isRunning == true || self.restartInPlace() { self.onRestart?(); return }
            self.rebuild()
        }
    }

    /// Brings a stopped engine back (watchdog): same engine first, then a new one.
    @discardableResult
    func recover() -> Bool {
        if restartInPlace() { onRestart?(); return true }
        return rebuild()
    }

    /// Restarts with a new engine keeping the current recognition request. Returns whether it's running.
    private var rebuilds: [Date] = []

    @discardableResult
    func rebuild() -> Bool {
        let request = requests.current
        // The voice-processing engine keeps stopping: climb the ladder rather than leave the user
        // with a dead mic.
        let now = Date()
        rebuilds = rebuilds.filter { now.timeIntervalSince($0) < 6 } + [now]
        if useVoiceProcessing, rebuilds.count >= 2 {
            vpAttempts += 1
            rebuilds = []
            if vpAttempts >= 3 {
                VoiceDiag.log("voice processing engine keeps stopping: switching to half-duplex")
                useVoiceProcessing = false
            } else {
                VoiceDiag.log("voice processing engine keeps stopping: retrying (attempt \(vpAttempts))")
            }
        }
        do {
            try start()
            requests.set(request)
        } catch {
            VoiceDiag.log("rebuild failed: \(error)")
        }
        onRestart?()
        return isRunning
    }

    /// Plays a short cue now (cutting off any cue still playing). The mic reads as silence meanwhile.
    func playCue(_ buffer: AVAudioPCMBuffer) {
        guard let engine, engine.isRunning, cuePlayer.engine === engine, buffer.frameLength > 0 else { return }
        cuePlayer.stop()
        cuePlayer.scheduleBuffer(buffer, completionHandler: nil)
        cuePlayer.play()
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        inputSuppressedUntil = Date().addingTimeInterval(seconds + 0.15)
    }

    /// The voice-processing unit's own input mute off (a headphone mute gesture may have set it).
    func clearInputMute() {
        guard let input = engine?.inputNode, input.isVoiceProcessingEnabled, input.isVoiceProcessingInputMuted else { return }
        input.isVoiceProcessingInputMuted = false
        VoiceDiag.log("voice processing input was muted; unmuted")
    }

    /// Self-test: play silently (the pipeline runs, nothing is heard).
    func muteOutput() { engine?.mainMixerNode.outputVolume = 0 }

    // MARK: Mic → recognizer

    /// The recognition request the mic feeds (nil = mic audio is dropped, e.g. muted).
    func feed(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        requests.set(request)
    }

    // MARK: Playback

    /// Queues a buffer (already in `playbackFormat`). Returns its 1-based index.
    @discardableResult
    func schedule(_ buffer: AVAudioPCMBuffer) -> Int {
        guard let engine, engine.isRunning, buffer.frameLength > 0 else {
            VoiceDiag.log("schedule dropped: engine=\(engine != nil) running=\(engine?.isRunning ?? false) frames=\(buffer.frameLength)")
            return scheduled
        }
        scheduled += 1
        let index = scheduled
        let gen = playbackGeneration
        Self.schedule(buffer, on: player) { [weak self] in
            Task { @MainActor in
                guard let self, gen == self.playbackGeneration else { return }
                self.played = max(self.played, index)
                self.onBufferPlayed?(index)
            }
        }
        if !player.isPlaying { player.play() }
        return index
    }

    // Audio-thread callbacks are set up in nonisolated code so they don't inherit main-actor isolation
    // (Swift 6 would trap when the audio thread calls them).
    nonisolated private static func installInputTap(on input: AVAudioInputNode, format: AVAudioFormat, box: RequestBox,
                                                    sink: PCMSinkBox,
                                                    handler: @escaping @Sendable (Float, TimeInterval) -> Void) {
        let rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
            sink.send(buffer)
            handler(decibels(buffer), Double(buffer.frameLength) / rate)
        }
    }

    nonisolated private static func installLevelTap(on node: AVAudioPlayerNode,
                                                    handler: @escaping @Sendable (Float) -> Void) {
        node.installTap(onBus: 0, bufferSize: 1024, format: playbackFormat) { buffer, _ in
            handler(max(0, min(1, (decibels(buffer) + 45) / 40)))
        }
    }

    nonisolated private static func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode,
                                             done: @escaping @Sendable () -> Void) {
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }

    /// Cuts the reply off now and drops everything queued.
    func stopPlayback() {
        playbackGeneration += 1
        if engine != nil { player.stop() }
        played = scheduled
        onOutputLevel?(0)
    }

    // MARK: Helpers

    nonisolated static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return 20 * log10(max((sum / Float(n)).squareRoot(), 0.000_01))
    }
}

enum VoiceAudioError: Error {
    case noMicrophone
    /// The audio session wouldn't activate (e.g. '!int' / '!pla' from the background).
    case sessionRefused
    /// The I/O unit wouldn't start from the background.
    case backgroundRefused
}

/// Where raw mic audio goes besides the recognizer (Gemini Live's encoder). Set from the main actor,
/// called on the audio thread.
final class PCMSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func set(_ h: (@Sendable (AVAudioPCMBuffer) -> Void)?) { lock.withLock { handler = h } }
    func send(_ buffer: AVAudioPCMBuffer) { lock.withLock { handler }?(buffer) }
}

/// The current recognition request, swapped from the main actor, appended to from the audio thread.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    var current: SFSpeechAudioBufferRecognitionRequest? { lock.withLock { request } }
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = r } }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request }?.append(buffer) }
}

// MARK: - MP3 stream → PCM

/// Decodes MP3 as it arrives (chunked HTTP) into `VoiceAudio.playbackFormat` buffers.
/// Feed bytes in order; call `finish()` at the end to flush the decoder.
final class MP3StreamDecoder {
    private var stream: AudioFileStreamID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var framesPerPacket: UInt32 = 1152
    private var ready: [AVAudioPCMBuffer] = []
    private let output = VoiceAudio.playbackFormat

    init() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(me, { client, streamID, property, _ in
            let d = Unmanaged<MP3StreamDecoder>.fromOpaque(client).takeUnretainedValue()
            d.property(streamID, property)
        }, { client, bytes, packets, data, descriptions in
            let d = Unmanaged<MP3StreamDecoder>.fromOpaque(client).takeUnretainedValue()
            d.packets(bytes: bytes, count: packets, data: data, descriptions: descriptions)
        }, kAudioFileMP3Type, &stream)
    }

    deinit { if let stream { AudioFileStreamClose(stream) } }

    /// Parses `data` and returns any PCM ready to play.
    func feed(_ data: Data) -> [AVAudioPCMBuffer] {
        guard let stream, !data.isEmpty else { return [] }
        data.withUnsafeBytes { raw in
            _ = AudioFileStreamParseBytes(stream, UInt32(raw.count), raw.baseAddress, [])
        }
        defer { ready = [] }
        return ready
    }

    /// Flushes the decoder's tail.
    func finish() -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        var out: [AVAudioPCMBuffer] = []
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: buf, error: &error) { _, s in
                s.pointee = .endOfStream
                return nil
            }
            if buf.frameLength > 0 { out.append(buf) }
            if status != .haveData { break }
        }
        return out
    }

    private func property(_ streamID: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return }
        if asbd.mFramesPerPacket > 0 { framesPerPacket = asbd.mFramesPerPacket }
        inputFormat = fmt
        converter = AVAudioConverter(from: fmt, to: output)
    }

    private func packets(bytes: UInt32, count: UInt32, data: UnsafeRawPointer,
                         descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let converter, let inputFormat, count > 0, bytes > 0 else { return }
        var maxPacket = 0
        if let descriptions {
            for i in 0..<Int(count) { maxPacket = max(maxPacket, Int(descriptions[i].mDataByteSize)) }
        }
        if maxPacket == 0 { maxPacket = Int(bytes) / Int(count) + 1 }
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(count),
                                                 maximumPacketSize: maxPacket)
        guard Int(bytes) <= Int(count) * maxPacket else { return }
        compressed.data.copyMemory(from: data, byteCount: Int(bytes))
        compressed.byteLength = bytes
        compressed.packetCount = AVAudioPacketCount(count)
        if let descriptions, let dst = compressed.packetDescriptions {
            for i in 0..<Int(count) { dst[i] = descriptions[i] }
        }
        // Output room: frames per packet × packets, scaled for the sample-rate change, plus slack.
        let ratio = output.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(framesPerPacket * count) * ratio) + 2048
        var given = false
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: buf, error: &error) { _, s in
                if given { s.pointee = .noDataNow; return nil }
                given = true
                s.pointee = .haveData
                return compressed
            }
            if buf.frameLength > 0 { ready.append(buf) }
            if status != .haveData { break }
        }
    }
}

// MARK: - Any PCM → playback format (for the on-device voice fallback)

final class PCMReformatter {
    private var converter: AVAudioConverter?
    private var from: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let out = VoiceAudio.playbackFormat
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == out { return buffer }
        if from != buffer.format {
            from = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: out)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * out.sampleRate / buffer.format.sampleRate) + 1024
        guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        _ = converter.convert(to: dst, error: &error) { _, s in
            if given { s.pointee = .noDataNow; return nil }
            given = true
            s.pointee = .haveData
            return buffer
        }
        return dst.frameLength > 0 ? dst : nil
    }
}
