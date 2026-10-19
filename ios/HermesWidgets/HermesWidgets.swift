import AppIntents
import SwiftUI
import WidgetKit

@main
struct HermesWidgetBundle: WidgetBundle {
    var body: some Widget {
        HermesNowWidget()
        HermesJobsWidget()
        HermesLimitsWidget()
        NewChatControl()
        TalkControl()
        VoiceControl()
        HermesRunLiveActivity()
    }
}

// MARK: - Control Center / Lock Screen controls / Action button

struct NewChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ai.elier.hermes.control.new") {
            ControlWidgetButton(action: NewHermesChatIntent()) {
                Label("New Otto Chat", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Otto Chat")
        .description("Open a new chat with your agent.")
    }
}

struct VoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ai.elier.hermes.control.voice") {
            ControlWidgetButton(action: VoiceChatWithHermesIntent()) {
                Label("Voice Chat", systemImage: "waveform")
            }
        }
        .displayName("Otto Voice Chat")
        .description("Start a hands-free conversation with Otto.")
    }
}

struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ai.elier.hermes.control.talk") {
            ControlWidgetButton(action: TalkToOttoIntent()) {
                Label("Talk to Otto", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to Otto")
        .description("Talk with Otto hands-free, even when your phone is locked.")
    }
}
