import Foundation

/// Pairs Otto for Mac with the Hermes server on the same Mac. The Mac App Store build is
/// sandboxed and can't read ~/.hermes/.env, so the relay hands over the gateway URL + key after
/// the person at the Mac clicks Allow in a dialog the relay shows (relay/macpair.py):
/// POST /macpair/start → {id, code}; GET /macpair/poll?id= → pending | approved (+ key, once) |
/// denied | expired; POST /macpair/cancel?id= when Otto stops waiting (closes the dialog). Plain Foundation so the iOS test target can exercise it.
struct LocalPairing: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct Start: Decodable, Equatable, Sendable {
        let id: String
        let code: String
        var expiresIn: Int?
        /// "123 456", the way the dialog shows it.
        var displayCode: String { code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code }
    }

    struct Result: Equatable, Sendable {
        let gateway: URL
        let relay: URL?
        let apiKey: String
    }

    enum Failure: LocalizedError, Equatable {
        case noRelay, denied, expired, busy, server(String)
        var errorDescription: String? {
            switch self {
            case .noRelay: "Hermes isn't running on this Mac (no relay on port 8650). Start Hermes, or enter a server below."
            case .denied: "Not allowed. Click Use This Mac to try again."
            case .expired: "The request timed out before anyone clicked Allow. Try again."
            case .busy: "A connect request is already waiting on this Mac's screen."
            case .server(let s): s
            }
        }
    }

    static let defaultRelay = URL(string: "http://127.0.0.1:8650")!

    var relay: URL = Self.defaultRelay
    var name: String = "Otto"
    var pollInterval: Duration = .seconds(1)
    var timeout: Duration = .seconds(150)
    var fetch: Fetch = { try await URLSession.shared.data(for: $0) }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    func start() async throws -> Start {
        var req = URLRequest(url: relay.appending(path: "macpair/start"), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, resp) = try await call(req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try Self.decoder.decode(Start.self, from: data)
        case 404: throw Failure.server("The relay on this Mac is too old to pair. Update Otto's relay (hermes-ios/relay) and restart it.")
        case 409: throw Failure.busy
        default: throw Failure.server(Self.detail(data) ?? "The relay refused to pair.")
        }
    }

    private struct Poll: Decodable {
        let status: String
        var gateway: String?
        var relay: String?
        var apiKey: String?
    }

    /// One poll: nil while the dialog is still up.
    func poll(_ id: String) async throws -> Result? {
        var c = URLComponents(url: relay.appending(path: "macpair/poll"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        let (data, resp) = try await call(URLRequest(url: c.url!, timeoutInterval: 10))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.server(Self.detail(data) ?? "The relay stopped answering.")
        }
        let p = try Self.decoder.decode(Poll.self, from: data)
        switch p.status {
        case "pending": return nil
        case "approved":
            guard let g = p.gateway.flatMap(URL.init(string:)), let key = p.apiKey, !key.isEmpty else {
                throw Failure.server("The relay approved but sent no key.")
            }
            return Result(gateway: g, relay: p.relay.flatMap(URL.init(string:)), apiKey: key)
        case "denied": throw Failure.denied
        default: throw Failure.expired
        }
    }

    /// Starts a pairing, reports the code (so the window can show the same digits as the dialog)
    /// and waits for the click. Cancelling the task stops waiting.
    func pair(onCode: @Sendable (Start) async -> Void) async throws -> Result {
        let s = try await start()
        await onCode(s)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                if let r = try await poll(s.id) { return r }
                try await Task.sleep(for: pollInterval)
            }
        } catch is CancellationError {
            cancel(s.id)
            throw CancellationError()
        }
        cancel(s.id)
        throw Failure.expired
    }

    /// Drops the pairing on the relay and closes its dialog. Detached: the caller's task is
    /// usually the one being cancelled, and that would cancel this request too.
    func cancel(_ id: String) {
        var c = URLComponents(url: relay.appending(path: "macpair/cancel"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        var req = URLRequest(url: c.url!, timeoutInterval: 5)
        req.httpMethod = "POST"
        let fetch = self.fetch
        Task.detached { _ = try? await fetch(req) }
    }

    private func call(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await fetch(req)
        } catch let e as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                                           .timedOut, .notConnectedToInternet].contains(e.code) {
            throw Failure.noRelay
        }
    }

    private static func detail(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
    }
}
