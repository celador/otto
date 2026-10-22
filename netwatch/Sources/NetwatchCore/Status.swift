import Foundation

/// What the helper writes to status.json every few seconds; the relay (relay/netwatch.py) serves it to
/// Otto as GET /hermes/hotspot. snake_case keys. Never contains the hotspot password.
public struct NetwatchStatus: Codable, Equatable, Sendable {
    public struct Mark: Codable, Equatable, Sendable {
        public var at: Double
        public var ok: Bool?
        public var detail: String?
        public init(at: Date, ok: Bool? = nil, detail: String? = nil) {
            self.at = at.timeIntervalSince1970
            self.ok = ok
            self.detail = detail
        }
    }

    public var version: Int = 1
    public var pid: Int32
    public var updatedAt: Double
    /// wifi | hotspot | offline
    public var link: String
    /// watching | joining | on_hotspot | switching_back | testing
    public var phase: String
    public var enabled: Bool
    public var hotspotSSID: String
    public var passwordSaved: Bool
    /// The current network's name (nil when not joined or unreadable without Location Services).
    public var ssid: String?
    /// The Wi-Fi Otto goes back to after a failover.
    public var homeSSID: String?
    public var wifiPower: Bool
    /// allowed | denied | not_determined | restricted
    public var location: String
    public var offlineSince: Double?
    public var lastFailover: Mark?
    public var lastSwitchBack: Mark?
    public var lastTest: Mark?
    public var lastError: Mark?
    public var joinFailures: Int
    public var nextJoinAt: Double?
    public var switchBackFailures: Int
    public var nextSwitchBackAt: Double?
    public var events: [FailoverEvent]

    enum CodingKeys: String, CodingKey {
        case version, pid, link, phase, enabled, ssid, location, events
        case updatedAt = "updated_at", hotspotSSID = "hotspot_ssid", passwordSaved = "password_saved"
        case homeSSID = "home_ssid", wifiPower = "wifi_power", offlineSince = "offline_since"
        case lastFailover = "last_failover", lastSwitchBack = "last_switch_back", lastTest = "last_test"
        case lastError = "last_error", joinFailures = "join_failures", nextJoinAt = "next_join_at"
        case switchBackFailures = "switch_back_failures", nextSwitchBackAt = "next_switch_back_at"
    }

    public init(pid: Int32, now: Date, link: String, engine: FailoverEngine, config: NetwatchConfig,
                passwordSaved: Bool, ssid: String?, wifiPower: Bool, location: String,
                lastError: Mark?, events: [FailoverEvent]) {
        self.pid = pid
        updatedAt = now.timeIntervalSince1970
        self.link = link
        phase = engine.phase.name
        enabled = config.enabled
        hotspotSSID = config.ssid
        self.passwordSaved = passwordSaved
        self.ssid = ssid
        homeSSID = engine.homeSSID
        self.wifiPower = wifiPower
        self.location = location
        offlineSince = engine.offlineSince?.timeIntervalSince1970
        lastFailover = engine.lastFailover.map { Mark(at: $0, ok: true) }
        lastSwitchBack = engine.lastSwitchBack.map { Mark(at: $0, ok: true) }
        lastTest = engine.lastTest.map { Mark(at: $0.at, ok: $0.ok, detail: $0.detail) }
        self.lastError = lastError
        joinFailures = engine.joinFailures
        nextJoinAt = engine.nextJoinAt?.timeIntervalSince1970
        switchBackFailures = engine.switchBackFailures
        nextSwitchBackAt = engine.nextSwitchBackAt?.timeIntervalSince1970
        self.events = events
    }

    /// wifi | hotspot | offline, from one observation.
    public static func link(_ o: Observation) -> String {
        o.online ? (o.onHotspot ? "hotspot" : "wifi") : "offline"
    }
}

/// The helper's files under ~/.hermes/otto-netwatch (owner-only).
public struct NetwatchPaths: Sendable {
    public var dir: URL
    public init(dir: URL) { self.dir = dir }

    public static func standard(env: [String: String] = ProcessInfo.processInfo.environment) -> NetwatchPaths {
        let home = env["HERMES_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        return NetwatchPaths(dir: home.appendingPathComponent("otto-netwatch"))
    }

    public var config: URL { dir.appendingPathComponent("config.json") }
    public var status: URL { dir.appendingPathComponent("status.json") }
    /// The relay writes this to ask for "Test now"; the helper deletes it when it starts the test.
    public var testRequest: URL { dir.appendingPathComponent("test-request") }
    public var log: URL { dir.appendingPathComponent("netwatch.log") }

    public func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func loadConfig() -> NetwatchConfig {
        guard let data = try? Data(contentsOf: config),
              let c = try? JSONDecoder().decode(NetwatchConfig.self, from: data) else { return NetwatchConfig() }
        return c
    }

    /// Atomic, 0600.
    public func write(_ data: Data, to url: URL) throws {
        try ensureDir()
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public func writeStatus(_ s: NetwatchStatus) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try write(try enc.encode(s), to: status)
    }

    /// One line per event; trimmed to the last ~2000 lines when it passes 512 KB.
    public func appendLog(_ line: String) {
        try? ensureDir()
        let data = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: log) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            if (try? h.offset()) ?? 0 > 512 * 1024, let all = try? String(contentsOf: log, encoding: .utf8) {
                let keep = all.split(separator: "\n", omittingEmptySubsequences: true).suffix(2000).joined(separator: "\n") + "\n"
                try? write(Data(keep.utf8), to: log)
            }
        } else {
            FileManager.default.createFile(atPath: log.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}

/// iPhone Personal Hotspot always hands out 172.20.10.0/28 with the phone at 172.20.10.1, so the
/// router address identifies it even when macOS hides network names (no Location Services access).
public enum HotspotHeuristics {
    public static let iPhoneRouter = "172.20.10.1"

    public static func isHotspot(ssid: String?, router: String?, hotspotSSID: String) -> Bool {
        if let s = ssid, !s.isEmpty, !hotspotSSID.isEmpty, s == hotspotSSID { return true }
        return router == iPhoneRouter
    }

    /// The Wi-Fi port's device ("en0") from `networksetup -listallhardwareports`.
    public static func wifiDevice(fromHardwarePorts output: String) -> String? {
        var wifi = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let name = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces).lowercased()
                wifi = name == "wi-fi" || name == "airport"
            } else if wifi, line.hasPrefix("Device:") {
                let dev = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                return dev.isEmpty ? nil : dev
            }
        }
        return nil
    }
}
