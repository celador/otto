import SwiftUI

@main
struct OttoMacApp: App {
    @State private var model: AppModel

    init() {
        let m = AppModel.macLaunchModel()
        _model = State(initialValue: m)
        // Keep Mac awake polls the relay for agent activity even with no window open. Its controls live
        // in Otto's window (sidebar footer), View → Keep Mac Awake and Settings; no menu bar item.
        KeepAwakeController.shared.start { [weak m] in m?.companionClient }
        HotspotController.shared.start { [weak m] in m?.companionClient }
        // Headphone button: registered once, before any audio input starts, for the app's lifetime
        // (AirPods press in voice mode = send / interrupt; idle double press = start voice).
        HeadphoneHub.shared.onIdleStart = { HeadphoneVoiceStart.start() }
        HeadphoneHub.shared.install()
    }

    var body: some Scene {
        WindowGroup("Otto", id: "main") {
            MacRootView()
                .environment(model)
                .tint(Theme.accent)
                .frame(minWidth: 720, minHeight: 480)
                .containerBackground(Color(.systemBackground), for: .window)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands { OttoCommands() }

        Settings {
            MacSettingsView()
                .environment(model)
                .tint(Theme.accent)
        }
    }
}
