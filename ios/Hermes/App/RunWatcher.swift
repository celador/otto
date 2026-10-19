import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Tells you when the agent finishes while the app is in the background.
///
/// Without an APNs relay the phone has to notice on its own:
/// 1. On backgrounding, a background task keeps the run stream alive ~30s
///    (most short turns finish inside that window).
/// 2. A `BGAppRefreshTask` polls pending runs when iOS grants time.
/// 3. On foreground, pending runs are checked immediately.
/// Each finished run posts one local notification that deep-links to its chat.
@MainActor
final class RunWatcher {
    static let shared = RunWatcher()
    nonisolated static let refreshTaskID = "ai.elier.hermes.refresh"

    private struct Pending: Codable, Hashable {
        var runID: String
        var sessionID: String
        var title: String
        var started: Date? = Date()
    }

    /// A run we can't get a status for after this long is treated as over (expired on the gateway).
    static let maxRunAge: TimeInterval = 3 * 3600

    private let storeKey = "pendingRuns"
    var client: HermesClient?
    /// The chat currently on screen; its runs don't need a banner.
    var visibleSessionID: String?

    private var pending: [Pending] {
        get {
            UserDefaults.standard.data(forKey: storeKey)
                .flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storeKey)
        }
    }

    // MARK: Registration

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            nonisolated(unsafe) let refresh = task
            MainActor.assumeIsolated {
                let work = Task { @MainActor in
                    await RunWatcher.shared.checkPending()
                    RunWatcher.shared.scheduleRefresh()
                    refresh.setTaskCompleted(success: true)
                }
                refresh.expirationHandler = { work.cancel() }
            }
        }
    }

    func scheduleRefresh() {
        guard !pending.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Tracking

    func track(runID: String, sessionID: String, title: String) {
        var list = pending.filter { $0.runID != runID }
        list.append(Pending(runID: runID, sessionID: sessionID, title: title))
        pending = Array(list.suffix(20))
    }

    /// The chat screen saw the run finish while visible.
    func finishedInForeground(runID: String) {
        pending = pending.filter { $0.runID != runID }
    }

    /// Called on background: poll for up to ~25s while iOS lets us run.
    func didEnterBackground() {
        guard !pending.isEmpty else { return }
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "hermes.run") {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task {
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, !pending.isEmpty {
                await checkPending()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            scheduleRefresh()
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }
    }

    /// Checks every pending run once; notifies for the ones that ended, and ends their Live Activity.
    func checkPending() async {
        guard let client else { return }
        var reachedGateway = false
        for item in pending {
            guard let status = try? await client.runStatus(id: item.runID) else {
                // Unreachable (Tailscale off?) → try later; but a run that old is gone, not running.
                if let s = item.started, Date().timeIntervalSince(s) > Self.maxRunAge {
                    pending = pending.filter { $0.runID != item.runID }
                    LiveActivityController.shared.end(sessionID: item.sessionID, status: "interrupted")
                }
                continue
            }
            reachedGateway = true
            guard status.isTerminal else { continue }
            pending = pending.filter { $0.runID != item.runID }
            RunBookmark.clear(sessionID: item.sessionID)
            LiveActivityController.shared.end(sessionID: item.sessionID, status: status.status)
            let appActive = UIApplication.shared.applicationState == .active
            if appActive && visibleSessionID == item.sessionID { continue }
            await notify(item, status: status)
        }
        if pending.isEmpty { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        // Only prune when we know the truth (gateway answered, or nothing is pending at all).
        if reachedGateway || pending.isEmpty {
            LiveActivityController.shared.reconcile(runningSessions: Set(pending.map(\.sessionID)))
        }
    }

    private func notify(_ item: Pending, status: RunStatus) async {
        let content = UNMutableNotificationContent()
        content.title = item.title
        switch status.status {
        case "completed":
            let text = (status.output ?? "").trimmed
            content.body = text.isEmpty ? "Done." : String(text.prefix(240))
        case "cancelled": content.body = "Stopped."
        default: content.body = "The run \(status.status)."
        }
        content.sound = .default
        content.threadIdentifier = item.sessionID
        content.userInfo = ["sessionID": item.sessionID]
        let request = UNNotificationRequest(identifier: item.runID, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Routes notification taps to the right chat and shows banners in-app for other chats.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    static let openSession = Notification.Name("hermes.openSession")

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let sessionID = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: Self.openSession, object: nil, userInfo: ["sessionID": sessionID])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
