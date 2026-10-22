import Foundation

// Hotspot failover for Otto: when this Mac's Wi-Fi stops reaching the internet for a while, join the
// user's iPhone Personal Hotspot; when the normal Wi-Fi is back and stable, go back to it so phone data
// isn't burned.
//
// The hotspot handoff (CoreWLAN SSID-filtered scan + associate, hotspot password in the login Keychain,
// Location Services to read network names, failover after a sustained Wi-Fi loss with backoff) is ported
// from Insomnia by Krish Garg (https://github.com/krishhgg/Insomnia, MIT; see THIRD_PARTY_NOTICES.md).
// Otto adds: detection by real reachability (a captive portal or a dead uplink counts, not only a dropped
// association), a verify step after each join, and switching back to the original Wi-Fi.
//
// This file is the pure state machine: no clocks, no I/O. The helper feeds it one Observation per tick
// and performs the Actions it returns.

public struct NetwatchConfig: Codable, Equatable, Sendable {
    /// Fail over automatically. "Test now" works while this is off.
    public var enabled: Bool
    /// The iPhone's Personal Hotspot network name, e.g. "Sam's iPhone".
    public var hotspotSSID: String
    /// Seconds of continuous no-internet on Wi-Fi before joining the hotspot (ignore brief blips).
    public var outageSeconds: Double
    /// Seconds a join (or a switch back) gets to come online before it counts as failed.
    public var verifySeconds: Double
    /// Seconds the original Wi-Fi must stay visible before switching back to it.
    public var stableSeconds: Double

    public init(enabled: Bool = false, hotspotSSID: String = "", outageSeconds: Double = 25,
                verifySeconds: Double = 30, stableSeconds: Double = 120) {
        self.enabled = enabled
        self.hotspotSSID = hotspotSSID
        self.outageSeconds = outageSeconds
        self.verifySeconds = verifySeconds
        self.stableSeconds = stableSeconds
    }

    enum CodingKeys: String, CodingKey {
        case enabled, hotspotSSID = "hotspot_ssid", outageSeconds = "outage_seconds",
             verifySeconds = "verify_seconds", stableSeconds = "stable_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NetwatchConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        hotspotSSID = try c.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? d.hotspotSSID
        // Clamp so a hand-edited file can't make the helper flap or never act.
        outageSeconds = min(max(try c.decodeIfPresent(Double.self, forKey: .outageSeconds) ?? d.outageSeconds, 10), 600)
        verifySeconds = min(max(try c.decodeIfPresent(Double.self, forKey: .verifySeconds) ?? d.verifySeconds, 10), 120)
        stableSeconds = min(max(try c.decodeIfPresent(Double.self, forKey: .stableSeconds) ?? d.stableSeconds, 30), 3600)
    }

    public var ssid: String { hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// One look at the network, taken by the helper each tick.
public struct Observation: Equatable, Sendable {
    /// The internet answered (captive.apple.com or https://1.1.1.1), so a captive portal counts as offline.
    public var online: Bool
    /// The Mac is on the iPhone hotspot (its SSID, or the 172.20.10.1 router every iPhone hotspot uses).
    public var onHotspot: Bool
    /// The current Wi-Fi network's name; nil when not joined or unreadable (no Location Services access).
    public var ssid: String?
    /// While on the hotspot after a failover: whether the original Wi-Fi was seen in a scan this tick
    /// (nil = not scanned this tick).
    public var homeVisible: Bool?

    public init(online: Bool, onHotspot: Bool, ssid: String? = nil, homeVisible: Bool? = nil) {
        self.online = online
        self.onHotspot = onHotspot
        self.ssid = ssid
        self.homeVisible = homeVisible
    }
}

public enum FailoverAction: Equatable, Sendable {
    case joinHotspot
    /// Go back to this Wi-Fi network (nil: unknown, let macOS pick its preferred network).
    case switchBack(String?)
}

public struct FailoverEvent: Codable, Equatable, Sendable {
    public var at: Double
    /// outage | recovered | failover | failover_failed | left_hotspot | switch_back | switch_back_failed |
    /// test_ok | test_failed
    public var kind: String
    public var detail: String

    public init(at: Date, kind: String, detail: String) {
        self.at = at.timeIntervalSince1970
        self.kind = kind
        self.detail = detail
    }
}

public struct FailoverEngine: Sendable {
    public enum Phase: Equatable, Sendable {
        case watching
        /// Joining the hotspot; `test` = started by "Test now" (switch back right after).
        case joining(since: Date, test: Bool)
        case onHotspot(since: Date)
        case switchingBack(since: Date, test: Bool)

        public var name: String {
            switch self {
            case .watching: "watching"
            case .joining(_, let t): t ? "testing" : "joining"
            case .onHotspot: "on_hotspot"
            case .switchingBack(_, let t): t ? "testing" : "switching_back"
            }
        }
    }

    /// Waits after the n-th failed join: 30 s, 1, 2, 5, then every 10 minutes.
    public static let joinBackoff: [Double] = [30, 60, 120, 300, 600]
    /// Waits after the n-th failed switch back: 5, 10, 20, 30, then every 60 minutes.
    public static let switchBackBackoff: [Double] = [300, 600, 1200, 1800, 3600]
    /// With no Location Services access the original Wi-Fi's name is unknown, so it can't be scanned
    /// for: try going back this long after the failover instead (then switchBackBackoff).
    public static let blindSwitchBackAfter: Double = 600

    public private(set) var phase: Phase = .watching
    /// Start of the current no-internet stretch (nil = online).
    public private(set) var offlineSince: Date?
    /// The Wi-Fi to go back to after a failover.
    public private(set) var homeSSID: String?
    /// The last non-hotspot network seen online.
    public private(set) var lastGoodSSID: String?
    public private(set) var joinFailures = 0
    public private(set) var nextJoinAt: Date?
    public private(set) var switchBackFailures = 0
    public private(set) var nextSwitchBackAt: Date?
    /// Since when the original Wi-Fi has been visible in every scan while on the hotspot.
    public private(set) var homeSeenSince: Date?
    public private(set) var testPending = false
    public private(set) var lastFailover: Date?
    public private(set) var lastSwitchBack: Date?
    public private(set) var lastTest: (at: Date, ok: Bool, detail: String)?
    private var testJoinFailed = false
    /// We switched back to Wi-Fi ourselves and it hasn't yet held for `probation`.
    private var switchedBackByUs = false
    /// A switch back counts as failed if that Wi-Fi drops again within this many seconds.
    public static let probation: Double = 300

    public init() {}

    public static func delay(_ table: [Double], failures n: Int) -> Double {
        table[min(max(n - 1, 0), table.count - 1)]
    }

    /// "Test now": join the hotspot, check it reaches the internet, then go back to Wi-Fi.
    public mutating func requestTest() { testPending = true }

    /// Feeds one observation; returns what to do now and what happened (for the log).
    public mutating func step(_ o: Observation, now: Date, config: NetwatchConfig)
        -> (actions: [FailoverAction], events: [FailoverEvent]) {
        var actions: [FailoverAction] = []
        var events: [FailoverEvent] = []
        func event(_ kind: String, _ detail: String) { events.append(FailoverEvent(at: now, kind: kind, detail: detail)) }
        let hotspot = config.ssid

        if o.online, !o.onHotspot, let s = o.ssid, !s.isEmpty, s != hotspot { lastGoodSSID = s }

        switch phase {
        case .watching:
            if o.online {
                if let since = offlineSince {
                    event("recovered", "Internet back after \(Self.human(now.timeIntervalSince(since))) without switching.")
                }
                offlineSince = nil
                joinFailures = 0
                nextJoinAt = nil
                if switchedBackByUs, let back = lastSwitchBack, now.timeIntervalSince(back) >= Self.probation {
                    // The switch back held: forget earlier failed ones.
                    switchedBackByUs = false
                    switchBackFailures = 0
                    nextSwitchBackAt = nil
                }
                if testPending {
                    testPending = false
                    if hotspot.isEmpty {
                        finishTest(now, ok: false, "Set the hotspot name first.", &events)
                    } else if o.onHotspot {
                        finishTest(now, ok: true, "Already on the hotspot and online.", &events)
                    } else {
                        homeSSID = o.ssid ?? lastGoodSSID
                        phase = .joining(since: now, test: true)
                        actions.append(.joinHotspot)
                    }
                }
                return (actions, events)
            }
            // No internet.
            if offlineSince == nil {
                offlineSince = now
                event("outage", o.onHotspot ? "No internet on the hotspot." : "No internet on Wi-Fi.")
            }
            if o.onHotspot {
                // Already on the hotspot (joined by hand, or it left us here): nothing better to join.
                if testPending { testPending = false; finishTest(now, ok: false, "The hotspot isn't reaching the internet.", &events) }
                return (actions, events)
            }
            guard !hotspot.isEmpty else { return (actions, events) }
            let manual = testPending
            testPending = false
            guard config.enabled || manual else { return (actions, events) }
            let waited = now.timeIntervalSince(offlineSince!)
            // "Test now" while offline is just an immediate failover.
            guard manual || waited >= config.outageSeconds else { return (actions, events) }
            if !manual, let next = nextJoinAt, now < next { return (actions, events) }
            if let back = lastSwitchBack, now.timeIntervalSince(back) < Self.probation, switchedBackByUs {
                // The Wi-Fi we went back to died again soon after: that switch back failed. Back off
                // before trying it again, so an unreliable Wi-Fi can't bounce us every few minutes.
                switchBackFailures += 1
                let wait = Self.delay(Self.switchBackBackoff, failures: switchBackFailures)
                nextSwitchBackAt = now.addingTimeInterval(wait)
                event("switch_back_failed", "\(homeSSID ?? "Wi-Fi") dropped again soon after switching back. Next try in \(Self.human(wait)).")
            }
            switchedBackByUs = false
            homeSSID = (o.ssid.flatMap { $0 == hotspot ? nil : $0 }) ?? lastGoodSSID
            phase = .joining(since: now, test: false)
            actions.append(.joinHotspot)

        case .joining(let since, let test):
            if o.onHotspot, o.online {
                joinFailures = 0
                nextJoinAt = nil
                offlineSince = nil
                homeSeenSince = nil
                if test {
                    // Proven: go straight back to Wi-Fi.
                    phase = .switchingBack(since: now, test: true)
                    actions.append(.switchBack(homeSSID))
                } else {
                    phase = .onHotspot(since: now)
                    lastFailover = now
                    event("failover", "Joined \(hotspot) and the internet answered.")
                }
            } else if o.online, !o.onHotspot, !test, now.timeIntervalSince(since) >= 3 {
                // Wi-Fi came back on its own while we were trying.
                phase = .watching
                offlineSince = nil
                joinFailures = 0
                nextJoinAt = nil
                event("recovered", "Wi-Fi came back before the hotspot join finished.")
            } else if now.timeIntervalSince(since) >= config.verifySeconds {
                joinFailures += 1
                let wait = Self.delay(Self.joinBackoff, failures: joinFailures)
                nextJoinAt = now.addingTimeInterval(wait)
                let why = o.onHotspot ? "joined \(hotspot) but the internet didn't answer"
                                      : "couldn't join \(hotspot)"
                if test {
                    testJoinFailed = true
                    finishTest(now, ok: false, "Test failed: \(why). Is Personal Hotspot on and the iPhone nearby?", &events)
                    if o.online, !o.onHotspot {
                        // The join never left the Wi-Fi: nothing to switch back from.
                        testJoinFailed = false
                        phase = .watching
                    } else {
                        phase = .switchingBack(since: now, test: true)
                        actions.append(.switchBack(homeSSID))
                    }
                } else {
                    phase = .watching
                    event("failover_failed", "Failover failed: \(why). Next try in \(Self.human(wait)).")
                }
            }

        case .onHotspot(let since):
            if !o.onHotspot {
                phase = .watching
                homeSeenSince = nil
                if o.online {
                    event("left_hotspot", "Off the hotspot and online (\(o.ssid ?? "Wi-Fi")).")
                    lastSwitchBack = now
                } else {
                    offlineSince = now
                    event("left_hotspot", "Dropped off the hotspot; no internet.")
                }
                return (actions, events)
            }
            if testPending { testPending = false; finishTest(now, ok: o.online, o.online ? "On the hotspot and online." : "On the hotspot but offline.", &events) }
            if let home = homeSSID {
                if o.homeVisible == true { homeSeenSince = homeSeenSince ?? now }
                if o.homeVisible == false { homeSeenSince = nil }
                if let next = nextSwitchBackAt, now < next { return (actions, events) }
                if let seen = homeSeenSince, now.timeIntervalSince(seen) >= config.stableSeconds {
                    phase = .switchingBack(since: now, test: false)
                    actions.append(.switchBack(home))
                }
            } else if now >= (nextSwitchBackAt ?? since.addingTimeInterval(Self.blindSwitchBackAfter)) {
                phase = .switchingBack(since: now, test: false)
                actions.append(.switchBack(nil))
            }

        case .switchingBack(let since, let test):
            if o.online, !o.onHotspot {
                phase = .watching
                // switchBackFailures / nextSwitchBackAt stay until the Wi-Fi has held for `probation`.
                homeSeenSince = nil
                offlineSince = nil
                lastSwitchBack = now
                switchedBackByUs = !test
                if test {
                    if !testJoinFailed {
                        finishTest(now, ok: true, "Joined \(hotspot), reached the internet, and came back to \(o.ssid ?? "Wi-Fi").", &events)
                    }
                    testJoinFailed = false
                } else {
                    event("switch_back", "Back on \(o.ssid ?? "Wi-Fi"); the internet answered.")
                }
            } else if now.timeIntervalSince(since) >= config.verifySeconds {
                switchBackFailures += 1
                let wait = Self.delay(Self.switchBackBackoff, failures: switchBackFailures)
                nextSwitchBackAt = now.addingTimeInterval(wait)
                event("switch_back_failed", "Couldn't get back on \(homeSSID ?? "Wi-Fi"); staying on the hotspot. Next try in \(Self.human(wait)).")
                homeSeenSince = nil
                if o.onHotspot, o.online {
                    phase = .onHotspot(since: now)
                } else {
                    phase = .joining(since: now, test: false)
                    actions.append(.joinHotspot)
                }
            }
        }
        return (actions, events)
    }

    private mutating func finishTest(_ now: Date, ok: Bool, _ detail: String, _ events: inout [FailoverEvent]) {
        lastTest = (now, ok, detail)
        events.append(FailoverEvent(at: now, kind: ok ? "test_ok" : "test_failed", detail: detail))
    }

    /// "45s", "2m 10s", "1h 5m".
    public static func human(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }
}
