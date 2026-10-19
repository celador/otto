import AppKit
import Foundation
import UserNotifications

// Mac stand-ins for iOS-only services the shared code calls into. Live Activities, the
// watch link, HealthKit and background refresh don't exist for the Mac app, so these are
// no-ops with the same API as the iOS versions (ios/Hermes/App/*.swift).

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    static var isEnabled: Bool { false }
    func start(sessionID: String, title: String) {}
    func update(status: String?, tools: Int, needsApproval: Bool) {}
    func end(status: String, tools: Int, answer: String? = nil) {}
    func end(sessionID: String, status: String) {}
    func reconcile(runningSessions: Set<String>) {}
    func voiceUpdate(sessionID: String?, title: String, phase: String, status: String) {}
    func voiceEnded() {}
    func endAllImmediately() {}
}

/// On iOS this finishes runs in the background and posts a notification. On the Mac the app
/// stays alive, so the chat's own stream does the work; only the bookkeeping API remains.
@MainActor
final class RunWatcher {
    static let shared = RunWatcher()
    var client: HermesClient?
    var visibleSessionID: String?
    func track(runID: String, sessionID: String, title: String) {}
    func finishedInForeground(runID: String) {}
    func checkPending() async {}
}

enum NotificationRouter {
    static let openSession = Notification.Name("hermes.openSession")
}

@MainActor
final class WatchBridge {
    static let shared = WatchBridge()
    func pushStatus(_ status: LiveStatus) {}
    func pushLimits(_ snapshot: LimitsSnapshot) {}
}

enum HealthContext {
    static let enabledKey = "health.enabled"
    static var enabled: Bool { false }
    static var available: Bool { false }
    static func requestAccess() async -> Bool { false }
    static func contextIfRelevant(_ text: String) async -> String? { nil }
}

/// Haptics are an iPhone thing; the Mac has none for these events.
@MainActor
enum Haptics {
    static func send() {}
    static func tap() {}
    static func success() {}
    static func error() {}
}
