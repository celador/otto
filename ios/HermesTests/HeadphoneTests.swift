import Foundation
import Testing
@testable import Hermes

/// Headphone button in voice mode: press → send / interrupt per phase, duplicate events from one
/// press count once, a double press (or nextTrack) ends, and the cues are short and quiet.
@MainActor
struct HeadphoneTests {
    typealias G = HeadphoneGestures

    // MARK: press → action per phase

    @Test func pressActionPerPhase() {
        #expect(G.action(for: .press, phase: .listening, turnOpen: true) == .send)
        #expect(G.action(for: .press, phase: .listening, turnOpen: false) == .nothingToSend)
        #expect(G.action(for: .press, phase: .speaking, turnOpen: false) == .interrupt)
        #expect(G.action(for: .press, phase: .speaking, turnOpen: true) == .interrupt)
        #expect(G.action(for: .press, phase: .thinking, turnOpen: false) == .ignore)
        #expect(G.action(for: .press, phase: .thinking, turnOpen: true) == .ignore)
        #expect(G.action(for: .press, phase: .idle, turnOpen: false) == .ignore)
        #expect(G.action(for: .press, phase: .paused, turnOpen: false) == .resume)
        #expect(G.action(for: .press, phase: .error("x"), turnOpen: false) == .retry)
    }

    @Test func endGestureEndsInEveryPhase() {
        for phase: VoiceSession.Phase in [.listening, .speaking, .thinking, .paused, .error("x")] {
            #expect(G.action(for: .end, phase: phase, turnOpen: true) == .end)
        }
    }

    // MARK: debounce / gestures

    @Test func remoteCommandPressAndRepeats() {
        var g = G()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.remoteCommand, at: t) == .press)
        // pause+play pair from one click
        #expect(g.register(.remoteCommand, at: t.addingTimeInterval(0.1)) == nil)
        #expect(g.register(.remoteCommand, at: t.addingTimeInterval(1.0)) == .press)
    }

    @Test func muteToggleAndRemoteCommandFromOnePressCountOnce() {
        var g = G()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.muteToggle, at: t) == .press)
        #expect(g.register(.remoteCommand, at: t.addingTimeInterval(0.15)) == nil)
        var h = G()
        #expect(h.register(.remoteCommand, at: t) == .press)
        #expect(h.register(.muteToggle, at: t.addingTimeInterval(0.2)) == nil)
        // a later press counts again
        #expect(h.register(.remoteCommand, at: t.addingTimeInterval(1.5)) == .press)
    }

    @Test func twoMuteTogglesCloseTogetherAreADoublePressThatEnds() {
        var g = G()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.muteToggle, at: t) == .press)
        #expect(g.register(.muteToggle, at: t.addingTimeInterval(0.35)) == .end)
        // the double press doesn't leave a pending toggle behind
        #expect(g.register(.muteToggle, at: t.addingTimeInterval(1.5)) == .press)
    }

    @Test func slowMuteTogglesAreSeparatePresses() {
        var g = G()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.muteToggle, at: t) == .press)
        #expect(g.register(.muteToggle, at: t.addingTimeInterval(0.9)) == .press)
        #expect(g.register(.muteToggle, at: t.addingTimeInterval(1.8)) == .press)
    }

    @Test func bouncingMuteToggleIsOneEvent() {
        var g = G()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.muteToggle, at: t) == .press)
        #expect(g.register(.muteToggle, at: t.addingTimeInterval(0.02)) == nil)
    }

    @Test func nextTrackEndsOnceEvenWithTrailingEvents() {
        var g = G()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.remoteCommand, end: true, at: t) == .end)
        #expect(g.register(.remoteCommand, end: true, at: t.addingTimeInterval(0.1)) == nil)
        #expect(g.register(.muteToggle, at: t.addingTimeInterval(0.2)) == nil)
    }

    // MARK: control object (no system events: fed through the test seam)

    @Test func controlForwardsGesturesOnlyWhileActive() {
        let c = HeadphoneControl()
        var got: [(G.Gesture, HeadphoneSource)] = []
        c.onGesture = { g, s, _ in got.append((g, s)) }
        let t = Date(timeIntervalSince1970: 1000)
        c.received(.remoteCommand, event: "togglePlayPause", end: false, at: t)
        #expect(got.isEmpty)
        c.activate(title: "Test")
        c.received(.remoteCommand, event: "togglePlayPause", end: false, at: t)
        c.received(.muteToggle, event: "inputMute(true)", end: false, at: t.addingTimeInterval(0.1))
        c.received(.remoteCommand, event: "nextTrack", end: true, at: t.addingTimeInterval(2))
        c.deactivate()
        c.received(.remoteCommand, event: "togglePlayPause", end: false, at: t.addingTimeInterval(5))
        #expect(got.map(\.0) == [.press, .end])
        #expect(got.map(\.1) == [.remoteCommand, .remoteCommand])
    }

    // MARK: idle: double press starts voice

    @Test func idleSinglePressDoesNothingDoublePressStarts() {
        var g = IdleHeadphoneGestures()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.toggle, at: t) == false)
        #expect(g.register(.toggle, at: t.addingTimeInterval(0.3)) == true)
        // the screen is coming up: more presses don't start a second session
        #expect(g.register(.toggle, at: t.addingTimeInterval(0.6)) == false)
        #expect(g.register(.toggle, at: t.addingTimeInterval(0.8)) == false)
    }

    @Test func idleSlowPressesNeverStart() {
        var g = IdleHeadphoneGestures()
        let t = Date(timeIntervalSince1970: 1000)
        for i in 0..<5 { #expect(g.register(.toggle, at: t.addingTimeInterval(Double(i) * 0.6)) == false) }
    }

    @Test func idleBouncePairIsOnePress() {
        var g = IdleHeadphoneGestures()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.toggle, at: t) == false)
        #expect(g.register(.toggle, at: t.addingTimeInterval(0.02)) == false)   // pause+play of one click
        #expect(g.register(.toggle, at: t.addingTimeInterval(0.3)) == true)
    }

    @Test func idleNextTrackStarts() {
        var g = IdleHeadphoneGestures()
        let t = Date(timeIntervalSince1970: 1000)
        #expect(g.register(.nextTrack, at: t) == true)
        #expect(g.register(.nextTrack, at: t.addingTimeInterval(0.5)) == false)
        #expect(g.register(.nextTrack, at: t.addingTimeInterval(2.0)) == true)
    }

    @Test func hubStartsVoiceOnIdleDoublePress() {
        let hub = HeadphoneHub()
        var starts = 0
        hub.onIdleStart = { starts += 1 }
        let t = Date(timeIntervalSince1970: 1000)
        hub.idleEvent(.toggle, name: "togglePlayPause", at: t)
        #expect(starts == 0)
        hub.idleEvent(.toggle, name: "togglePlayPause", at: t.addingTimeInterval(0.25))
        #expect(starts == 1)
    }

    // MARK: cues

    @Test func cuesAreShortAndQuiet() {
        for cue in VoiceCue.allCases {
            #expect(cue.duration > 0.04 && cue.duration < 0.3)
            let s = cue.samples(rate: 24_000)
            #expect(s.count == Int(cue.duration * 24_000) || abs(s.count - Int(cue.duration * 24_000)) <= cue.notes.count)
            #expect((s.map(abs).max() ?? 1) <= VoiceCue.amplitude + 0.001)
            #expect(abs(s.first ?? 1) < 0.01 && abs(s.last ?? 1) < 0.02)   // faded: no click
            let buf = cue.buffer()
            #expect(buf?.frameLength == AVAudioFrameCountish(s.count))
        }
    }

    @Test func endCueWavIsValid() {
        let d = VoiceCue.ended.wav()
        #expect(d.prefix(4) == Data("RIFF".utf8))
        #expect(d.subdata(in: 8..<12) == Data("WAVE".utf8))
        #expect(d.count == 44 + VoiceCue.ended.samples(rate: 24_000).count * 2)
    }
}

private func AVAudioFrameCountish(_ n: Int) -> UInt32 { UInt32(n) }
