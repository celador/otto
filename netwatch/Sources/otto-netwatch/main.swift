// otto-netwatch: Otto's hotspot failover helper (non-sandboxed, per-user LaunchAgent).
//
//   otto-netwatch run                         the watcher (launchd runs this; see scripts/install_netwatch.sh)
//   otto-netwatch set-password --ssid NAME    reads the hotspot password from stdin, saves it in the login
//                                             Keychain (never in a file, an argument or a log)
//   otto-netwatch clear-password --ssid NAME
//   otto-netwatch status                      prints status.json
//
// The hotspot handoff is ported from Insomnia by Krish Garg (https://github.com/krishhgg/Insomnia, MIT):
// CoreWLAN SSID-filtered scan + associate (the password never goes into process arguments), the hotspot
// password in the login Keychain read with prompts switched off, Location Services to read network names.
// See THIRD_PARTY_NOTICES.md. Otto's state machine is NetwatchCore/FailoverEngine.swift.

import CoreLocation
import CoreWLAN
import Foundation
import NetwatchCore
import Network
import Security
import SystemConfiguration

let keychainService = "otto-hotspot"
let paths = NetwatchPaths.standard()

func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

func log(_ s: String) {
    let line = "\(stamp()) \(s)"
    print(line)
    fflush(stdout)
    paths.appendLog(line)
}

// MARK: - Keychain (login keychain; the item's access list trusts this signed helper)

enum Keychain {
    static func query(_ ssid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: ssid]
    }

    /// Whether an item exists. Attributes only, so no access check and never a prompt.
    static func has(_ ssid: String) -> Bool {
        var q = query(ssid)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    /// The password, or nil + why. The watcher switches keychain prompts off, so a read that would need
    /// one (another program's item, a locked keychain) fails instead of showing a dialog.
    static func get(_ ssid: String) -> (String?, String?) {
        var q = query(ssid)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess, let d = out as? Data { return (String(decoding: d, as: UTF8.self), nil) }
        if st == errSecItemNotFound { return (nil, "No hotspot password saved.") }
        return (nil, "Keychain: \(SecCopyErrorMessageString(st, nil) as String? ?? "OSStatus \(st)")")
    }

    static func set(_ ssid: String, _ password: String) -> OSStatus {
        let data = Data(password.utf8)
        let st = SecItemUpdate(query(ssid) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = query(ssid)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Otto hotspot password (\(ssid))"
            return SecItemAdd(add as CFDictionary, nil)
        }
        return st
    }

    static func delete(_ ssid: String) -> OSStatus {
        let st = SecItemDelete(query(ssid) as CFDictionary)
        return st == errSecItemNotFound ? errSecSuccess : st
    }
}

/// Switches keychain dialogs off for this process (the watcher must never block on one).
func keychainPromptsOff() {
    typealias SetInteraction = @convention(c) (UInt8) -> OSStatus
    if let h = dlopen(nil, RTLD_LAZY), let p = dlsym(h, "SecKeychainSetUserInteractionAllowed") {
        _ = unsafeBitCast(p, to: SetInteraction.self)(0)
    }
}

// MARK: - Network facts

func wifiInterface() -> CWInterface? {
    CWWiFiClient.shared().interface() ?? CWWiFiClient.shared().interfaces()?.first
}

/// The default route's router (SystemConfiguration), e.g. 172.20.10.1 on an iPhone hotspot.
func currentRouter() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "otto-netwatch" as CFString, nil, nil),
          let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    else { return nil }
    return dict["Router"] as? String
}

/// The internet answers: Apple's captive check says "Success", or Cloudflare answers over TLS by IP
/// (a captive portal can fake neither). 5 s each, run together.
final class Prober {
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 6
        c.waitsForConnectivity = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpMaximumConnectionsPerHost = 1
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    func fetch(_ url: String, ok: @escaping (Int, String) -> Bool) async -> Bool {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("close", forHTTPHeaderField: "Connection")
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return ok(http.statusCode, String(decoding: data.prefix(4096), as: UTF8.self))
    }

    func online() async -> Bool {
        // OTTO_NETWATCH_PROBE_URL (tests only): probe this URL instead, e.g. an unroutable one to rehearse an
        // outage on a real Mac without taking its Wi-Fi down.
        if let custom = ProcessInfo.processInfo.environment["OTTO_NETWATCH_PROBE_URL"] {
            return await fetch(custom) { code, _ in code == 200 }
        }
        async let apple = fetch("http://captive.apple.com/hotspot-detect.html") { code, body in code == 200 && body.contains("Success") }
        async let cf = fetch("https://1.1.1.1/cdn-cgi/trace") { code, body in code == 200 && body.contains("ip=") }
        let (a, b) = await (apple, cf)
        return a || b
    }
}

// MARK: - Location Services (needed only to read Wi-Fi network names)

final class LocationGate: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    override init() {
        super.init()
        manager.delegate = self
    }

    var state: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }

    /// Shows the one-time macOS prompt if it was never answered.
    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            log("asking for Location Services access (to read Wi-Fi network names)")
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        log("location access: \(state)")
    }
}

// MARK: - Joining

enum Joiner {
    /// Finds the network by name (scan filtered by SSID: works even when macOS redacts names) and joins.
    static func join(ssid: String, password: String?, iface: CWInterface) -> String? {
        if !iface.powerOn() {
            do { try iface.setPower(true) } catch { return "Wi-Fi is off and couldn't be turned on." }
            Thread.sleep(forTimeInterval: 3)
        }
        var found: CWNetwork?
        for attempt in 1...3 {
            do {
                let nets = try iface.scanForNetworks(withSSID: Data(ssid.utf8))
                found = nets.max { $0.rssiValue < $1.rssiValue }
            } catch {
                log("scan for \(ssid) failed (attempt \(attempt)): \(error.localizedDescription)")
            }
            if found != nil { break }
            Thread.sleep(forTimeInterval: 2)
        }
        guard let net = found else { return "\(ssid) isn't in range." }
        do {
            try iface.associate(to: net, password: password)
            return nil
        } catch {
            return "Couldn't join \(ssid): \(error.localizedDescription)"
        }
    }

    /// Back to the original Wi-Fi: CoreWLAN with its saved credentials, then networksetup (which uses
    /// the saved password). With no name known (no Location Services access), or when both fail, turn
    /// Wi-Fi off and on: macOS then auto-joins its preferred known network, and it ranks ordinary Wi-Fi
    /// above Personal Hotspots, so the hotspot is only rejoined when nothing else is around.
    static func switchBack(home: String?, iface: CWInterface) -> String? {
        if let home {
            if join(ssid: home, password: nil, iface: iface) == nil { return nil }
            if networksetupJoin(home, iface: iface) == nil { return nil }
            log("couldn't rejoin \(home) directly; cycling Wi-Fi so macOS picks its preferred network")
        }
        do {
            try iface.setPower(false)
            Thread.sleep(forTimeInterval: 2)
            try iface.setPower(true)
            return nil
        } catch {
            try? iface.setPower(true)
            return "Couldn't cycle Wi-Fi: \(error.localizedDescription)"
        }
    }

    static func networksetupJoin(_ ssid: String, iface: CWInterface) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-setairportnetwork", iface.interfaceName ?? "en0", ssid]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "networksetup: \(error.localizedDescription)" }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && text.isEmpty ? nil
            : "networksetup: \(text.isEmpty ? "exit \(p.terminationStatus)" : text)"
    }
}

// MARK: - The watcher

final class Watcher {
    var engine = FailoverEngine()
    let prober = Prober()
    let location = LocationGate()
    var events: [FailoverEvent] = []
    var lastError: NetwatchStatus.Mark?
    var lastOnline = true
    var lastProbe = Date.distantPast
    var lastScan = Date.distantPast
    var probeNow = true
    var passwordSaved = false
    var passwordCheckedAt = Date.distantPast
    var passwordSSID = ""
    var lastLocationCheck = Date()
    let monitor = NWPathMonitor()

    func start() {
        keychainPromptsOff()
        try? paths.ensureDir()
        monitor.pathUpdateHandler = { [weak self] _ in self?.probeNow = true }
        monitor.start(queue: .global())
        log("otto-netwatch started (pid \(getpid()), state in \(paths.dir.path))")
        if !paths.loadConfig().ssid.isEmpty { location.requestIfNeeded() }
        Task.detached { await self.loop() }
    }

    var busy: Bool { engine.phase != .watching || !lastOnline || engine.testPending }

    func loop() async {
        while true {
            await tick()
            try? await Task.sleep(for: .seconds(busy ? 2 : 5))
        }
    }

    func tick() async {
        let now = Date()
        let config = paths.loadConfig()
        if FileManager.default.fileExists(atPath: paths.testRequest.path) {
            try? FileManager.default.removeItem(at: paths.testRequest)
            log("test requested")
            engine.requestTest()
            if !config.ssid.isEmpty { await MainActor.run { location.requestIfNeeded() } }
        }
        // Location Services turned on later (system-wide): ask once it becomes askable, without a restart.
        if !config.ssid.isEmpty, now.timeIntervalSince(lastLocationCheck) >= 60 {
            lastLocationCheck = now
            await MainActor.run { location.requestIfNeeded() }
        }
        let iface = wifiInterface()
        let ssid = iface?.ssid()
        let router = currentRouter()
        let onHotspot = HotspotHeuristics.isHotspot(ssid: ssid, router: router, hotspotSSID: config.ssid)

        if busy || probeNow || now.timeIntervalSince(lastProbe) >= 15 {
            probeNow = false
            lastOnline = await prober.online()
            lastProbe = Date()
        }

        var homeVisible: Bool?
        if case .onHotspot = engine.phase, let home = engine.homeSSID, let iface, now.timeIntervalSince(lastScan) >= 30 {
            lastScan = now
            let nets = (try? iface.scanForNetworks(withSSID: Data(home.utf8))) ?? []
            homeVisible = nets.contains { $0.rssiValue > -80 }
        }

        let obs = Observation(online: lastOnline, onHotspot: onHotspot, ssid: ssid, homeVisible: homeVisible)
        let (actions, newEvents) = engine.step(obs, now: Date(), config: config)
        for e in newEvents { record(e) }
        for a in actions { perform(a, config: config, iface: iface) }
        if !actions.isEmpty { probeNow = true }

        if config.ssid != passwordSSID || now.timeIntervalSince(passwordCheckedAt) > 30 {
            passwordSSID = config.ssid
            passwordSaved = !config.ssid.isEmpty && Keychain.has(config.ssid)
            passwordCheckedAt = now
        }
        let status = NetwatchStatus(
            pid: getpid(), now: Date(), link: NetwatchStatus.link(obs), engine: engine, config: config,
            passwordSaved: passwordSaved, ssid: ssid, wifiPower: iface?.powerOn() ?? false,
            location: location.state, lastError: lastError, events: Array(events.suffix(20)))
        try? paths.writeStatus(status)
    }

    func record(_ e: FailoverEvent) {
        events.append(e)
        if events.count > 50 { events.removeFirst(events.count - 50) }
        log("[\(e.kind)] \(e.detail)")
    }

    func fail(_ detail: String) {
        lastError = NetwatchStatus.Mark(at: Date(), ok: false, detail: detail)
        log("error: \(detail)")
    }

    func perform(_ action: FailoverAction, config: NetwatchConfig, iface: CWInterface?) {
        guard let iface else { fail("No Wi-Fi interface."); return }
        switch action {
        case .joinHotspot:
            let (pw, why) = Keychain.get(config.ssid)
            if pw == nil, let why { log("no readable hotspot password (\(why)); trying saved network credentials") }
            log("joining hotspot \(config.ssid)")
            if let err = Joiner.join(ssid: config.ssid, password: pw, iface: iface) {
                let inRange = !err.hasSuffix("isn't in range.")
                fail(pw == nil && inRange ? "\(err) Save the hotspot password in Otto → Settings → Hotspot." : inRange ? err
                     : "\(err) Turn on Personal Hotspot on the iPhone (keep its settings screen open) and keep it nearby.")
            }
        case .switchBack(let home):
            log("switching back to \(home ?? "the preferred Wi-Fi")")
            if let err = Joiner.switchBack(home: home, iface: iface) { fail(err) }
        }
    }
}

// MARK: - CLI

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func validSSID(_ s: String?) -> String? {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.utf8.count <= 32 else { return nil }
    return s
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
switch command {
case "run":
    setvbuf(stdout, nil, _IOLBF, 0)
    let watcher = Watcher()
    watcher.start()
    RunLoop.main.run()

case "set-password":
    guard let ssid = validSSID(argValue("--ssid")) else { FileHandle.standardError.write(Data("need --ssid (1-32 bytes)\n".utf8)); exit(2) }
    let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let pw = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    guard (8...63).contains(pw.utf8.count) else { FileHandle.standardError.write(Data("password must be 8-63 characters\n".utf8)); exit(2) }
    let st = Keychain.set(ssid, pw)
    guard st == errSecSuccess else {
        FileHandle.standardError.write(Data("keychain: \(SecCopyErrorMessageString(st, nil) as String? ?? "\(st)")\n".utf8))
        exit(1)
    }
    print("saved")

case "clear-password":
    guard let ssid = validSSID(argValue("--ssid")) else { FileHandle.standardError.write(Data("need --ssid\n".utf8)); exit(2) }
    let st = Keychain.delete(ssid)
    guard st == errSecSuccess else { FileHandle.standardError.write(Data("keychain: \(st)\n".utf8)); exit(1) }
    print("cleared")

case "status":
    if let d = try? Data(contentsOf: paths.status) { FileHandle.standardOutput.write(d); print() } else { print("{}") }

default:
    print("usage: otto-netwatch run | set-password --ssid NAME (password on stdin) | clear-password --ssid NAME | status")
    exit(command == "help" ? 0 : 2)
}
