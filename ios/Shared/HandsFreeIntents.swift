import AppIntents
import Foundation
#if os(iOS)
import ActivityKit
#endif

/// "Hey Siri, talk to Otto" (AirPods, phone locked in a pocket), the Action button and the Control
/// Center control: Otto's live voice mode starts in the background, without opening or unlocking the
/// phone. It runs as an audio-recording intent, which iOS allows on a locked phone as long as a Live
/// Activity shows that the mic is on (Lock Screen + Dynamic Island, with a Stop button).
///
/// Compiled into the app and the widget extension (the controls); it always runs in the app, which
/// fills in `HandsFreeHooks` at launch.
@MainActor
enum HandsFreeHooks {
    enum Outcome: Equatable, Sendable {
        case started, alreadyRunning, notConnected
        /// The background start isn't possible right now (no Live Activity / mic refused): open the app
        /// to the voice screen instead, which starts live voice by itself.
        case needsForeground
        case failed(String)
    }

    static var start: (@MainActor () async -> Outcome)?
    static var stop: (@MainActor () async -> Void)?
    /// Posted when Stop is tapped and the voice running is the app's own voice screen.
    static let stopNotification = Notification.Name("ai.elier.hermes.voiceStop")
}

#if os(iOS)

struct HandsFreeIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

/// Shared by the hands-free intents: start (or keep) the background voice session.
@MainActor
enum HandsFreeLaunch {
    enum Next: Equatable { case done, openApp }

    static func run() async throws -> Next {
        guard let start = HandsFreeHooks.start else {
            throw HandsFreeIntentError(message: "Open Otto once on this phone first.")
        }
        switch await start() {
        case .started, .alreadyRunning: return .done
        case .needsForeground: return .openApp
        case .notConnected: throw HandsFreeIntentError(message: "Open Otto and connect it to your agent server first.")
        case .failed(let m): throw HandsFreeIntentError(message: m)
        }
    }

    /// Runs the hands-free start for an intent; if the background start isn't possible, brings the app
    /// forward (no confirmation prompt) and opens the voice screen, which starts live voice on its own.
    static func perform<I: AppIntent>(_ intent: I) async throws {
        guard try await run() == .openApp else { return }
        if #available(iOS 26.0, *) {
            try await intent.continueInForeground(nil, alwaysConfirm: false)
            LaunchRequest.post(.voice)
        } else {
            throw HandsFreeIntentError(message: "Open Otto to talk.")
        }
    }

    /// Starts in the background; may move to the app when the background start isn't possible.
    @available(iOS 26.0, *)
    nonisolated static var modes: IntentModes { [.background, .foreground(.dynamic)] }
}

/// "Talk to Otto": a hands-free spoken conversation, phone locked or not.
struct TalkToOttoIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Talk to Otto" }
    static var description: IntentDescription {
        IntentDescription("Starts a hands-free spoken conversation with Otto, even with your phone locked. Say \"bye\" or tap Stop to end it.")
    }
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { HandsFreeLaunch.modes }
    /// No Face ID / passcode: the conversation runs with the phone locked in a pocket.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await HandsFreeLaunch.perform(self)
        return .result()
    }
}

/// Stop button on the voice Live Activity (Lock Screen and Dynamic Island).
struct StopOttoVoiceIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Otto Voice" }
    static var description: IntentDescription { IntentDescription("Ends the spoken conversation with Otto.") }
    static var isDiscoverable: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let stop = HandsFreeHooks.stop {
            await stop()
        } else {
            // Not running in the app (shouldn't happen): at least take the activity down.
            for a in Activity<HermesRunAttributes>.activities where a.content.state.voice != nil {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
        return .result()
    }
}
#endif
