import Foundation
import IOKit.pwr_mgt
import Observation
import AppKit

// Keep Mac awake (Otto for Mac).
//
// Layer 1, in the app and App Sandbox-safe: an IOKit power assertion
// (kIOPMAssertPreventUserIdleSystemSleep) held only while it's needed — while agents work or until a
// timer ends — and released when they go idle, when the relay can't be reached, and when Otto quits.
// It keeps an open Mac from idle-sleeping; it can't stop a closed lid from sleeping the Mac.
//
// Layer 2, lid-closed mode: a visible toggle that asks the user's own Hermes companion (the relay,
// relay/awake.py, POST /hermes/awake) to keep the Mac awake with the lid closed. The app itself makes
// no system changes and never asks for administrator rights. The first time the toggle is turned on,
// Otto asks the relay to set itself up (POST /hermes/awake/setup); the relay, outside the sandbox, shows
// the standard macOS administrator prompt. "Undo lid-closed setup" calls POST /hermes/awake/undo.
//
// Everything lives in Otto's own window, Settings and main menu; there is no menu bar (status) item.
//
// The timer model (days/hours/minutes, add time, end early) follows Insomnia by Krish Garg
// (https://github.com/krishhgg/Insomnia, MIT); see THIRD_PARTY_NOTICES.md.

/// Holds one power assertion. Tests use a fake.
@MainActor
protocol PowerAssertionHolding: AnyObject {
    var isHeld: Bool { get }
    /// Takes the assertion if not already held. False if macOS refused it.
    @discardableResult func acquire(reason: String) -> Bool
    func release()
}

@MainActor
final class IOKitPowerAssertion: PowerAssertionHolding {
    private var id: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private(set) var isHeld = false

    @discardableResult
    func acquire(reason: String) -> Bool {
        if isHeld { return true }
        var newID = IOPMAssertionID(kIOPMNullAssertionID)
        let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &newID)
        guard r == kIOReturnSuccess else { return false }
        id = newID
        isHeld = true
        return true
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        id = IOPMAssertionID(kIOPMNullAssertionID)
        isHeld = false
    }
}

enum KeepAwakeMode: Equatable, Codable, Sendable {
    case off
    case whileWorking
    case until(Date)

    var isTimer: Bool { if case .until = self { true } else { false } }
    var endDate: Date? { if case .until(let d) = self { d } else { nil } }
}

/// What the relay's GET/POST /hermes/awake returns (relay/awake.py `status()`), decoded with
/// HermesClient.decoder (snake_case → camelCase).
struct AwakeStatus: Decodable, Equatable, Sendable {
    struct Battery: Decodable, Equatable, Sendable {
        var percent: Int?
        var onBattery: Bool?
        var charging: Bool?
    }
    struct Agents: Decodable, Equatable, Sendable {
        var chats: Int?
        var kanban: Int?
    }
    struct Last: Decodable, Equatable, Sendable {
        var at: Double?
        var reason: String?
    }
    /// The one-time setup / undo job the relay runs (POST /hermes/awake/setup|undo).
    struct Setup: Decodable, Equatable, Sendable {
        var action: String      // setup | undo
        var state: String       // running | done | cancelled | failed
        var detail: String?
        var at: Double?
    }
    var installed: Bool
    var setup: Setup?
    var mode: String
    var until: Double?
    var holding: Bool
    var holdUntil: Double?
    var sleepDisabled: Bool?
    var lowPowerByUs: Bool?
    var agentsWorking: Bool
    var agents: Agents?
    var battery: Battery?
    var thermal: String?
    var last: Last?
}

/// The relay calls. A protocol so tests can fake the relay.
protocol AwakeRelay: Sendable {
    func awakeStatus() async throws -> AwakeStatus
    func setAwake(mode: String, until: Date?) async throws -> AwakeStatus
    /// Starts the relay's one-time lid-closed setup ("setup") or its undo ("undo").
    func startAwakeSetup(_ action: String) async throws -> AwakeStatus
    /// Older relays without /hermes/awake: chats with a turn running.
    func runningCount() async throws -> Int
}

extension CompanionClient: AwakeRelay {
    func awakeStatus() async throws -> AwakeStatus {
        try HermesClient.decoder.decode(AwakeStatus.self, from: try await rawRequest("GET", "/hermes/awake"))
    }

    func setAwake(mode: String, until: Date?) async throws -> AwakeStatus {
        var body: [String: Any] = ["mode": mode]
        if let until { body["until"] = until.timeIntervalSince1970 }
        let data = try await rawRequest("POST", "/hermes/awake", body: try JSONSerialization.data(withJSONObject: body))
        return try HermesClient.decoder.decode(AwakeStatus.self, from: data)
    }

    func startAwakeSetup(_ action: String) async throws -> AwakeStatus {
        let data = try await rawRequest("POST", "/hermes/awake/\(action)", body: Data("{}".utf8))
        return try HermesClient.decoder.decode(AwakeStatus.self, from: data)
    }

    func runningCount() async throws -> Int { try await runningSessions().count }
}

@MainActor
@Observable
final class KeepAwakeController {
    static let shared = KeepAwakeController()

    /// What John picked. Persisted; a timer that ended while Otto was closed reads back as off.
    private(set) var mode: KeepAwakeMode = .off
    /// Lid-closed mode wanted (layer 2). Persisted.
    private(set) var lidClosedWanted = false
    /// nil = unknown (no relay answer yet, or the last poll failed).
    private(set) var agentsWorking: Bool?
    private(set) var workingCount = 0
    /// Last relay status (nil on an old relay or before the first poll).
    private(set) var relay: AwakeStatus?
    private(set) var relayError: String?
    /// The relay has no /hermes/awake (older relay): lid-closed mode unavailable.
    private(set) var relayOutdated = false
    /// The setup / undo job in progress ("setup" | "undo"), nil when idle.
    private(set) var setupBusy: String?
    /// What happened with the last setup / undo, in plain words ("Cancelled. Nothing was changed.").
    private(set) var setupMessage: String?
    private(set) var setupFailed = false
    /// Seconds between status polls while the admin prompt is up. Tests set 0.
    @ObservationIgnored var setupPollInterval: Double = 1.5

    @ObservationIgnored let assertion: PowerAssertionHolding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var relayProvider: @MainActor () -> AwakeRelay? = { nil }
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    static let reason = "Otto: Keep Mac awake (Hermes agents)"

    enum Keys {
        static let mode = "keepAwake.mode"
        static let lid = "keepAwake.lidClosed"
        /// Gone: the old menu bar item's setting, removed at launch.
        static let menuBar = "keepAwake.menuBar"
    }

    init(assertion: PowerAssertionHolding = IOKitPowerAssertion(), now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        self.assertion = assertion
        self.now = now
        self.defaults = defaults
        defaults.removeObject(forKey: Keys.menuBar)
        lidClosedWanted = defaults.bool(forKey: Keys.lid)
        if let data = defaults.data(forKey: Keys.mode), let m = try? JSONDecoder().decode(KeepAwakeMode.self, from: data) {
            mode = m
        }
        if let end = mode.endDate, end <= now() { mode = .off; save() }
    }

    // MARK: Derived state

    /// Whether the assertion should be held right now.
    var wantsHold: Bool {
        switch mode {
        case .off: false
        case .whileWorking: agentsWorking == true
        case .until(let end): end > now()
        }
    }

    var isHolding: Bool { assertion.isHeld }
    var lidClosedInstalled: Bool { relay?.installed == true }
    var lidClosedActive: Bool { relay?.holding == true }

    // MARK: Lifecycle

    /// Starts polling the relay and releases the assertion when Otto quits.
    func start(relay: @escaping @MainActor () -> AwakeRelay?) {
        relayProvider = relay
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.shutdown() }
            }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    /// Quit: release now (macOS would also drop it with the process).
    func shutdown() {
        pollTask?.cancel()
        assertion.release()
    }

    /// Tests: a relay without the poll loop or the quit observer.
    func startForTests(relay: AwakeRelay) {
        relayProvider = { relay }
    }

    var pollInterval: Double {
        switch mode {
        case .off: lidClosedWanted ? 30 : 60
        case .whileWorking: 10
        case .until: 30
        }
    }

    // MARK: Actions

    func setMode(_ new: KeepAwakeMode) {
        if let end = new.endDate, end <= now() { mode = .off } else { mode = new }
        save()
        evaluate()
        if lidClosedWanted { Task { await pushLidClosed() } }
    }

    func startTimer(seconds: TimeInterval) {
        guard seconds >= 60 else { return }
        setMode(.until(now().addingTimeInterval(seconds)))
    }

    /// Adds time to a running timer (or starts one).
    func addTime(_ seconds: TimeInterval) {
        let base = max(mode.endDate ?? now(), now())
        setMode(.until(base.addingTimeInterval(seconds)))
    }

    func endEarly() { setMode(.off) }

    /// Turning it on before the relay is set up starts the one-time setup (one macOS admin prompt),
    /// then turns it on once that succeeded.
    func setLidClosed(_ on: Bool) {
        if on, relay?.installed == false, !relayOutdated {
            guard setupBusy == nil else { return }
            Task { await runSetup("setup") }
            return
        }
        lidClosedWanted = on
        defaults.set(on, forKey: Keys.lid)
        if on, mode == .off { mode = .whileWorking; save() }
        evaluate()
        Task { await pushLidClosed() }
    }

    // MARK: One-time setup (the relay shows the macOS administrator prompt)

    /// "setup" or "undo". Starts the job on the relay, then follows it until John answers the prompt.
    func runSetup(_ action: String) async {
        guard setupBusy == nil else { return }
        guard let client = relayProvider() else {
            setupMessage = "Not connected to Hermes."
            setupFailed = true
            return
        }
        setupBusy = action
        setupFailed = false
        setupMessage = action == "setup"
            ? "Approve the prompt on this Mac with Touch ID or your password…"
            : "Approve the prompt on this Mac to undo the setup…"
        defer { setupBusy = nil }
        do {
            apply(try await client.startAwakeSetup(action))
            var waited = 0.0
            while relay?.setup?.state == "running", waited < 660 {
                try? await Task.sleep(for: .seconds(setupPollInterval))
                waited += max(setupPollInterval, 0.01)
                if let s = try? await client.awakeStatus() { apply(s) }
            }
        } catch HermesError.http(let code, let detail) {
            setupFailed = true
            setupMessage = code == 404 ? "The Hermes relay on this Mac needs restarting first." : (detail ?? "The relay answered \(code).")
            return
        } catch CompanionError.relayOutdated {
            setupFailed = true
            setupMessage = "The Hermes relay on this Mac needs restarting first."
            return
        } catch {
            setupFailed = true
            setupMessage = AppModel.friendly(error)
            return
        }
        let job = relay?.setup
        switch job?.state {
        case "done":
            setupFailed = false
            if action == "setup" {
                setupMessage = "Done. Otto can now keep this Mac awake with the lid closed."
                setupBusy = nil
                setLidClosed(true)
            } else {
                setupMessage = "Lid-closed setup removed. This Mac sleeps normally with the lid closed."
                lidClosedWanted = false
                defaults.set(false, forKey: Keys.lid)
            }
        case "cancelled":
            setupFailed = false
            setupMessage = "Cancelled. Nothing was changed."
        case "running":
            setupFailed = true
            setupMessage = "Still waiting for the prompt on this Mac."
        default:
            setupFailed = true
            setupMessage = job?.detail ?? "Setup didn't finish."
        }
    }

    // MARK: Relay

    func poll() async {
        guard let client = relayProvider() else {
            relayFailed("Not connected to Hermes.")
            return
        }
        if relayOutdated {
            do {
                let n = try await client.runningCount()
                relayError = nil
                updateAgents(working: n > 0, count: n)
            } catch {
                relayFailed(AppModel.friendly(error))
            }
            return
        }
        do {
            let s = try await client.awakeStatus()
            apply(s)
        } catch CompanionError.relayOutdated {
            relayOutdated = true
            relay = nil
            await poll()
        } catch {
            relayFailed(AppModel.friendly(error))
        }
    }

    func apply(_ s: AwakeStatus) {
        relay = s
        relayError = nil
        relayOutdated = false
        updateAgents(working: s.agentsWorking, count: (s.agents?.chats ?? 0) + (s.agents?.kanban ?? 0))
        // The relay ended lid-closed mode itself (timer, battery, heat, backstop): say why under the toggle.
        if lidClosedWanted, s.mode == "off", mode != .off, let reason = s.last?.reason, reason != "turned off" {
            lidClosedNote = reason
        }
    }

    /// Why the relay last ended lid-closed mode (battery, heat, timer), shown under the toggle.
    private(set) var lidClosedNote: String?

    func updateAgents(working: Bool, count: Int) {
        agentsWorking = working
        workingCount = count
        evaluate()
    }

    /// No answer from the relay: we can't tell whether agents work, so let go (a timer keeps holding).
    func relayFailed(_ message: String) {
        relayError = message
        agentsWorking = nil
        workingCount = 0
        evaluate()
    }

    /// Takes or releases the assertion to match `wantsHold`; ends an expired timer.
    func evaluate() {
        if let end = mode.endDate, end <= now() {
            mode = .off
            save()
        }
        if wantsHold { assertion.acquire(reason: Self.reason) } else { assertion.release() }
    }

    /// Sends the current plan to the relay (lid-closed mode). Off when the toggle is off.
    func pushLidClosed() async {
        guard let client = relayProvider(), !relayOutdated else { return }
        let (m, until): (String, Date?) = {
            guard lidClosedWanted else { return ("off", nil) }
            switch mode {
            case .off: return ("off", nil)
            case .whileWorking: return ("working", nil)
            case .until(let d): return ("timer", d)
            }
        }()
        if m != "off", relay?.installed == false { return }  // setup first; nothing to change
        do {
            let s = try await client.setAwake(mode: m, until: until)
            lidClosedNote = nil
            apply(s)
        } catch HermesError.http(let code, let detail) {
            relayError = detail ?? "The relay answered \(code)."
            if code == 409 { try? await refreshRelayOnly(client) }
        } catch {
            relayError = AppModel.friendly(error)
        }
    }

    private func refreshRelayOnly(_ client: AwakeRelay) async throws {
        apply(try await client.awakeStatus())
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mode) { defaults.set(data, forKey: Keys.mode) }
    }
}
