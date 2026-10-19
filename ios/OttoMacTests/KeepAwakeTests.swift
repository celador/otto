import AppKit
import Foundation
import Testing
@testable import Otto

/// Keep Mac awake: the power assertion is held only while it's needed and released on idle,
/// relay failure, timer end, Off and quit. Fake assertion, fake clock, fake relay.

@MainActor
final class FakeAssertion: PowerAssertionHolding {
    private(set) var isHeld = false
    private(set) var acquires = 0
    private(set) var releases = 0
    var refuse = false

    func acquire(reason: String) -> Bool {
        if isHeld { return true }
        if refuse { return false }
        acquires += 1
        isHeld = true
        return true
    }

    func release() {
        guard isHeld else { return }
        releases += 1
        isHeld = false
    }
}

final class FakeRelay: AwakeRelay, @unchecked Sendable {
    var status: AwakeStatus
    var fail = false
    var outdated = false
    var running = 0
    var posts: [(String, Date?)] = []
    var setupCalls: [String] = []
    /// How the admin prompt ends: done | cancelled | failed; after `promptPolls` status polls.
    var setupOutcome = "done"
    var promptPolls = 2

    init(working: Bool = false, installed: Bool = true) {
        status = AwakeStatus(installed: installed, setup: nil, mode: "off", until: nil, holding: false, holdUntil: nil,
                             sleepDisabled: false, lowPowerByUs: false, agentsWorking: working, agents: nil,
                             battery: nil, thermal: "nominal", last: nil)
    }

    func awakeStatus() async throws -> AwakeStatus {
        if outdated { throw CompanionError.relayOutdated }
        if fail { throw URLError(.cannotConnectToHost) }
        if var job = status.setup, job.state == "running" {
            if promptPolls > 0 {
                promptPolls -= 1
            } else {
                job.state = setupOutcome
                job.detail = setupOutcome == "failed" ? "Couldn't install the rule: boom" : nil
                if setupOutcome == "done" { status.installed = job.action == "setup" }
                status.setup = job
            }
        }
        return status
    }

    func startAwakeSetup(_ action: String) async throws -> AwakeStatus {
        setupCalls.append(action)
        if outdated { throw CompanionError.relayOutdated }
        status.setup = .init(action: action, state: "running", detail: nil, at: 1)
        return status
    }

    func setAwake(mode: String, until: Date?) async throws -> AwakeStatus {
        posts.append((mode, until))
        if !status.installed && mode != "off" { throw HermesError.http(409, "not set up") }
        status.mode = mode
        status.holding = mode == "timer" || (mode == "working" && status.agentsWorking)
        return status
    }

    func runningCount() async throws -> Int {
        if fail { throw URLError(.cannotConnectToHost) }
        return running
    }
}

@MainActor
struct KeepAwakeTests {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 2_000_000_000) }

    func make(_ relay: FakeRelay? = FakeRelay()) -> (KeepAwakeController, FakeAssertion, Clock, UserDefaults) {
        let suite = "keepawake.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let clock = Clock()
        let a = FakeAssertion()
        let c = KeepAwakeController(assertion: a, now: { clock.t }, defaults: d)
        if let relay { c.startForTests(relay: relay) }
        return (c, a, clock, d)
    }

    @Test func offNeverHolds() async {
        let relay = FakeRelay(working: true)
        let (c, a, _, _) = make(relay)
        await c.poll()
        #expect(c.mode == .off)
        #expect(!a.isHeld && a.acquires == 0)
    }

    @Test func whileWorkingHoldsOnlyWhileAgentsWork() async {
        let relay = FakeRelay(working: false)
        let (c, a, _, _) = make(relay)
        c.setMode(.whileWorking)
        await c.poll()
        #expect(!a.isHeld)
        relay.status.agentsWorking = true
        await c.poll()
        #expect(a.isHeld)
        await c.poll()
        #expect(a.acquires == 1)  // one assertion, not one per poll
        relay.status.agentsWorking = false
        await c.poll()
        #expect(!a.isHeld && a.releases == 1)
    }

    @Test func relayFailureReleases() async {
        let relay = FakeRelay(working: true)
        let (c, a, _, _) = make(relay)
        c.setMode(.whileWorking)
        await c.poll()
        #expect(a.isHeld)
        relay.fail = true
        await c.poll()
        #expect(!a.isHeld && c.agentsWorking == nil && c.relayError != nil)
    }

    @Test func timerHoldsUntilEndThenTurnsOff() async {
        let (c, a, clock, d) = make(FakeRelay(working: false))
        c.startTimer(seconds: 3600)
        #expect(a.isHeld)
        #expect(c.mode.endDate == clock.t.addingTimeInterval(3600))
        clock.t += 1800
        c.evaluate()
        #expect(a.isHeld)
        clock.t += 1801
        c.evaluate()
        #expect(!a.isHeld && c.mode == .off)
        let saved = try? JSONDecoder().decode(KeepAwakeMode.self, from: d.data(forKey: KeepAwakeController.Keys.mode) ?? Data())
        #expect(saved == .off)
    }

    @Test func addTimeAndEndEarly() {
        let (c, a, clock, _) = make(nil)
        c.startTimer(seconds: 600)
        c.addTime(3600)
        #expect(c.mode.endDate == clock.t.addingTimeInterval(4200))
        c.endEarly()
        #expect(c.mode == .off && !a.isHeld)
        c.startTimer(seconds: 30)  // under a minute: ignored
        #expect(c.mode == .off)
    }

    @Test func timerKeepsHoldingWhenRelayIsDown() async {
        let relay = FakeRelay()
        let (c, a, _, _) = make(relay)
        relay.fail = true
        c.startTimer(seconds: 600)
        await c.poll()
        #expect(a.isHeld)
    }

    @Test func quitReleases() {
        let (c, a, _, _) = make(nil)
        c.startTimer(seconds: 600)
        #expect(a.isHeld)
        c.shutdown()
        #expect(!a.isHeld)
    }

    @Test func refusedAssertionIsNotHeld() {
        let (c, a, _, _) = make(nil)
        a.refuse = true
        c.startTimer(seconds: 600)
        #expect(!c.isHolding)
    }

    @Test func expiredTimerReadsBackAsOff() {
        let suite = "keepawake.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.set(try? JSONEncoder().encode(KeepAwakeMode.until(Date(timeIntervalSince1970: 100))), forKey: KeepAwakeController.Keys.mode)
        let c = KeepAwakeController(assertion: FakeAssertion(), now: { Date(timeIntervalSince1970: 200) }, defaults: d)
        #expect(c.mode == .off)
    }

    @Test func outdatedRelayFallsBackToRunningChats() async {
        let relay = FakeRelay()
        relay.outdated = true
        relay.running = 2
        let (c, a, _, _) = make(relay)
        c.setMode(.whileWorking)
        await c.poll()
        #expect(c.relayOutdated && a.isHeld && c.workingCount == 2)
        relay.running = 0
        await c.poll()
        #expect(!a.isHeld)
    }

    @Test func lidClosedPushesThePlan() async {
        let relay = FakeRelay(working: true)
        let (c, _, clock, _) = make(relay)
        await c.poll()
        c.setLidClosed(true)  // Off + lid closed on → while working
        #expect(c.mode == .whileWorking)
        await c.pushLidClosed()
        #expect(relay.posts.last?.0 == "working")
        c.startTimer(seconds: 3600)
        await c.pushLidClosed()
        #expect(relay.posts.last?.0 == "timer" && relay.posts.last?.1 == clock.t.addingTimeInterval(3600))
        c.setLidClosed(false)
        await c.pushLidClosed()
        #expect(relay.posts.last?.0 == "off")
    }

    @Test func lidClosedNotInstalledStartsSetupInsteadOfChangingAnything() async {
        let relay = FakeRelay(working: true, installed: false)
        let (c, _, _, _) = make(relay)
        c.setupPollInterval = 0
        await c.poll()
        #expect(!c.lidClosedInstalled)
        c.setLidClosed(true)  // first flip: the one-time setup, not a plan
        for _ in 0..<200 where c.setupBusy != nil || relay.setupCalls.isEmpty { await Task.yield() }
        #expect(relay.setupCalls == ["setup"])
        await c.pushLidClosed()
        for _ in 0..<50 { await Task.yield() }
        #expect(relay.posts.allSatisfy { $0.0 == "working" })  // only after setup succeeded
        #expect(c.lidClosedInstalled && c.lidClosedWanted)
    }

    @Test func setupSucceedsThenTurnsLidClosedOn() async {
        let relay = FakeRelay(working: true, installed: false)
        let (c, _, _, _) = make(relay)
        c.setupPollInterval = 0
        await c.poll()
        await c.runSetup("setup")
        #expect(c.setupBusy == nil && !c.setupFailed)
        #expect(c.setupMessage?.hasPrefix("Done.") == true)
        #expect(c.lidClosedInstalled && c.lidClosedWanted && c.mode == .whileWorking)
        for _ in 0..<50 { await Task.yield() }  // setLidClosed's push
        #expect(relay.posts.last?.0 == "working")
    }

    @Test func setupCancelledChangesNothing() async {
        let relay = FakeRelay(working: true, installed: false)
        relay.setupOutcome = "cancelled"
        let (c, _, _, _) = make(relay)
        c.setupPollInterval = 0
        await c.poll()
        await c.runSetup("setup")
        #expect(c.setupMessage == "Cancelled. Nothing was changed." && !c.setupFailed)
        #expect(!c.lidClosedInstalled && !c.lidClosedWanted && relay.posts.isEmpty && c.mode == .off)
    }

    @Test func setupFailureIsShown() async {
        let relay = FakeRelay(installed: false)
        relay.setupOutcome = "failed"
        let (c, _, _, _) = make(relay)
        c.setupPollInterval = 0
        await c.poll()
        await c.runSetup("setup")
        #expect(c.setupFailed && c.setupMessage?.contains("boom") == true && !c.lidClosedWanted)
    }

    @Test func oldRelayWithoutSetupRouteSaysRestart() async {
        let relay = FakeRelay(installed: false)
        let (c, _, _, _) = make(relay)
        await c.poll()
        relay.outdated = true
        await c.runSetup("setup")
        #expect(c.setupFailed && c.setupMessage?.contains("restarting") == true)
    }

    @Test func undoRemovesSetupAndTurnsLidClosedOff() async {
        let relay = FakeRelay(working: true, installed: true)
        let (c, _, _, _) = make(relay)
        c.setupPollInterval = 0
        await c.poll()
        c.setLidClosed(true)
        #expect(c.lidClosedWanted)
        await c.runSetup("undo")
        #expect(relay.setupCalls == ["undo"] && !c.lidClosedInstalled && !c.lidClosedWanted)
        #expect(c.setupMessage?.contains("sleeps normally") == true)
    }

    /// John: "I don't want a menu bar item." Otto (the test host) has no status item, and the old
    /// "Show in menu bar" setting is gone.
    @Test func noMenuBarStatusItem() {
        let statusWindows = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
        #expect(statusWindows.isEmpty)
        let suite = "keepawake.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.set(true, forKey: KeepAwakeController.Keys.menuBar)
        _ = KeepAwakeController(assertion: FakeAssertion(), defaults: d)
        #expect(d.object(forKey: KeepAwakeController.Keys.menuBar) == nil)
    }

    @Test func relayEndingLidClosedIsExplained() async {
        let relay = FakeRelay(working: true)
        let (c, _, _, _) = make(relay)
        await c.poll()
        c.setLidClosed(true)
        await c.pushLidClosed()
        for _ in 0..<20 { await Task.yield() }  // let setLidClosed's own push finish
        relay.status.mode = "off"
        relay.status.last = .init(at: 1, reason: "battery below 10%")
        await c.poll()
        #expect(c.lidClosedNote == "battery below 10%")
    }

    @Test func decodesRelayStatus() throws {
        let json = """
        {"installed": true, "setup": {"action": "setup", "state": "done", "detail": "ok", "at": 1.0}, "mode": "working", "until": null,
         "holding": true, "hold_until": 2000000600.5, "sleep_disabled": true, "low_power_by_us": false,
         "agents_working": true, "agents": {"chats": 2, "kanban": 1},
         "battery": {"percent": 80, "on_battery": false, "charging": true}, "thermal": "nominal",
         "rules": {"low_power_floor": 40, "end_floor": 10, "thermal_rules": true, "idle_grace": 180.0},
         "last": {"at": 1.0, "reason": "agents finished", "clean": true}, "now": 2000000000.0}
        """
        let s = try HermesClient.decoder.decode(AwakeStatus.self, from: Data(json.utf8))
        #expect(s.holding && s.agentsWorking && s.setup?.state == "done" && s.setup?.action == "setup")
        #expect(s.battery?.onBattery == false && s.agents?.kanban == 1 && s.last?.reason == "agents finished")
    }
}
