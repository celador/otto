import Foundation
import Observation

// iPhone hotspot failover (Otto for Mac): when this Mac's Wi-Fi stops reaching the internet, join the
// user's iPhone Personal Hotspot so Hermes agents, the gateway and the phone relay stay online, and go
// back to Wi-Fi when it returns.
//
// The sandboxed app can't change Wi-Fi networks, so the work is done by otto-netwatch, a small helper
// the Hermes relay installs and runs at login (netwatch/, scripts/install_netwatch.sh). Otto only shows
// its status and edits its settings through the relay: GET/POST /hermes/hotspot, POST
// /hermes/hotspot/test and /hermes/hotspot/setup (relay/netwatch.py). The hotspot password goes from
// the password field straight to the relay, which hands it to the helper to keep in the login Keychain;
// Otto never stores it and the relay never sends it back.

/// GET/POST /hermes/hotspot, decoded with HermesClient.decoder (snake_case → camelCase).
struct HotspotStatus: Decodable, Equatable, Sendable {
    struct Mark: Decodable, Equatable, Sendable {
        var at: Double
        var ok: Bool?
        var detail: String?
        var date: Date { Date(timeIntervalSince1970: at) }
    }
    struct Event: Decodable, Equatable, Sendable {
        var at: Double
        var kind: String
        var detail: String
    }
    struct Setup: Decodable, Equatable, Sendable {
        var action: String
        var state: String       // running | done | failed
        var detail: String?
    }
    var installed: Bool
    var running: Bool
    var enabled: Bool
    var hotspotSsid: String
    var setup: Setup?
    var link: String?           // wifi | hotspot | offline (nil: helper not running)
    var phase: String?          // watching | joining | on_hotspot | switching_back | testing
    var ssid: String?
    var homeSsid: String?
    var passwordSaved: Bool?
    var wifiPower: Bool?
    var location: String?       // allowed | denied | not_determined | restricted
    var offlineSince: Double?
    var lastFailover: Mark?
    var lastSwitchBack: Mark?
    var lastTest: Mark?
    var lastError: Mark?
    var nextJoinAt: Double?
    var events: [Event]?
    var testPending: Bool?
}

protocol HotspotRelay: Sendable {
    func hotspotStatus() async throws -> HotspotStatus
    /// Only the keys given are changed; password "" clears the saved one.
    func setHotspot(enabled: Bool?, ssid: String?, password: String?) async throws -> HotspotStatus
    func testHotspot() async throws -> HotspotStatus
    func startHotspotSetup() async throws -> HotspotStatus
}

extension CompanionClient: HotspotRelay {
    func hotspotStatus() async throws -> HotspotStatus {
        try HermesClient.decoder.decode(HotspotStatus.self, from: try await rawRequest("GET", "/hermes/hotspot"))
    }

    func setHotspot(enabled: Bool?, ssid: String?, password: String?) async throws -> HotspotStatus {
        var body: [String: Any] = [:]
        if let enabled { body["enabled"] = enabled }
        if let ssid { body["hotspot_ssid"] = ssid }
        if let password { body["password"] = password }
        let data = try await rawRequest("POST", "/hermes/hotspot", body: try JSONSerialization.data(withJSONObject: body))
        return try HermesClient.decoder.decode(HotspotStatus.self, from: data)
    }

    func testHotspot() async throws -> HotspotStatus {
        try HermesClient.decoder.decode(HotspotStatus.self, from: try await rawRequest("POST", "/hermes/hotspot/test", body: Data("{}".utf8)))
    }

    func startHotspotSetup() async throws -> HotspotStatus {
        try HermesClient.decoder.decode(HotspotStatus.self, from: try await rawRequest("POST", "/hermes/hotspot/setup", body: Data("{}".utf8)))
    }
}

@MainActor
@Observable
final class HotspotController {
    static let shared = HotspotController()

    private(set) var status: HotspotStatus?
    private(set) var error: String?
    /// The relay has no /hermes/hotspot yet (it needs restarting).
    private(set) var relayOutdated = false
    /// "save" | "test" | "setup" while one runs.
    private(set) var busy: String?
    /// The result of the last save / test / setup, in plain words.
    private(set) var message: String?
    private(set) var messageFailed = false

    /// Seconds between polls while a test or setup runs. Tests set 0.
    @ObservationIgnored var followInterval: Double = 1.5
    @ObservationIgnored private var relayProvider: @MainActor () -> HotspotRelay? = { nil }
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func start(relay: @escaping @MainActor () -> HotspotRelay?) { relayProvider = relay }
    func startForTests(relay: HotspotRelay) { relayProvider = { relay } }

    // MARK: Derived

    var installed: Bool { status?.installed == true }
    var running: Bool { status?.running == true }

    /// "On Wi-Fi (Hotel)", "On your iPhone hotspot", "Offline", …
    var stateLine: String {
        guard let s = status else { return relayOutdated ? "The Hermes relay on this Mac needs restarting." : (error ?? "Connecting to Hermes…") }
        if !s.installed { return "Not set up" }
        if !s.running { return "The network helper isn't running" }
        switch s.phase {
        case "joining": return "Wi-Fi isn't working — joining \(s.hotspotSsid)…"
        case "switching_back": return "Wi-Fi is back — switching to \(s.homeSsid ?? "it")…"
        case "testing": return "Testing the hotspot…"
        default: break
        }
        switch s.link {
        case "wifi": return s.ssid.map { "On Wi-Fi (\($0))" } ?? "On Wi-Fi"
        case "hotspot": return s.phase == "on_hotspot" ? "On your iPhone hotspot (Wi-Fi isn't working)" : "On your iPhone hotspot"
        case "offline": return s.offlineSince.map { "Offline since \(Self.time($0))" } ?? "Offline"
        default: return "Unknown"
        }
    }

    var stateSymbol: String {
        switch status?.link {
        case "wifi": "wifi"
        case "hotspot": "personalhotspot"
        case "offline": "wifi.exclamationmark"
        default: "wifi.slash"
        }
    }

    /// Network names are hidden from the helper (Location Services off or not allowed for it).
    var namesHidden: Bool { running && status?.location != "allowed" }

    static func time(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Actions

    func poll() async {
        guard let relay = relayProvider() else {
            status = nil
            error = "Not connected to Hermes."
            return
        }
        do {
            status = try await relay.hotspotStatus()
            error = nil
            relayOutdated = false
        } catch HermesError.http(404, _) {
            relayOutdated = true
            status = nil
        } catch CompanionError.relayOutdated {
            relayOutdated = true
            status = nil
        } catch {
            self.error = AppModel.friendly(error)
        }
    }

    /// Saves the toggle / name / password. `password` nil = leave the saved one; "" = clear it.
    func save(enabled: Bool? = nil, ssid: String? = nil, password: String? = nil) async {
        await run("save") { relay in
            let s = try await relay.setHotspot(enabled: enabled, ssid: ssid, password: password)
            self.status = s
            if let password { return password.isEmpty ? "Password removed." : "Saved. The password is in your login Keychain." }
            return nil
        }
    }

    /// Joins the hotspot, checks the internet answers, and comes back to Wi-Fi.
    func test() async {
        let started = now().timeIntervalSince1970
        await run("test") { relay in
            self.status = try await relay.testHotspot()
            var waited = 0.0
            // The helper picks the request up within 5 s; a test takes up to ~70 s when the hotspot is
            // slow to appear (join, verify, switch back).
            while waited < 150 {
                try? await Task.sleep(for: .seconds(self.followInterval))
                waited += max(self.followInterval, 0.01)
                guard let s = try? await relay.hotspotStatus() else { continue }
                self.status = s
                if let t = s.lastTest, t.at >= started - 1, s.phase == "watching" || s.phase == "on_hotspot" {
                    self.messageFailed = t.ok != true
                    return t.detail ?? (t.ok == true ? "The hotspot works." : "The test failed.")
                }
            }
            self.messageFailed = true
            return "The test didn't finish. Check the status below."
        }
    }

    /// Builds and starts the helper (no administrator prompt). Takes a minute the first time.
    func setUp() async {
        await run("setup") { relay in
            self.status = try await relay.startHotspotSetup()
            var waited = 0.0
            while self.status?.setup?.state == "running", waited < 660 {
                try? await Task.sleep(for: .seconds(self.followInterval))
                waited += max(self.followInterval, 0.01)
                if let s = try? await relay.hotspotStatus() { self.status = s }
            }
            let job = self.status?.setup
            self.messageFailed = job?.state != "done"
            return job?.state == "done" ? "The network helper is running." : (job?.detail ?? "Setup didn't finish.")
        }
    }

    private func run(_ what: String, _ body: @escaping (HotspotRelay) async throws -> String?) async {
        guard busy == nil else { return }
        guard let relay = relayProvider() else {
            message = "Not connected to Hermes."
            messageFailed = true
            return
        }
        busy = what
        message = nil
        messageFailed = false
        defer { busy = nil }
        do {
            message = try await body(relay)
        } catch HermesError.http(let code, let detail) {
            messageFailed = true
            message = code == 404 ? "The Hermes relay on this Mac needs restarting first." : (detail ?? "The relay answered \(code).")
        } catch CompanionError.relayOutdated {
            messageFailed = true
            message = "The Hermes relay on this Mac needs restarting first."
        } catch {
            messageFailed = true
            message = AppModel.friendly(error)
        }
    }
}
