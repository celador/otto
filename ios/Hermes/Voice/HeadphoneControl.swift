import AudioToolbox
#if os(macOS)
import CoreAudio
#endif
import AVFoundation
import Foundation
import MediaPlayer
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How a headphone press reached the app.
nonisolated enum HeadphoneSource: String, Sendable {
    /// Now Playing remote command (wired/USB headset play-pause, AirPods on a media-style session).
    case remoteCommand
    /// The system's input-mute toggle: an AirPods stem press while the mic is in a call-style
    /// (voice-processing) session arrives as "mute", not as play/pause.
    case muteToggle
}

/// Headphone press → gesture → what voice mode does. Pure, so it's testable.
nonisolated struct HeadphoneGestures: Sendable {
    enum Gesture: Equatable, Sendable {
        case press
        case end
    }

    enum Action: Equatable, Sendable {
        /// You were talking: send your turn now.
        case send
        /// Otto was talking: stop it and listen.
        case interrupt
        /// Paused (muted in Otto): listen again.
        case resume
        /// The session hit an error: try again.
        case retry
        /// Listening but nothing said yet: nothing to send (a short cue says the press arrived).
        case nothingToSend
        /// Otto is working, or voice isn't running: the press does nothing.
        case ignore
        /// End the voice session.
        case end
    }

    /// One press can arrive twice (mute toggle + remote command): a second event from the OTHER
    /// source within this window is the same press.
    static let duplicateWindow: TimeInterval = 0.3
    /// Two mute toggles this close together are a double press (= end). AirPods report each press
    /// of a double press as its own mute toggle; remote commands already arrive as nextTrack.
    static let doublePressWindow: TimeInterval = 0.7
    /// Mute toggles closer than this are one bouncing event, not two presses.
    static let bounceWindow: TimeInterval = 0.06

    private var lastEvent: (source: HeadphoneSource, at: Date)?
    private var lastMuteToggle: Date?
    private var lastEnd: Date?

    /// A raw event → the gesture it is, or nil when it's a duplicate of one already counted.
    /// `end` = the platform already recognised an end gesture (nextTrack = double press).
    mutating func register(_ source: HeadphoneSource, end: Bool = false, at now: Date) -> Gesture? {
        defer { lastEvent = (source, now) }
        if let lastEnd, now.timeIntervalSince(lastEnd) < Self.duplicateWindow { return nil }
        if end {
            lastEnd = now
            return .end
        }
        switch source {
        case .muteToggle:
            if let prev = lastMuteToggle {
                let gap = now.timeIntervalSince(prev)
                if gap < Self.bounceWindow { return nil }
                if gap < Self.doublePressWindow {
                    lastMuteToggle = nil
                    lastEnd = now
                    return .end
                }
            }
            if let last = lastEvent, last.source == .remoteCommand,
               now.timeIntervalSince(last.at) < Self.duplicateWindow {
                lastMuteToggle = now
                return nil
            }
            lastMuteToggle = now
            return .press
        case .remoteCommand:
            if let last = lastEvent, now.timeIntervalSince(last.at) < Self.duplicateWindow { return nil }
            return .press
        }
    }

    /// What a gesture does in each phase. `turnOpen` = you've said something not yet sent.
    static func action(for gesture: Gesture, phase: VoiceSession.Phase, turnOpen: Bool) -> Action {
        if gesture == .end { return .end }
        switch phase {
        case .speaking: return .interrupt
        case .listening: return turnOpen ? .send : .nothingToSend
        case .thinking, .idle: return .ignore
        case .paused: return .resume
        case .error: return .retry
        }
    }
}

/// Short, quiet sounds so you know a press landed without looking. Generated (no bundled files).
nonisolated enum VoiceCue: String, Sendable, CaseIterable {
    case listening, sent, interrupted, nothing, ended

    /// (frequency Hz, seconds) per note.
    var notes: [(Double, Double)] {
        switch self {
        case .listening: [(660, 0.07), (880, 0.09)]
        case .sent: [(988, 0.07)]
        case .interrupted: [(740, 0.05), (494, 0.08)]
        case .nothing: [(330, 0.09)]
        case .ended: [(880, 0.07), (660, 0.07), (440, 0.11)]
        }
    }

    static let amplitude: Float = 0.12

    var duration: TimeInterval { notes.reduce(0) { $0 + $1.1 } }

    /// Mono float samples at `rate`, each note with a short fade in/out (no clicks).
    func samples(rate: Double) -> [Float] {
        var out: [Float] = []
        for (freq, dur) in notes {
            let n = Int(dur * rate)
            let fade = max(1, Int(0.008 * rate))
            for i in 0..<n {
                let env = Float(min(1, Double(min(i, n - 1 - i)) / Double(fade)))
                out.append(Float(sin(2 * .pi * freq * Double(i) / rate)) * Self.amplitude * env)
            }
        }
        return out
    }

    /// In `VoiceAudio.playbackFormat`, for playing through the voice engine (so the echo canceller
    /// removes it from the mic).
    func buffer() -> AVAudioPCMBuffer? {
        let format = VoiceAudio.playbackFormat
        let s = samples(rate: format.sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)),
              let ch = buf.floatChannelData?[0] else { return nil }
        for (i, v) in s.enumerated() { ch[i] = v }
        buf.frameLength = AVAudioFrameCount(s.count)
        return buf
    }

    /// 16-bit mono WAV (for the end cue, which plays after the engine has stopped).
    func wav(rate: Double = 24_000) -> Data {
        let pcm = samples(rate: rate).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in pcm { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    /// Plays outside any audio engine (system sound). Only for the end cue.
    @MainActor static func playSystem(_ cue: VoiceCue) {
        if let id = systemSounds[cue] { AudioServicesPlaySystemSound(id); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("otto-cue-\(cue.rawValue).wav")
        do { try cue.wav().write(to: url) } catch { return }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return }
        systemSounds[cue] = id
        AudioServicesPlaySystemSound(id)
    }

    @MainActor private static var systemSounds: [VoiceCue: SystemSoundID] = [:]
}

/// With no voice session running: a double press of play/pause (two presses within
/// `doublePressWindow`), or nextTrack (AirPods report their own double press that way), starts voice.
/// A single press does nothing. Pure, so it's testable.
nonisolated struct IdleHeadphoneGestures: Sendable {
    enum Event: Equatable, Sendable { case toggle, nextTrack }

    static let doublePressWindow: TimeInterval = 0.4
    /// Closer than this is one bouncing press (some headsets send pause + play for one click).
    static let bounceWindow: TimeInterval = 0.06
    /// After a start, further presses are ignored for this long (the voice screen is coming up).
    static let afterStartQuiet: TimeInterval = 1.5

    private var lastToggle: Date?
    private var lastStart: Date?

    /// True = start voice now.
    mutating func register(_ event: Event, at now: Date) -> Bool {
        if let lastStart, now.timeIntervalSince(lastStart) < Self.afterStartQuiet { return false }
        switch event {
        case .nextTrack:
            lastToggle = nil
            lastStart = now
            return true
        case .toggle:
            if let prev = lastToggle {
                let gap = now.timeIntervalSince(prev)
                if gap < Self.bounceWindow { return false }
                if gap < Self.doublePressWindow {
                    lastToggle = nil
                    lastStart = now
                    return true
                }
            }
            lastToggle = now
            return false
        }
    }
}

/// Thread-safe state the system mute handler reads (it's called off the main thread).
nonisolated final class HeadphoneGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var resetting = false

    var isActive: Bool { lock.withLock { active } }
    var isResetting: Bool { lock.withLock { resetting } }
    func setActive(_ on: Bool) { lock.withLock { active = on } }
    func setResetting(_ on: Bool) { lock.withLock { resetting = on } }
}

/// App-lifetime owner of the headphone button: the Now Playing remote commands and the system
/// input-mute gesture are registered once at launch (never toggled per session), so presses reach
/// Otto both during voice mode (send / interrupt / end, via the session's `HeadphoneControl`) and
/// while idle (double press = start voice).
///
/// macOS (AirPods): while Otto records, an AirPods stem / AirPods Max crown press is the system mute
/// gesture, not a media key. audioaccessoryd only hands it to an app that has opted in to stem-click
/// muting, which AVFAudio does when the app OBSERVES `inputMuteStateChangeNotification` after setting
/// the input-mute handler. Setting only the handler (build 80) left `stemClickMutingEnabled` false, so
/// macOS rejected every press with "Cannot Control Mic with AirPods Max" (audioaccessoryd:
/// "toggleInputMute returned with error 'what'"). Each handler call is a press; Otto never actually
/// mutes, so the mic stays live.
@MainActor
final class HeadphoneHub {
    static let shared = HeadphoneHub()

    /// Starts voice mode (set by the app). Called on an idle double press.
    var onIdleStart: (() -> Void)?

    let gate = HeadphoneGate()
    private(set) var installed = false
    private weak var session: HeadphoneControl?
    private var idle = IdleHeadphoneGestures()
    private var muteObserver: NSObjectProtocol?
    private let selfUnmute = SelfUnmuteFlag()

    /// Once, at app launch (before any audio input starts).
    func install() {
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        for (command, event) in [(center.togglePlayPauseCommand, "togglePlayPause"),
                                 (center.playCommand, "play"),
                                 (center.pauseCommand, "pause"),
                                 (center.nextTrackCommand, "nextTrack")] {
            command.isEnabled = true
            command.addTarget(handler: Self.remoteHandler { [weak self] in self?.remote(event) })
        }
#if os(macOS)
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler(Self.muteHandler(gate) { [weak self] muted in
                self?.mute(muted)
            })
        } catch {
            VoiceDiag.log("headphones: mute handler not set: \(error)")
        }
        // Observing the notification (after the handler) is what opts Otto in to the AirPods gesture.
        muteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: nil) { _ in }
#else
        muteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: nil,
            using: Self.muteNotification(selfUnmute) { [weak self] muted in self?.mute(muted) })
#endif
        holdNowPlaying(playing: false, title: nil)
        VoiceDiag.log("headphones: installed (remote commands + input-mute gesture\(Self.stemClickState))")
    }

    // MARK: session

    func attach(_ control: HeadphoneControl, title: String) {
        install()
        session = control
        gate.setActive(true)
        holdNowPlaying(playing: true, title: title)
#if os(iOS)
        unmuteIfMuted()
#endif
        VoiceDiag.log("headphones: on (session\(Self.stemClickState))")
    }

    func detach(_ control: HeadphoneControl) {
        guard session === control else { return }
        session = nil
        gate.setActive(false)
        unmuteIfMuted()
        holdNowPlaying(playing: false, title: nil)
        VoiceDiag.log("headphones: off (idle: double press starts voice)")
    }

    /// Otto stays the Now Playing app while idle (paused), so play/pause reaches it. Another app that
    /// plays takes Now Playing back, which is fine.
    private func holdNowPlaying(playing: Bool, title: String?) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: playing ? "Voice" : "Otto",
                                   MPMediaItemPropertyArtist: title ?? "Double-press to talk",
                                   MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
                                   MPNowPlayingInfoPropertyIsLiveStream: true]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
#endif
    }

    // MARK: events

    private func remote(_ event: String, at now: Date = Date()) {
        if let session, session.isActive {
            session.received(.remoteCommand, event: event, end: event == "nextTrack", at: now)
            return
        }
        idleEvent(event == "nextTrack" ? .nextTrack : .toggle, name: event, at: now)
    }

    private func mute(_ muted: Bool) {
        if let session, session.isActive {
            session.received(.muteToggle, event: "inputMute(\(muted))", end: false)
        } else {
            VoiceDiag.log("headphones: idle inputMute(\(muted)) ignored")
        }
    }

    /// An idle press (also the test seam).
    func idleEvent(_ event: IdleHeadphoneGestures.Event, name: String, at now: Date = Date()) {
        let start = idle.register(event, at: now)
        VoiceDiag.log("headphones: idle \(name) -> \(start ? "start voice" : "wait for a second press")")
        if start { onIdleStart?() }
    }

    /// Back to unmuted without counting it as a press (end of a session; iOS session start).
    private func unmuteIfMuted() {
        guard AVAudioApplication.shared.isInputMuted else { return }
        gate.setResetting(true)
        selfUnmute.set(true)
        do { try AVAudioApplication.shared.setInputMuted(false) } catch {
            VoiceDiag.log("headphones: unmute failed: \(error)")
        }
        gate.setResetting(false)
        selfUnmute.clear(after: 0.5)
    }

    /// iOS only: the system muted the session input for the gesture; undo it so the mic stays live.
    func keepMicLive() {
#if os(iOS)
        unmuteIfMuted()
#else
        Self.clearProcessInputMute()
#endif
    }

#if os(macOS)
    /// Otto never mutes for the gesture, but make sure Core Audio isn't muting this process's input.
    private static func clearProcessInputMute() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessInputMute,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) == noErr,
              value != 0 else { return }
        value = 0
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value)
        VoiceDiag.log("headphones: process input was muted; unmuted (\(status))")
    }
#endif

    /// For the log: whether the system will hand Otto the AirPods gesture (DEBUG builds only).
    private static var stemClickState: String {
#if DEBUG
        let app = AVAudioApplication.shared
        let sel = NSSelectorFromString("stemClickMutingEnabled")
        guard app.responds(to: sel) else { return "" }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let on = unsafeBitCast(app.method(for: sel), to: Getter.self)(app, sel)
        return ", stem click \(on ? "on" : "OFF")"
#else
        return ""
#endif
    }

    // Handlers are built in nonisolated code: the system calls them off the main thread, and a
    // main-actor closure would trap there (Swift 6).
    nonisolated private static func remoteHandler(_ fire: @escaping @MainActor () -> Void)
        -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in fire() }
            return .success
        }
    }

#if os(macOS)
    /// true = "Otto handled it" (no rejection banner). Outside a voice session Otto doesn't claim it.
    nonisolated private static func muteHandler(_ gate: HeadphoneGate, _ fire: @escaping @MainActor (Bool) -> Void)
        -> @Sendable (Bool) -> Bool {
        { shouldMute in
            if gate.isResetting { return true }   // our own reset to unmuted
            guard gate.isActive else { return false }
            Task { @MainActor in fire(shouldMute) }
            return true
        }
    }
#else
    nonisolated private static func muteNotification(_ flag: SelfUnmuteFlag, _ fire: @escaping @MainActor (Bool) -> Void)
        -> @Sendable (Notification) -> Void {
        { note in
            let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue ?? false
            if !muted, flag.isSet { return }   // our own unmute
            Task { @MainActor in fire(muted) }
        }
    }
#endif
}

/// The headphone button during one voice session: presses come from `HeadphoneHub` (registered for
/// the app's lifetime), are de-duplicated into gestures here and handed to the session.
@MainActor
final class HeadphoneControl {
    /// A press or end gesture, with its source and the raw event name (for the log).
    var onGesture: ((HeadphoneGestures.Gesture, HeadphoneSource, String) -> Void)?
    /// Called after a mute gesture so the voice engine's own input mute is cleared too.
    var onUnmute: (() -> Void)?

    private(set) var isActive = false
    private var gestures = HeadphoneGestures()
    private let hub: HeadphoneHub

    init(hub: HeadphoneHub = .shared) { self.hub = hub }

    func activate(title: String) {
        guard !isActive else { return }
        isActive = true
        gestures = HeadphoneGestures()
        hub.attach(self, title: title)
        onUnmute?()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        hub.detach(self)
        onUnmute?()
    }

    /// A raw headphone event (also the test seam).
    func received(_ source: HeadphoneSource, event: String, end: Bool, at now: Date = Date()) {
        guard isActive else { return }
        if source == .muteToggle {
            hub.keepMicLive()
            onUnmute?()
        }
        guard let gesture = gestures.register(source, end: end, at: now) else {
            VoiceDiag.log("headphones: \(event) source=\(source.rawValue) duplicate, ignored")
            return
        }
        onGesture?(gesture, source, event)
    }
}

/// "We're unmuting ourselves right now" (read from whatever thread the system calls back on).
nonisolated final class SelfUnmuteFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var generation = 0

    var isSet: Bool { lock.withLock { on } }

    func set(_ value: Bool) { lock.withLock { on = value; generation += 1 } }

    func clear(after seconds: TimeInterval) {
        let g = lock.withLock { generation }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            lock.withLock { if generation == g { on = false } }
        }
    }
}

/// Where an idle headphone double press opens voice mode: the chat on screen (the last one to
/// appear), else a new chat (iOS: the hands-free start, which also works with the phone locked).
@MainActor
enum HeadphoneVoiceStart {
    private static var chats: [(id: UUID, open: () -> Void)] = []

    static func claim(_ id: UUID, open: @escaping () -> Void) {
        chats.removeAll { $0.id == id }
        chats.append((id, open))
    }

    static func release(_ id: UUID) { chats.removeAll { $0.id == id } }

    static func start() {
#if os(macOS)
        NSApplication.shared.activate()
        if let chat = chats.last {
            VoiceDiag.log("headphones: start voice in the open chat")
            chat.open()
        } else {
            VoiceDiag.log("headphones: start voice in a new chat")
            Task {
                try? await Task.sleep(for: .milliseconds(300))   // the window becomes key first
                LaunchRequest.post(.voice)
            }
        }
#else
        if UIApplication.shared.applicationState == .active, let chat = chats.last {
            VoiceDiag.log("headphones: start voice in the open chat")
            chat.open()
        } else {
            VoiceDiag.log("headphones: start hands-free voice")
            Task {
                let outcome = await HandsFreeHooks.start?()
                VoiceDiag.log("headphones: hands-free start -> \(outcome.map { String(describing: $0) } ?? "no hook")")
            }
        }
#endif
    }
}
