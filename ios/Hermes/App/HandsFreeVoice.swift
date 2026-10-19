import ActivityKit
import AVFoundation
import Foundation
import UIKit

/// Otto's live voice mode with no screen: started by "Hey Siri, talk to Otto", the Action button or
/// the Control Center control while the phone is locked in a pocket. Drives the same `VoiceSession`
/// the voice screen uses (Gemini Live or the classic pipeline), in a new chat, and ends it on
/// "bye"/"stop", a long silence, or Stop on the Live Activity.
@MainActor
final class HandsFreeVoice {
    static let shared = HandsFreeVoice()

    private(set) var session: VoiceSession?
    private var chat: ChatModel?
    private var watchdog: Task<Void, Never>?

    var isRunning: Bool { session != nil }

    /// Called at app launch (including the background launch Siri does for the intent).
    static func install() {
        HandsFreeHooks.start = { await HandsFreeVoice.shared.start() }
        HandsFreeHooks.stop = { HandsFreeVoice.shared.stopFromLiveActivity() }
    }

    func start() async -> HandsFreeHooks.Outcome {
        if session != nil { return .alreadyRunning }
        // The app is open and in front: use the voice screen, as before.
        if UIApplication.shared.applicationState == .active, !LiveActivityController.shared.voiceActive,
           !UserDefaults.standard.bool(forKey: "hermes.handsFreeHeadless") {
            LaunchRequest.post(.voice)
            return .started
        }
        if LiveActivityController.shared.voiceActive { return .alreadyRunning }   // the voice screen is open
        guard let (client, companion) = Self.connection() else { return .notConnected }
        let active = UIApplication.shared.applicationState == .active
        VoiceDiag.log("handsfree: begin (app state \(UIApplication.shared.applicationState.rawValue), build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))")
        // The Live Activity first, and confirmed: iOS lets a background app record only while the recording
        // intent's activity shows. Without it the mic start fails ('what' / '!int' / '!pla').
        let activityUp = await LiveActivityController.shared.startHandsFreeVoice(title: "Otto")
        VoiceDiag.log("handsfree: live activities=\(Activity<HermesRunAttributes>.activities.count) up=\(activityUp)")
        if HandsFreePlan.afterActivity(appActive: active, activityUp: activityUp) == .foreground {
            VoiceDiag.log("handsfree: no Live Activity in the background; continuing in the app")
            LiveActivityController.shared.voiceEnded()
            return .needsForeground
        }
        let chat = ChatModel(client: client, sessionID: nil)
        let s = VoiceSession(chat: chat, companion: companion, title: "Otto")
        session = s
        self.chat = chat
        VoiceDiag.log("handsfree: start (app state \(UIApplication.shared.applicationState.rawValue))")
        await s.start()
        if case .error(let message) = s.phase {
            VoiceDiag.log("handsfree: start failed: \(message)")
            stop(.error)
            let outcome = HandsFreePlan.afterFailure(message, appActive: UIApplication.shared.applicationState == .active)
            if outcome == .needsForeground { VoiceDiag.log("handsfree: continuing in the app instead") }
            return outcome
        }
        watch(s)
        return .started
    }

    /// Stop on the Lock Screen / Dynamic Island.
    func stopFromLiveActivity() {
        if session != nil { stop(.stopButton); return }
        // The voice screen is what's running: close it.
        NotificationCenter.default.post(name: HandsFreeHooks.stopNotification, object: nil)
        LiveActivityController.shared.voiceEnded()
    }

    func stop(_ reason: HandsFreeEnd.Reason) {
        guard let s = session else { return }
        VoiceDiag.log("handsfree: end (\(reason))")
        watchdog?.cancel()
        watchdog = nil
        session = nil
        chat = nil
        s.end()
    }

    private func watch(_ s: VoiceSession) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var state = HandsFreeEnd.State(now: Date())
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.session === s else { return }
                if let reason = HandsFreeEnd.step(&state, phase: HandsFreeEnd.phase(s.phase), heard: s.heard, now: Date()) {
                    self.stop(reason)
                    return
                }
            }
        }
    }

    /// The saved connection (the Keychain item is readable while the phone is locked).
    private static func connection() -> (HermesClient, CompanionClient?)? {
        let app = AppModel.launchModel()
        guard let client = app.client else { return nil }
        return (client, app.companionClient)
    }
}

/// How a hands-free start goes on. Pure, so it's testable.
enum HandsFreePlan {
    enum Step: Equatable { case background, foreground }

    /// After requesting the Live Activity. In the background the mic can't start without it, so go
    /// straight to the app (voice screen, live voice on, no extra tap) instead of failing. In front
    /// (the headless test path) the activity is only cosmetic.
    static func afterActivity(appActive: Bool, activityUp: Bool) -> Step {
        appActive || activityUp ? .background : .foreground
    }

    /// The screenless session failed to start: from the background the app can still take over;
    /// in front, report it.
    static func afterFailure(_ message: String, appActive: Bool) -> HandsFreeHooks.Outcome {
        appActive ? .failed(message) : .needsForeground
    }
}

/// When a screenless conversation is over. Pure, so it's testable.
enum HandsFreeEnd {
    /// Listening this long with nothing said ends it.
    static let silenceTimeout: TimeInterval = 30
    /// After a goodbye, wait at most this long for Otto's own goodbye to finish.
    static let goodbyeGrace: TimeInterval = 8
    /// A goodbye has to stay the last thing said this long (so "bye…" mid-sentence doesn't count).
    static let goodbyeSettle: TimeInterval = 1.5
    /// Stuck in an error this long ends it (Gemini retries on its own first).
    static let errorTimeout: TimeInterval = 12

    enum Reason: Equatable { case goodbye, silence, error, stopButton }

    enum Phase: Equatable { case listening, thinking, speaking, paused, error, idle }

    static func phase(_ p: VoiceSession.Phase) -> Phase {
        switch p {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .paused: .paused
        case .error: .error
        }
    }

    struct State {
        var lastHeard = ""
        var quietSince: Date
        var goodbyeAt: Date?
        /// Otto answered (thought or spoke) after the goodbye.
        var repliedToGoodbye = false
        var errorSince: Date?
        init(now: Date) { quietSince = now }
    }

    static func step(_ st: inout State, phase: Phase, heard: String, now: Date) -> Reason? {
        let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if said != st.lastHeard {
            st.lastHeard = said
            st.quietSince = now
            if !said.isEmpty {
                // Each new word restarts the check: only the final words count as a goodbye.
                st.goodbyeAt = WatchTalkLoop.isGoodbye(said) ? now : nil
                st.repliedToGoodbye = false
            }
        }
        if phase != .listening { st.quietSince = now }

        if let at = st.goodbyeAt {
            let settled = now.timeIntervalSince(at) >= goodbyeSettle
            if phase == .thinking || phase == .speaking { st.repliedToGoodbye = true }
            // Otto said its goodbye (the exchange cleared, or it's back to listening), or it's taking too long.
            if settled && (said.isEmpty || (st.repliedToGoodbye && phase == .listening)) { return .goodbye }
            if now.timeIntervalSince(at) >= goodbyeGrace { return .goodbye }
        }

        if phase == .error {
            if st.errorSince == nil { st.errorSince = now }
            if let e = st.errorSince, now.timeIntervalSince(e) >= errorTimeout { return .error }
        } else {
            st.errorSince = nil
        }

        if phase == .listening, now.timeIntervalSince(st.quietSince) >= silenceTimeout { return .silence }
        return nil
    }
}
