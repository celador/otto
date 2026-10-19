import ActivityKit
import Foundation

/// Starts, updates and ends the "Hermes is working" Live Activity for the
/// turn running in the chat on screen. Updates are throttled; the last
/// state always lands. Without push, updates arrive while the app runs
/// (foreground, or the short background window after you leave it).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<HermesRunAttributes>?
    private var lastState: HermesRunAttributes.ContentState?
    private var lastPush = Date.distantPast
    private var pendingTask: Task<Void, Never>?

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "liveActivity.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveActivity.enabled") }
    }

    private var watchRun: (sessionID: String, title: String, started: Date)?

    /// Voice mode is open: its phase rides along in every state, and the activity stays up between
    /// turns until voice mode closes (then it ends, unless a run is still going).
    private var voice: (sessionID: String?, title: String, phase: String, status: String)?

    func start(sessionID: String, title: String) {
        watchRun = (sessionID, ChatTitle.short(title), Date())
        WatchBridge.shared.pushStatus(LiveStatus(state: .working, line: "Thinking…", title: ChatTitle.short(title),
                                                 sessionID: sessionID, steps: 0, startedAt: Date(), updatedAt: Date()))
        guard Self.isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if voice != nil, voice?.sessionID == nil { voice?.sessionID = sessionID }
        if let activity, activity.attributes.sessionID == sessionID, activity.activityState == .active {
            if voice != nil { push(HermesRunAttributes.ContentState(status: "Thinking", toolsUsed: 0, needsApproval: false,
                                                                    finished: false, failed: false, voice: voice?.phase)) }
            return
        }
        endAllImmediately()
        let attributes = HermesRunAttributes(sessionID: sessionID, title: ChatTitle.short(title), startedAt: Date())
        let state = HermesRunAttributes.ContentState(status: "Thinking", toolsUsed: 0, needsApproval: false,
                                                     finished: false, failed: false, voice: voice?.phase)
        do {
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)),
                                            pushType: nil)
            lastState = state
        } catch {
            VoiceDiag.log("live activity: run request failed: \(error)")
            activity = nil
        }
    }

    func update(status: String?, tools: Int, needsApproval: Bool) {
        if let run = watchRun {
            WatchBridge.shared.pushStatus(LiveStatus(state: needsApproval ? .needsYou : .working,
                                                     line: needsApproval ? "Needs your approval" : (status ?? "Thinking…"),
                                                     title: run.title, sessionID: run.sessionID, steps: tools,
                                                     startedAt: run.started, updatedAt: Date()))
        }
        guard activity != nil else { return }
        let state = HermesRunAttributes.ContentState(status: status ?? "Thinking", toolsUsed: tools,
                                                     needsApproval: needsApproval, finished: false, failed: false,
                                                     voice: voice?.phase)
        push(state)
    }

    /// Throttled update of the current activity.
    private func push(_ state: HermesRunAttributes.ContentState) {
        guard activity != nil, state != lastState else { return }
        lastState = state
        // At most ~1 update/second; the latest state always gets through.
        let wait = max(0, 1 - Date().timeIntervalSince(lastPush))
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, let self, let id = self.activity?.id, let latest = self.lastState else { return }
            self.lastPush = Date()
            await Self.update(id: id, state: latest)
        }
    }

    func end(status: String, tools: Int, answer: String? = nil) {
        if let run = watchRun {
            let failed = status == "failed" || status == "interrupted"
            let first = answer.map { WatchSnippet.firstLine($0) }
            WatchBridge.shared.pushStatus(LiveStatus(state: failed ? .failed : .done,
                                                     line: status == "cancelled" ? "Stopped" : failed ? "Didn't finish" : (first ?? "Done"),
                                                     title: run.title, sessionID: run.sessionID, steps: tools,
                                                     startedAt: run.started, updatedAt: Date()))
            watchRun = nil
        }
        guard let activity else { return }
        if let v = voice {
            // Voice mode continues: the run is done but the conversation isn't.
            push(HermesRunAttributes.ContentState(status: v.status, toolsUsed: 0, needsApproval: false,
                                                  finished: false, failed: false, voice: v.phase))
            return
        }
        pendingTask?.cancel()
        let failed = status == "failed" || status == "interrupted"
        let label = status == "cancelled" ? "Stopped" : failed ? "Didn't finish" : "Done"
        let state = HermesRunAttributes.ContentState(status: label, toolsUsed: tools, needsApproval: false,
                                                     finished: true, failed: failed)
        let id = activity.id
        self.activity = nil
        lastState = nil
        Task { await Self.end(id: id, state: state, immediately: false) }
    }

    /// Ends the activity for a session whose run finished while the chat wasn't watching it
    /// (app in the background, chat closed, or another device).
    func end(sessionID: String, status: String) {
        if watchRun?.sessionID == sessionID || activity?.attributes.sessionID == sessionID {
            end(status: status, tools: lastState?.toolsUsed ?? 0)
        }
        let failed = status == "failed" || status == "interrupted"
        let label = status == "cancelled" ? "Stopped" : failed ? "Didn't finish" : "Done"
        for a in Activity<HermesRunAttributes>.activities where a.attributes.sessionID == sessionID {
            if voice != nil, a.id == activity?.id { continue }
            let id = a.id
            let state = HermesRunAttributes.ContentState(status: label, toolsUsed: 0, needsApproval: false, finished: true, failed: failed)
            Task { await Self.end(id: id, state: state, immediately: false) }
        }
    }

    /// Ends every activity whose session has no run in flight. Called when the app becomes active,
    /// so an activity can never outlive its run (it used to sit at "7 hours" until iOS's 8-hour cap).
    func reconcile(runningSessions: Set<String>) {
        for a in Activity<HermesRunAttributes>.activities where !runningSessions.contains(a.attributes.sessionID) {
            if voice != nil, a.id == activity?.id { continue }   // voice mode is still open
            let id = a.id
            if activity?.id == id { activity = nil; lastState = nil; pendingTask?.cancel() }
            Task { await Self.end(id: id, state: nil, immediately: true) }
        }
    }

    // MARK: Voice mode

    /// Voice mode opened or changed phase. Starts an activity if none is showing, so the Dynamic Island
    /// and lock screen show listening / thinking / speaking while the app is in the background.
    func voiceUpdate(sessionID: String?, title: String, phase: String, status: String) {
        voice = (sessionID ?? voice?.sessionID, ChatTitle.short(title), phase, status)
        if activity == nil || activity?.activityState != .active {
            guard Self.isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            endAllImmediately()
            let attributes = HermesRunAttributes(sessionID: sessionID ?? "", title: ChatTitle.short(title),
                                                 startedAt: Date())
            let state = HermesRunAttributes.ContentState(status: status, toolsUsed: 0, needsApproval: false,
                                                         finished: false, failed: false, voice: phase)
            do {
                activity = try Activity.request(attributes: attributes,
                                                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)),
                                                pushType: nil)
                lastState = state
            } catch {
                VoiceDiag.log("live activity: voice request failed: \(error)")
                activity = nil
            }
            return
        }
        push(HermesRunAttributes.ContentState(status: status, toolsUsed: lastState?.toolsUsed ?? 0,
                                              needsApproval: lastState?.needsApproval ?? false,
                                              finished: false, failed: false, voice: phase))
    }

    /// Voice mode closed. The activity never outlives it: it ends now unless a run is still going,
    /// in which case it goes back to being that run's activity (and ends with the run).
    func voiceEnded() {
        guard voice != nil else { return }
        voice = nil
        guard let activity else { return }
        if watchRun != nil {
            push(HermesRunAttributes.ContentState(status: lastState?.status ?? "Thinking",
                                                  toolsUsed: lastState?.toolsUsed ?? 0,
                                                  needsApproval: lastState?.needsApproval ?? false,
                                                  finished: false, failed: false, voice: nil))
            return
        }
        pendingTask?.cancel()
        let id = activity.id
        self.activity = nil
        lastState = nil
        Task { await Self.end(id: id, state: nil, immediately: true) }
    }

    var voiceActive: Bool { voice != nil }

    /// Hands-free voice (Action button, "Talk to Otto", Control Center) from the background: the activity
    /// has to be up BEFORE the mic starts, because iOS only lets a background app record while the
    /// recording intent's Live Activity shows. Waits for leftovers to end first (a stale activity left
    /// running by a killed process made the old fire-and-forget path race), then requests and reports
    /// whether one is showing. Every failure is written to the voice trace.
    func startHandsFreeVoice(title: String) async -> Bool {
        voice = (nil, ChatTitle.short(title), "listening", "Starting…")
        let auth = ActivityAuthorizationInfo()
        guard Self.isEnabled, auth.areActivitiesEnabled else {
            VoiceDiag.log("live activity: off (app setting=\(Self.isEnabled) system=\(auth.areActivitiesEnabled))")
            return false
        }
        pendingTask?.cancel()
        activity = nil
        lastState = nil
        for a in Activity<HermesRunAttributes>.activities {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        let attributes = HermesRunAttributes(sessionID: "", title: ChatTitle.short(title), startedAt: Date())
        let state = HermesRunAttributes.ContentState(status: "Starting…", toolsUsed: 0, needsApproval: false,
                                                     finished: false, failed: false, voice: "listening")
        do {
            let a = try Activity.request(attributes: attributes,
                                         content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)),
                                         pushType: nil)
            activity = a
            lastState = state
            VoiceDiag.log("live activity: hands-free up id=\(a.id.prefix(8)) state=\(a.activityState) count=\(Activity<HermesRunAttributes>.activities.count)")
            return true
        } catch {
            VoiceDiag.log("live activity: hands-free request failed: \(error) (\(String(describing: type(of: error))))")
            activity = nil
            return false
        }
    }

    /// Clears leftovers (e.g. after a crash or relaunch) so only one shows.
    func endAllImmediately() {
        for a in Activity<HermesRunAttributes>.activities {
            let id = a.id
            Task { await Self.end(id: id, state: nil, immediately: true) }
        }
        activity = nil
        lastState = nil
    }

    // Look activities up by id inside a nonisolated context, so no
    // non-Sendable Activity value crosses actors.
    nonisolated private static func update(id: String, state: HermesRunAttributes.ContentState) async {
        guard let a = Activity<HermesRunAttributes>.activities.first(where: { $0.id == id }) else { return }
        await a.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60)))
    }

    nonisolated private static func end(id: String, state: HermesRunAttributes.ContentState?, immediately: Bool) async {
        guard let a = Activity<HermesRunAttributes>.activities.first(where: { $0.id == id }) else { return }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await a.end(content, dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(4)))
    }
}
