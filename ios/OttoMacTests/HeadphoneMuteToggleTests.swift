import AVFAudio
import Foundation
import Testing
@testable import Otto

/// The AirPods press on the Mac is the system input-mute gesture. audioaccessoryd only delivers it to
/// an app that opted in to stem-click muting (handler set, THEN the notification observed); without
/// that, macOS shows "Cannot Control Mic with AirPods" (build 80). `setInputMuted` drives the same
/// handler the gesture calls.
@Suite(.serialized) @MainActor
struct HeadphoneMuteToggleTests {
    private func stemClickMutingEnabled() -> Bool {
        let app = AVAudioApplication.shared
        let sel = NSSelectorFromString("stemClickMutingEnabled")
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(app.method(for: sel), to: Getter.self)(app, sel)
    }

    @Test func launchInstallOptsInToTheAirPodsGesture() {
        HeadphoneHub.shared.install()   // the app already did this at launch; idempotent
        #expect(HeadphoneHub.shared.installed)
        #expect(stemClickMutingEnabled())
    }

    @Test func eachGestureIsAPressAndOurStartupStateIsNot() async throws {
        HeadphoneHub.shared.install()
        let c = HeadphoneControl()
        var got: [(HeadphoneGestures.Gesture, HeadphoneSource)] = []
        c.onGesture = { g, s, _ in got.append((g, s)) }
        c.activate(title: "Test")
        try await Task.sleep(for: .milliseconds(200))
        #expect(got.isEmpty)   // starting a session is not a press (build 80 logged one)

        try AVAudioApplication.shared.setInputMuted(true)   // first press: the system asks to mute
        try await Task.sleep(for: .milliseconds(200))
        #expect(got.map(\.0) == [.press])
        #expect(got.first?.1 == .muteToggle)

        try await Task.sleep(for: .milliseconds(800))
        try AVAudioApplication.shared.setInputMuted(false)  // next press: the system asks to unmute
        try await Task.sleep(for: .milliseconds(200))
        #expect(got.map(\.0) == [.press, .press])

        try AVAudioApplication.shared.setInputMuted(true)   // quick second press = double press: end
        try await Task.sleep(for: .milliseconds(200))
        #expect(got.map(\.0) == [.press, .press, .end])

        c.deactivate()   // resets to unmuted without counting a press
        try await Task.sleep(for: .milliseconds(200))
        #expect(AVAudioApplication.shared.isInputMuted == false)
        #expect(got.count == 3)
    }

    @Test func idleGestureIsNotClaimed() async throws {
        HeadphoneHub.shared.install()
        var count = 0
        let c = HeadphoneControl()
        c.onGesture = { _, _, _ in count += 1 }
        // No session: the handler declines (macOS keeps its own behaviour), nothing fires.
        #expect(throws: (any Error).self) { try AVAudioApplication.shared.setInputMuted(true) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == 0)
        #expect(AVAudioApplication.shared.isInputMuted == false)
    }
}
