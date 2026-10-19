import UserNotifications
import SwiftUI

@main
struct HermesApp: App {
    @State private var model = AppModel.launchModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if let q = UserDefaults.standard.string(forKey: "hermes.siriTest"), !q.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(3))
                var intent = AskHermesForAnswerIntent()
                intent.question = q
                let started = Date()
                let r = try? await intent.perform()
                NSLog("SIRITEST done in %.1fs: %@", Date().timeIntervalSince(started), r.map { String(describing: $0) } ?? "nil")
            }
        }
        // `-hermes.handsFreeTest 1`: run the "Talk to Otto" intent a few seconds after launch (as Siri would),
        // with `-hermes.handsFreeHeadless 1` to force the screenless path while the app is in front.
        if UserDefaults.standard.bool(forKey: "hermes.handsFreeTest") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                do { _ = try await TalkToOttoIntent().perform(); NSLog("HANDSFREETEST started") }
                catch { NSLog("HANDSFREETEST failed: %@", String(describing: error)) }
            }
        }
        #endif
        RunWatcher.registerBackgroundTask()
        HandsFreeVoice.install()
        // Headphone button: registered once for the app's lifetime (idle double press = start voice).
        HeadphoneHub.shared.onIdleStart = { HeadphoneVoiceStart.start() }
        HeadphoneHub.shared.install()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        WatchBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "hermes.widgetPreview") {
                WidgetPreviewView().environment(model).onAppear { model.syncSharedVault() }
            } else {
                rootView
            }
            #else
            rootView
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: RunWatcher.shared.didEnterBackground()
            case .active: Task { await RunWatcher.shared.checkPending() }
            default: break
            }
        }
    }

    private var rootView: some View {
        RootView()
            .environment(model)
            .tint(Theme.accent)
            .onAppear {
                RunWatcher.shared.client = model.client
                model.shareWithWatch()
            }
            .onChange(of: model.isConnected) {
                RunWatcher.shared.client = model.client
                model.shareWithWatch()
            }
    }
}

extension AppModel {
    /// Lets the watch app talk to Hermes (through the phone, or direct).
    func shareWithWatch() {
        WatchBridge.shared.update(gateway: client?.config.baseURL, relay: kanbanClient?.baseURL,
                                  apiKey: client?.config.apiKey)
    }

    /// Debug-only launch args let the simulator skip setup for screenshots:
    /// `-hermes.url https://… -hermes.key …`. Release builds always use the Keychain.
    static func launchModel() -> AppModel {
        #if DEBUG
        let d = UserDefaults.standard
        if let url = d.string(forKey: "hermes.url").flatMap(AppModel.normalizedURL),
           let key = d.string(forKey: "hermes.key") {
            return AppModel(config: HermesConfig(baseURL: url, apiKey: key))
        }
        #endif
        return AppModel()
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isConnected {
            AppShell()
        } else {
            ConnectView()
        }
    }
}
