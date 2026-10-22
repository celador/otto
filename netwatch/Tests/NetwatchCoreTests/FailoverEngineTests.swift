import Foundation
import Testing
@testable import NetwatchCore

/// A fake network + clock: the engine's actions change which network the Mac is on, and the test flips
/// whether the Wi-Fi uplink and the hotspot work. One tick = 2 s, like the helper while it's busy.
struct Sim {
    enum Net { case wifi, hotspot, none }
    var engine = FailoverEngine()
    var config = NetwatchConfig(enabled: true, hotspotSSID: "Sam's iPhone")
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var on: Net = .wifi
    var wifiUplink = true
    var wifiInRange = true
    var hotspotUp = true
    /// Whether associating back to the Wi-Fi works.
    var switchBackWorks = true
    /// Location Services granted: network names readable.
    var namesReadable = true
    var joins = 0
    var switchBacks: [String?] = []
    var events: [FailoverEvent] = []

    var observation: Observation {
        let onHotspot = on == .hotspot
        let online = (on == .wifi && wifiUplink) || (on == .hotspot && hotspotUp)
        let ssid: String? = !namesReadable ? nil : (on == .wifi ? "Hotel" : on == .hotspot ? config.hotspotSSID : nil)
        var homeVisible: Bool?
        if onHotspot, engine.homeSSID != nil { homeVisible = wifiInRange && wifiUplink }
        return Observation(online: online, onHotspot: onHotspot, ssid: ssid, homeVisible: homeVisible)
    }

    mutating func tick(_ seconds: Double = 2) {
        now = now.addingTimeInterval(seconds)
        let r = engine.step(observation, now: now, config: config)
        events += r.events
        for a in r.actions {
            switch a {
            case .joinHotspot:
                joins += 1
                if hotspotUp { on = .hotspot }
            case .switchBack(let s):
                switchBacks.append(s)
                on = wifiInRange && switchBackWorks ? .wifi : .none
            }
        }
    }

    mutating func run(_ seconds: Double, step: Double = 2) {
        var t = 0.0
        while t < seconds { tick(step); t += step }
    }

    var kinds: [String] { events.map(\.kind) }
}

@Suite struct DetectionTests {
    @Test func briefBlipIsIgnored() {
        var s = Sim()
        s.run(10)
        s.wifiUplink = false
        s.run(16)            // < 25 s
        s.wifiUplink = true
        s.run(10)
        #expect(s.joins == 0)
        #expect(s.kinds == ["outage", "recovered"])
        #expect(s.engine.phase == .watching)
    }

    @Test func sustainedLossFailsOverWithinAMinute() {
        var s = Sim()
        s.run(10)
        s.wifiUplink = false
        var waited = 0.0
        while s.on != .hotspot, waited < 120 { s.tick(); waited += 2 }
        #expect(s.joins == 1)
        #expect(waited >= 25 && waited <= 30)
        s.run(4)
        #expect(s.engine.phase == .onHotspot(since: s.engine.lastFailover!))
        #expect(s.kinds == ["outage", "failover"])
        #expect(s.engine.homeSSID == "Hotel")
    }

    @Test func disabledNeverJoins() {
        var s = Sim()
        s.config.enabled = false
        s.wifiUplink = false
        s.run(300)
        #expect(s.joins == 0)
        #expect(s.on == .wifi)
    }

    @Test func noHotspotNameNeverJoins() {
        var s = Sim()
        s.config.hotspotSSID = "  "
        s.wifiUplink = false
        s.run(300)
        #expect(s.joins == 0)
    }

    @Test func offlineWhileAlreadyOnHotspotDoesNothing() {
        var s = Sim()
        s.on = .hotspot
        s.hotspotUp = false
        s.run(120)
        #expect(s.joins == 0)
        #expect(s.switchBacks.isEmpty)
    }
}

@Suite struct BackoffTests {
    @Test func failedJoinsBackOffAndNeverLoop() {
        var s = Sim()
        s.hotspotUp = false     // iPhone not around
        s.wifiUplink = false
        s.run(60 * 60)          // one hour of outage
        // 25 s detect, then verify 30 s + waits 30, 60, 120, 300, 600, 600, ... → about 8 joins in an hour.
        #expect(s.joins >= 6 && s.joins <= 9, "joins: \(s.joins)")
        #expect(s.engine.joinFailures == s.joins)
        #expect(s.kinds.filter { $0 == "failover_failed" }.count == s.joins)
        #expect(s.engine.nextJoinAt != nil)
    }

    @Test func backoffTable() {
        #expect(FailoverEngine.delay(FailoverEngine.joinBackoff, failures: 1) == 30)
        #expect(FailoverEngine.delay(FailoverEngine.joinBackoff, failures: 4) == 300)
        #expect(FailoverEngine.delay(FailoverEngine.joinBackoff, failures: 40) == 600)
        #expect(FailoverEngine.delay(FailoverEngine.switchBackBackoff, failures: 9) == 3600)
    }

    @Test func recoveryResetsBackoff() {
        var s = Sim()
        s.hotspotUp = false
        s.wifiUplink = false
        s.run(200)
        #expect(s.engine.joinFailures > 0)
        s.wifiUplink = true
        s.on = .wifi
        s.run(10)
        #expect(s.engine.joinFailures == 0)
        #expect(s.engine.nextJoinAt == nil)
        #expect(s.engine.phase == .watching)
    }

    @Test func hotspotThatComesUpLaterIsJoinedOnTheNextTry() {
        var s = Sim()
        s.hotspotUp = false
        s.wifiUplink = false
        s.run(70)               // first join failed at ~55 s
        #expect(s.engine.joinFailures == 1)
        s.hotspotUp = true      // John turns Personal Hotspot on
        s.run(40)
        #expect(s.on == .hotspot)
        #expect(s.engine.joinFailures == 0)
        #expect(s.kinds.last == "failover")
    }
}

@Suite struct SwitchBackTests {
    static func failedOver() -> Sim {
        var s = Sim()
        s.run(4)
        s.wifiUplink = false
        s.run(40)
        #expect(s.on == .hotspot)
        return s
    }

    @Test func switchesBackOnceWifiIsStable() {
        var s = Self.failedOver()
        s.run(300, step: 5)          // Wi-Fi still down: stay
        #expect(s.switchBacks.isEmpty)
        s.wifiUplink = true
        s.run(110, step: 5)          // seen < 120 s
        #expect(s.switchBacks.isEmpty)
        s.run(20, step: 5)
        #expect(s.switchBacks == ["Hotel"])
        s.run(4)
        #expect(s.on == .wifi)
        #expect(s.engine.phase == .watching)
        #expect(s.kinds.suffix(1) == ["switch_back"])
    }

    @Test func flappingWifiResetsStability() {
        var s = Self.failedOver()
        for _ in 0..<10 {
            s.wifiUplink = true
            s.run(60, step: 5)
            s.wifiUplink = false
            s.run(10, step: 5)
        }
        #expect(s.switchBacks.isEmpty)
        #expect(s.on == .hotspot)
    }

    @Test func failedSwitchBackReturnsToHotspotAndBacksOff() {
        var s = Self.failedOver()
        s.wifiUplink = true
        s.run(130, step: 5)
        #expect(s.switchBacks.count == 1)
        #expect(s.on == .wifi)
        // The Wi-Fi we went back to dies again a minute later: back to the hotspot, and that switch
        // back counts as failed.
        s.run(60)
        s.wifiUplink = false
        s.run(40)
        #expect(s.on == .hotspot)
        #expect(s.engine.switchBackFailures == 1)
        #expect(s.kinds.contains("switch_back_failed"))
        // Wi-Fi looks fine again right away, but the next try waits 5 minutes (not 2).
        s.wifiUplink = true
        s.run(240, step: 5)
        #expect(s.switchBacks.count == 1)
        s.run(120, step: 5)
        #expect(s.switchBacks.count == 2)
    }

    @Test func switchBackThatNeverComesOnlineReturnsToHotspot() {
        var s = Self.failedOver()
        s.wifiUplink = true
        s.switchBackWorks = false  // the association fails
        s.run(130, step: 5)
        #expect(s.switchBacks.count == 1)
        s.run(40)
        #expect(s.on == .hotspot)
        #expect(s.engine.switchBackFailures == 1)
        #expect(s.kinds.contains("switch_back_failed"))
    }

    @Test func intermittentWifiNeverLoopsFast() {
        // Wi-Fi works for 4 minutes, dies for 2, forever. Count switches in 3 hours.
        var s = Self.failedOver()
        var t = 0.0
        while t < 3 * 3600 {
            s.wifiUplink = Int(t) % 360 < 240
            s.tick(5)
            t += 5
        }
        #expect(s.switchBacks.count <= 8, "switch backs: \(s.switchBacks.count)")
        #expect(s.joins <= 9, "joins: \(s.joins)")
    }

    @Test func switchBackThatHoldsClearsFailures() {
        var s = Self.failedOver()
        s.wifiUplink = true
        s.run(130, step: 5)
        s.run(60)
        s.wifiUplink = false
        s.run(40)
        #expect(s.engine.switchBackFailures == 1)
        s.wifiUplink = true
        s.run(400, step: 5)        // switch back after the 5-minute wait
        #expect(s.on == .wifi)
        s.run(320, step: 5)        // holds past probation
        #expect(s.engine.switchBackFailures == 0)
        #expect(s.engine.nextSwitchBackAt == nil)
    }

    @Test func noLocationAccessStillSwitchesBackBlind() {
        var s = Sim()
        s.namesReadable = false
        s.run(4)
        s.wifiUplink = false
        s.run(40)
        #expect(s.on == .hotspot)       // detected by the 172.20.10.1 router in the helper
        #expect(s.engine.homeSSID == nil)
        s.wifiUplink = true
        s.run(FailoverEngine.blindSwitchBackAfter - 60, step: 10)
        #expect(s.switchBacks.isEmpty)
        s.run(80, step: 10)
        #expect(s.switchBacks == [nil])
        s.run(4)
        #expect(s.on == .wifi)
    }

    @Test func leavingHotspotByHandEndsFailover() {
        var s = Self.failedOver()
        s.on = .wifi
        s.wifiUplink = true
        s.run(4)
        #expect(s.engine.phase == .watching)
        #expect(s.kinds.last == "left_hotspot")
    }
}

@Suite struct TestNowTests {
    @Test func testJoinsVerifiesAndComesBack() {
        var s = Sim()
        s.config.enabled = false        // works while auto-failover is off
        s.run(4)
        s.engine.requestTest()
        s.run(10)
        #expect(s.joins == 1)
        #expect(s.switchBacks == ["Hotel"])
        #expect(s.on == .wifi)
        #expect(s.engine.lastTest?.ok == true)
        #expect(s.kinds == ["test_ok"])
        #expect(s.engine.lastFailover == nil)
    }

    @Test func testWithHotspotOffReportsAndStaysOnWifi() {
        var s = Sim()
        s.hotspotUp = false
        s.run(4)
        s.engine.requestTest()
        s.run(40)
        #expect(s.on == .wifi)
        #expect(s.switchBacks.isEmpty)      // never left the Wi-Fi, so no Wi-Fi cycling
        #expect(s.engine.phase == .watching)
        #expect(s.engine.lastTest?.ok == false)
        #expect(s.kinds == ["test_failed"])
    }

    @Test func testWithoutNameFails() {
        var s = Sim()
        s.config.hotspotSSID = ""
        s.engine.requestTest()
        s.tick()
        #expect(s.joins == 0)
        #expect(s.engine.lastTest?.ok == false)
    }

    @Test func testWhileOfflineFailsOverImmediately() {
        var s = Sim()
        s.config.enabled = false
        s.wifiUplink = false
        s.run(6)
        s.engine.requestTest()
        s.tick()
        #expect(s.joins == 1)
        s.run(4)
        #expect(s.on == .hotspot)
        #expect(s.engine.phase.name == "on_hotspot")
    }
}

@Suite struct FileTests {
    @Test func configDecodesSnakeCaseAndClamps() throws {
        let json = #"{"enabled":true,"hotspot_ssid":" Sam's iPhone ","outage_seconds":1,"stable_seconds":99999}"#
        let c = try JSONDecoder().decode(NetwatchConfig.self, from: Data(json.utf8))
        #expect(c.enabled)
        #expect(c.ssid == "Sam's iPhone")
        #expect(c.outageSeconds == 10)
        #expect(c.stableSeconds == 3600)
        #expect(c.verifySeconds == 30)
    }

    @Test func statusRoundTripsWithoutPassword() throws {
        var s = Sim()
        s.wifiUplink = false
        s.run(40)
        let st = NetwatchStatus(pid: 1, now: s.now, link: NetwatchStatus.link(s.observation), engine: s.engine,
                                config: s.config, passwordSaved: true, ssid: "Sam's iPhone", wifiPower: true,
                                location: "allowed", lastError: nil, events: s.events)
        let data = try JSONEncoder().encode(st)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"link\":\"hotspot\""))
        #expect(text.contains("\"last_failover\""))
        #expect(!text.lowercased().contains("password\":\""))
        #expect(try JSONDecoder().decode(NetwatchStatus.self, from: data) == st)
    }

    @Test func pathsWriteOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nw-\(UUID().uuidString)")
        let p = NetwatchPaths(dir: dir)
        try p.write(Data("{}".utf8), to: p.config)
        let attrs = try FileManager.default.attributesOfItem(atPath: p.config.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dattrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((dattrs[.posixPermissions] as? Int) == 0o700)
        #expect(p.loadConfig() == NetwatchConfig())
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func hotspotHeuristics() {
        #expect(HotspotHeuristics.isHotspot(ssid: nil, router: "172.20.10.1", hotspotSSID: "X"))
        #expect(HotspotHeuristics.isHotspot(ssid: "X", router: "10.0.0.1", hotspotSSID: "X"))
        #expect(!HotspotHeuristics.isHotspot(ssid: "Hotel", router: "192.168.32.1", hotspotSSID: "X"))
        #expect(!HotspotHeuristics.isHotspot(ssid: nil, router: nil, hotspotSSID: ""))
        let ports = """
        Hardware Port: Thunderbolt Bridge
        Device: bridge0

        Hardware Port: Wi-Fi
        Device: en0
        """
        #expect(HotspotHeuristics.wifiDevice(fromHardwarePorts: ports) == "en0")
    }
}
