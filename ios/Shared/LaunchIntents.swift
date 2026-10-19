import AppIntents
import Foundation

/// What the app should do when it's opened from Siri, Shortcuts, a widget or
/// a Control Center button. Compiled into the app and the widget extension.
enum LaunchAction: Hashable, Sendable {
    case newChat
    case dictate
    case voice
    case camera
    case ask(String)

    /// `hermes://new`, `hermes://new?dictate=1`, `hermes://new?camera=1`,
    /// `hermes://new?prompt=…`
    init?(url: URL) {
        guard url.scheme == "hermes", url.host == "new" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func has(_ name: String) -> Bool { items.contains { $0.name == name && $0.value != "0" } }
        if let prompt = items.first(where: { $0.name == "prompt" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            self = .ask(prompt)
        } else if has("voice") {
            self = .voice
        } else if has("dictate") {
            self = .dictate
        } else if has("camera") {
            self = .camera
        } else {
            self = .newChat
        }
    }

    var url: URL {
        switch self {
        case .newChat: URL(string: "hermes://new")!
        case .dictate: URL(string: "hermes://new?dictate=1")!
        case .voice: URL(string: "hermes://new?voice=1")!
        case .camera: URL(string: "hermes://new?camera=1")!
        case .ask(let prompt): Self.askURL(prompt)
        }
    }

    private static func askURL(_ prompt: String) -> URL {
        var c = URLComponents(string: "hermes://new")!
        c.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        return c.url!
    }
}

/// Hands a launch action from an intent to the UI. An intent can run before
/// the chat list exists (cold launch), so the action waits in `pending`.
@MainActor
enum LaunchRequest {
    static let notification = Notification.Name("ai.elier.hermes.launchRequest")
    private(set) static var pending: LaunchAction?

    static func post(_ action: LaunchAction) {
        pending = action
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func take() -> LaunchAction? {
        defer { pending = nil }
        return pending
    }
}

struct NewHermesChatIntent: AppIntent {
    static var title: LocalizedStringResource { "New Otto Chat" }
    static var description: IntentDescription { IntentDescription("Opens a new chat with your agent.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequest.post(.newChat)
        return .result()
    }
}

#if os(iOS)
/// Same as "Talk to Otto" (kept so Action-button, Control Center and Shortcuts set-ups made with it
/// keep working): the live voice conversation starts in the background, phone locked or not.
struct VoiceChatWithHermesIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Voice Chat with Otto" }
    static var description: IntentDescription {
        IntentDescription("Starts a hands-free spoken conversation with your agent, even with your phone locked.")
    }
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { HandsFreeLaunch.modes }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await HandsFreeLaunch.perform(self)
        return .result()
    }
}
#else
struct VoiceChatWithHermesIntent: AppIntent {
    static var title: LocalizedStringResource { "Voice Chat with Otto" }
    static var description: IntentDescription {
        IntentDescription("Starts a hands-free spoken conversation with your agent.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequest.post(.voice)
        return .result()
    }
}
#endif

struct DictateToHermesIntent: AppIntent {
    static var title: LocalizedStringResource { "Dictate to Otto" }
    static var description: IntentDescription {
        IntentDescription("Opens a new Otto chat with the microphone already listening.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequest.post(.dictate)
        return .result()
    }
}

struct PhotoToHermesIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Otto a Photo" }
    static var description: IntentDescription {
        IntentDescription("Opens a new Otto chat with the camera ready.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequest.post(.camera)
        return .result()
    }
}

struct AskHermesIntent: AppIntent {
    static var title: LocalizedStringResource { "Ask Otto" }
    static var description: IntentDescription {
        IntentDescription("Starts a new Otto chat and sends your request to your agent.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Request", inputOptions: String.IntentInputOptions(multiline: true))
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Otto \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRequest.post(.ask(prompt))
        return .result()
    }
}
