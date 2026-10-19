import Foundation

// MARK: - Weft auto-config: no URL/token typing, ever
//
// The Hermes host Otto is connected to already knows the Weft gateway and holds an operator token.
// `GET /hermes/weft/config` on the relay (relay/weft_config.py) returns the gateway URL and a
// human-scope token it minted once for John. Otto saves that into the Weft Keychain item tagged
// `.auto`. A connection typed into Weft settings (Advanced) is tagged `.manual` and always wins.

/// `GET /hermes/weft/config`.
struct WeftAutoConfig: Decodable, Equatable, Sendable {
    var url: String
    var token: String
    /// "human" (approve / undo / pause / message) or "observe" (read-only fallback).
    var scope: String
    var principal: String?
}

enum WeftAutoFailure: Equatable, Sendable {
    case notConnected          // Otto isn't connected to a Hermes host
    case hostUnreachable       // the relay didn't answer
    case relayOutdated         // relay has no /hermes/weft/config yet
    case noToken               // host has no admin or observer token
    case gatewayUnreachable    // host can't reach the Weft gateway
    case other(String)

    var message: String {
        switch self {
        case .notConnected: "Otto isn't connected to your Hermes host."
        case .hostUnreachable: "Can't reach your Hermes host."
        case .relayOutdated: "Your Hermes host's relay needs restarting to connect Weft."
        case .noToken: "Your Hermes host has no Weft token."
        case .gatewayUnreachable: "Your Hermes host can't reach the Weft gateway."
        case .other(let s): s
        }
    }

    nonisolated static func from(_ error: Error) -> WeftAutoFailure {
        switch error {
        case CompanionError.relayOutdated: return .relayOutdated
        case HermesError.http(503, _): return .noToken
        case HermesError.http(502, _): return .gatewayUnreachable
        case HermesError.http(_, let detail?): return .other(detail)
        case HermesError.unauthorized: return .other("Your Hermes host rejected Otto's key.")
        case let u as URLError:
            switch u.code {
            case .cancelled: return .other("Cancelled.")
            default: return .hostUnreachable
            }
        default: return .other(error.localizedDescription)
        }
    }
}

enum WeftAutoStatus: Equatable, Sendable {
    case idle
    case fetching
    case ok(scope: String)
    case failed(WeftAutoFailure)
}

extension WeftAutoConfig {
    /// What to store, given what the Keychain holds now. nil = keep the current config.
    /// Manual config wins over anything the host offers; an auto config follows the host.
    nonisolated static func resolve(current: WeftConfig?, offered: WeftAutoConfig) -> WeftConfig? {
        if let current, current.source == .manual { return nil }
        guard let url = WeftClient.normalizedURL(offered.url), !offered.token.isEmpty else { return nil }
        let next = WeftConfig(baseURL: url, token: offered.token, source: .auto, scope: offered.scope)
        return next == current ? nil : next
    }
}
