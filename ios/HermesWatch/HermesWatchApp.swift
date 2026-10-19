import SwiftUI
import WatchKit

/// Brings the WatchConnectivity session up on every launch, including the background launches
/// watchOS does to deliver a complication update from the iPhone.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        MainActor.assumeIsolated { _ = WatchModel.shared }
        WatchModel.scheduleBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        Task { @MainActor in await WatchModel.shared.refreshLimitsIfStale() }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    await WatchModel.shared.refreshLimitsIfStale()
                    WatchModel.scheduleBackgroundRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

@main
struct HermesWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var model = WatchModel.shared
    // Pages: 0 conversation · 1 recent chats · 2 jobs · 3 limits.
    @State private var page = UserDefaults.standard.integer(forKey: "watch.page")

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TabView(selection: $page) {
                    WatchHome(model: model).tag(0)
                    WatchChatsView(model: model) { withAnimation { page = 0 } }.tag(1)
                    WatchJobsView(model: model).tag(2)
                    WatchLimitsView(model: model).tag(3)
                    #if DEBUG
                    if page == 9 { WatchFacePreview().tag(9) }
                    #endif
                }
                .tabViewStyle(.verticalPage)
            }
            // Handoff: the chat on your wrist shows up on the iPhone (app switcher / Dock) to continue there.
            .userActivity("ai.elier.hermes.chat", isActive: model.hasConversation) { activity in
                activity.title = model.title ?? "Otto chat"
                activity.userInfo = ["session": model.currentSessionID ?? ""]
            }
            .onOpenURL { url in
                switch url.host {
                case "talk":
                    // The "Talk to Otto" complication: a hands-free conversation (or nothing new if one is on).
                    page = 0
                    if !model.handsFree, model.phase == .idle || model.phase.loop == .error {
                        Task { await model.startConversation() }
                    }
                case "limits": page = 3
                case "chat":
                    page = 0
                    if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "session" })?.value, !id.isEmpty,
                       id != model.currentSessionID {
                        let title = SharedVault.status().title ?? "Chat"
                        Task { await model.open(.init(id: id, title: title, lastActive: nil, source: nil)) }
                    }
                default: break
                }
            }
            #if DEBUG
            .task { await model.debugLaunch() }
            #endif
        }
    }
}
