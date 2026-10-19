import AppIntents

/// Siri phrases and Shortcuts-app actions. Available without any setup.
struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        #if os(iOS)
        // "Hey Siri, talk to Otto": live voice, hands-free, works with the phone locked (AirPods).
        AppShortcut(
            intent: TalkToOttoIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start \(.applicationName) voice",
                "Hey \(.applicationName)",
                "Let's talk to \(.applicationName)",
            ],
            shortTitle: "Talk to Otto",
            systemImageName: "waveform.circle"
        )
        #endif
        AppShortcut(
            intent: AskHermesForAnswerIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) something",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Get an Answer",
            systemImageName: "waveform.and.mic"
        )
        AppShortcut(
            intent: AskHermesIntent(),
            phrases: [
                "Send a request to \(.applicationName)",
                "Open a \(.applicationName) chat about something",
            ],
            shortTitle: "Ask Otto",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: VoiceChatWithHermesIntent(),
            phrases: [
                "Voice chat with \(.applicationName)",
                "Start a voice chat with \(.applicationName)",
                "Have a conversation with \(.applicationName)",
            ],
            shortTitle: "Voice Chat",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: DictateToHermesIntent(),
            phrases: [
                "Dictate to \(.applicationName)",
            ],
            shortTitle: "Dictate",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: PhotoToHermesIntent(),
            phrases: ["Show \(.applicationName) a photo"],
            shortTitle: "Photo to Otto",
            systemImageName: "camera"
        )
        AppShortcut(
            intent: NewHermesChatIntent(),
            phrases: ["New \(.applicationName) chat", "Start a \(.applicationName) chat"],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
    }
}
