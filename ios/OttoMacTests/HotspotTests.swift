import Foundation
import Testing
@testable import Otto

/// Settings → Hotspot: the controller talks only to the relay; the password is sent once and never kept.

final class FakeHotspotRelay: HotspotRelay, @unchecked Sendable {
    var status: HotspotStatus
    var sets: [(Bool?, String?, String?)] = []
    var tests = 0
    var setups = 0
    var failWith: Error?
    /// Polls before a started test / setup finishes.
    var pollsLeft = 2
    var testOK = true

    init(installed: Bool = true, running: Bool = true) {
        status = HotspotStatus(installed: installed, running: running, enabled: false, hotspotSsid: "",
                               setup: nil, link: running ? "wifi" : nil, phase: running ? "watching" : nil,
                               ssid: "Cafe", homeSsid: nil, passwordSaved: false, wifiPower: true, location: "allowed",
                               offlineSince: nil, lastFailover: nil, lastSwitchBack: nil, lastTest: nil,
                               lastError: nil, nextJoinAt: nil, events: [], testPending: false)
    }

    func hotspotStatus() async throws -> HotspotStatus {
        if let failWith { throw failWith }
        if status.phase == "testing" {
            if pollsLeft > 0 { pollsLeft -= 1 } else {
                status.phase = "watching"
                status.lastTest = .init(at: Date().timeIntervalSince1970, ok: testOK,
                                        detail: testOK ? "Joined Sam's iPhone, reached the internet, and came back to Cafe." : "Test failed: couldn't join Sam's iPhone.")
            }
        }
        if var job = status.setup, job.state == "running" {
            if pollsLeft > 0 { pollsLeft -= 1 } else {
                job.state = "done"
                status.setup = job
                status.installed = true
                status.running = true
            }
        }
        return status
    }

    func setHotspot(enabled: Bool?, ssid: String?, password: String?) async throws -> HotspotStatus {
        if let failWith { throw failWith }
        sets.append((enabled, ssid, password))
        if let enabled { status.enabled = enabled }
        if let ssid { status.hotspotSsid = ssid }
        if let password { status.passwordSaved = !password.isEmpty }
        return status
    }

    func testHotspot() async throws -> HotspotStatus {
        if let failWith { throw failWith }
        tests += 1
        status.phase = "testing"
        status.testPending = true
        return status
    }

    func startHotspotSetup() async throws -> HotspotStatus {
        setups += 1
        status.setup = .init(action: "setup", state: "running", detail: nil)
        return status
    }
}

@MainActor
@Suite struct HotspotControllerTests {
    func make(_ relay: FakeHotspotRelay) -> HotspotController {
        let c = HotspotController()
        c.followInterval = 0
        c.startForTests(relay: relay)
        return c
    }

    @Test func statusLines() async {
        let r = FakeHotspotRelay()
        let c = make(r)
        #expect(c.stateLine == "Connecting to Hermes…")
        await c.poll()
        #expect(c.stateLine == "On Wi-Fi (Cafe)")
        r.status.link = "hotspot"
        r.status.phase = "on_hotspot"
        await c.poll()
        #expect(c.stateLine == "On your iPhone hotspot (Wi-Fi isn't working)")
        #expect(c.stateSymbol == "personalhotspot")
        r.status.link = "offline"
        r.status.phase = "joining"
        r.status.hotspotSsid = "Sam's iPhone"
        await c.poll()
        #expect(c.stateLine == "Wi-Fi isn't working — joining Sam's iPhone…")
        r.status.running = false
        await c.poll()
        #expect(c.stateLine == "The network helper isn't running")
        r.status.installed = false
        await c.poll()
        #expect(c.stateLine == "Not set up")
    }

    @Test func passwordIsSentOnceAndNotKept() async {
        let r = FakeHotspotRelay()
        let c = make(r)
        await c.save(ssid: "Sam's iPhone", password: "hunter2hunter2")
        #expect(r.sets.count == 1)
        #expect(r.sets[0].1 == "Sam's iPhone")
        #expect(r.sets[0].2 == "hunter2hunter2")
        #expect(c.status?.passwordSaved == true)
        #expect(c.message == "Saved. The password is in your login Keychain.")
        // Nothing in the controller holds it.
        let mirror = String(describing: Mirror(reflecting: c).children.map { "\($0.value)" })
        #expect(!mirror.contains("hunter2hunter2"))
        await c.save(enabled: true, ssid: "Sam's iPhone")
        #expect(r.sets[1].2 == nil)
        #expect(c.status?.enabled == true)
    }

    @Test func testNowFollowsUntilTheHelperReports() async {
        let r = FakeHotspotRelay()
        r.status.hotspotSsid = "Sam's iPhone"
        let c = make(r)
        await c.test()
        #expect(r.tests == 1)
        #expect(c.busy == nil)
        #expect(c.messageFailed == false)
        #expect(c.message == "Joined Sam's iPhone, reached the internet, and came back to Cafe.")
    }

    @Test func failedTestIsShownAsFailed() async {
        let r = FakeHotspotRelay()
        r.testOK = false
        let c = make(r)
        await c.test()
        #expect(c.messageFailed)
        #expect(c.message == "Test failed: couldn't join Sam's iPhone.")
    }

    @Test func setUpRunsTheRelayJob() async {
        let r = FakeHotspotRelay(installed: false, running: false)
        let c = make(r)
        await c.setUp()
        #expect(r.setups == 1)
        #expect(c.installed)
        #expect(c.message == "The network helper is running.")
    }

    @Test func relayErrorsAreReadable() async {
        let r = FakeHotspotRelay()
        r.failWith = HermesError.http(409, "The network helper isn't running. Set it up first.")
        let c = make(r)
        await c.test()
        #expect(c.messageFailed)
        #expect(c.message == "The network helper isn't running. Set it up first.")
        r.failWith = CompanionError.relayOutdated
        await c.poll()
        #expect(c.relayOutdated)
        #expect(c.stateLine == "The Hermes relay on this Mac needs restarting.")
    }

    @Test func noRelay() async {
        let c = HotspotController()
        await c.poll()
        #expect(c.error == "Not connected to Hermes.")
        await c.save(enabled: true)
        #expect(c.messageFailed)
    }

    @Test func decodesRelayJSON() throws {
        let json = """
        {"installed": true, "running": true, "enabled": true, "hotspot_ssid": "Sam's iPhone", "setup": null,
         "link": "hotspot", "phase": "on_hotspot", "ssid": "Sam's iPhone", "home_ssid": "Cafe", "password_saved": true,
         "wifi_power": true, "location": "denied", "offline_since": null,
         "last_failover": {"at": 1800000000, "ok": true}, "last_test": {"at": 1800000000, "ok": false, "detail": "x"},
         "join_failures": 0, "events": [{"at": 1800000000, "kind": "failover", "detail": "Joined Sam's iPhone"}],
         "test_pending": false, "updated_at": 1800000000}
        """
        let s = try HermesClient.decoder.decode(HotspotStatus.self, from: Data(json.utf8))
        #expect(s.hotspotSsid == "Sam's iPhone")
        #expect(s.homeSsid == "Cafe")
        #expect(s.lastFailover?.ok == true)
        #expect(s.events?.first?.kind == "failover")
    }
}
