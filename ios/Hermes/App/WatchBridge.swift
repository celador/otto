import Foundation
import UIKit
import WatchConnectivity
import WidgetKit

/// The iPhone side of the watch app: relays voice turns to Hermes and shares
/// the connection so the watch can also go direct when it can reach the Mac.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private var lite: HermesLite?
    fileprivate var lastPushedStatus: LiveStatus?
    fileprivate var pendingStatus: LiveStatus?
    fileprivate var lastStatusPush = Date.distantPast
    fileprivate var lastLimitsPush = Date.distantPast
    fileprivate var lastWidgetState: LiveStatus.State?
    fileprivate var lastWidgetReload = Date.distantPast

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Call whenever the gateway connection changes.
    func update(gateway: URL?, relay: URL?, apiKey: String?) {
        if let gateway, let relay, let apiKey {
            lite = HermesLite(gateway: gateway, relay: relay, apiKey: apiKey, timeout: 25)
        } else {
            lite = nil
        }
        pushContext()
    }

    private func pushContext() {
        let s = WCSession.default
        guard WCSession.isSupported(), s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        var ctx: [String: Any] = [:]
        if let lite {
            ctx = [WatchWire.gatewayURL: lite.gateway.absoluteString,
                   WatchWire.relayURL: lite.relay.absoluteString,
                   WatchWire.apiKey: lite.apiKey]
        }
        try? s.updateApplicationContext(ctx)
    }

    fileprivate func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let lite else { return ["error": "Open Otto on your iPhone and connect it first."] }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "watch-turn")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        do {
            switch message[WatchWire.op] as? String {
            case WatchWire.ask:
                let turn = try await lite.ask(audio: message["audio"] as? Data, text: message["text"] as? String,
                                              sessionID: message["session"] as? String,
                                              endsOnGoodbye: message["loop"] as? Bool ?? false,
                                              context: { said in await HealthContext.contextIfRelevant(said) })
                return WatchWire.reply(turn)
            case WatchWire.status:
                let s = try await lite.status(runID: message["run"] as? String ?? "")
                var out: [String: Any] = ["status": s.status]
                if let o = s.output { out["output"] = o }
                if let e = s.lastEvent { out["event"] = e }
                return out
            case WatchWire.speak:
                return ["audio": try await lite.speak(message["text"] as? String ?? "")]
            case WatchWire.stop:
                await lite.stop(runID: message["run"] as? String ?? "")
                return ["ok": true]
            case WatchWire.limits:
                let snap = try await LimitsAPI.fetch(relay: lite.relay, apiKey: lite.apiKey, timeout: 25)
                return ["limits": try JSONEncoder().encode(snap)]
            case WatchWire.jobs:
                let jobs = try await JobsAPI.list(relay: lite.relay, apiKey: lite.apiKey)
                SharedVault.saveJobs(jobs)
                return ["jobs": try JSONEncoder().encode(JobsAPI.ordered(jobs))]
            case WatchWire.runJob:
                guard let d = message["job"] as? Data, let job = try? JSONDecoder().decode(JobLite.self, from: d) else {
                    return ["error": "unknown job"]
                }
                try await JobsAPI.run(job, relay: lite.relay, apiKey: lite.apiKey)
                SharedVault.addKick(job)
                WidgetCenter.shared.reloadTimelines(ofKind: HermesWidgetKinds.jobs)
                return ["ok": true]
            case WatchWire.chats:
                return ["chats": try JSONEncoder().encode(try await lite.recentChats())]
            case WatchWire.chat:
                let ex = try await lite.lastExchange(sessionID: message["session"] as? String ?? "")
                return ["exchange": try JSONEncoder().encode(ex)]
            default:
                return ["error": "unknown request"]
            }
        } catch {
            return ["error": (error as? LocalizedError)?.errorDescription ?? "Couldn't reach your agent server."]
        }
    }
}

// MARK: Complications (live line + limits ring)

extension WatchBridge {
    /// The phone's own chat runs → the watch's live line. Sent at start, on a meaningful change at most
    /// every ~45 s, and at the end, so it stays inside watchOS's complication-update budget.
    func pushStatus(_ status: LiveStatus) {
        // The iPhone's own "Hermes Now" widget reads the same status.
        SharedVault.saveStatus(status)
        if status.state != lastWidgetState || Date().timeIntervalSince(lastWidgetReload) > 60 {
            lastWidgetState = status.state
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: HermesWidgetKinds.now)
        }
        let important = status.state != .working || lastPushedStatus?.state != .working
        let changed = status.line != lastPushedStatus?.line || status.state != lastPushedStatus?.state
        guard changed, important || Date().timeIntervalSince(lastStatusPush) > 45 else {
            pendingStatus = status   // the next push (or the end) carries it
            return
        }
        lastPushedStatus = status
        lastStatusPush = Date()
        pendingStatus = nil
        transfer(status.dictionary)
    }

    /// Limits for the ring: when the iPhone has fresh numbers, at most every 20 minutes.
    func pushLimits(_ snapshot: LimitsSnapshot) {
        guard Date().timeIntervalSince(lastLimitsPush) > 20 * 60, let data = try? JSONEncoder().encode(snapshot) else { return }
        lastLimitsPush = Date()
        transfer(["limits": data])
    }

    private func transfer(_ info: [String: Any]) {
        let s = WCSession.default
        guard WCSession.isSupported(), s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        // Wakes the watch app to refresh its complication; budgeted (~50/day), so fall back to the queue.
        if s.isComplicationEnabled, s.remainingComplicationUserInfoTransfers > 3 {
            s.transferCurrentComplicationUserInfo(info)
        } else {
            s.transferUserInfo(info)
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushContext() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushContext() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let message = message
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in reply(await self.handle(message)) }
    }
}
