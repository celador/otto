import Foundation

/// One shell on the Hermes host, reached over the relay's `/hermes/terminal` WebSocket
/// (relay/terminal.py). Bytes from the shell go to `onOutput`; keyboard bytes go out with `send`.
/// A dropped connection reconnects with the session id for up to `reattachWindow` seconds (the relay
/// keeps the shell that long and replays recent output), so a network blip or sleep keeps the shell.
final class RelayTerminalConnection: @unchecked Sendable {
    enum State: Equatable { case connecting, connected, reconnecting, ended(String) }

    struct Endpoint: Sendable {
        var relay: URL
        var apiKey: String
    }

    /// Hand-off target; set before `start()`.
    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int) -> Void)?
    var onState: (@Sendable (State) -> Void)?

    let endpoint: Endpoint
    let cwd: String?
    static let reattachWindow: TimeInterval = 25

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var sessionID: String?
    private var size: (cols: Int, rows: Int) = (80, 24)
    private var closed = false
    private var generation = 0
    private var droppedAt: Date?
    private let urlSession: URLSession
    private let outbox: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    private let outboxStream: AsyncStream<URLSessionWebSocketTask.Message>
    private var sender: Task<Void, Never>?

    init(endpoint: Endpoint, cwd: String?) {
        self.endpoint = endpoint
        self.cwd = cwd
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 3600 * 24
        urlSession = URLSession(configuration: c)
        (outboxStream, outbox) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit { outbox.finish() }

    /// The relay's WebSocket URL for this shell.
    static func url(relay: URL, cwd: String?, cols: Int, rows: Int, session: String?) -> URL? {
        guard var c = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/hermes/terminal"
        var q = [URLQueryItem(name: "cols", value: String(cols)), URLQueryItem(name: "rows", value: String(rows))]
        if let cwd, !cwd.isEmpty { q.append(URLQueryItem(name: "cwd", value: cwd)) }
        if let session { q.append(URLQueryItem(name: "session", value: session)) }
        c.queryItems = q
        return c.url
    }

    func start(cols: Int, rows: Int) {
        lock.withLock { size = (max(cols, 2), max(rows, 2)) }
        if sender == nil {
            let stream = outboxStream
            sender = Task { [weak self] in
                for await msg in stream {
                    guard let task = self?.lock.withLock({ self?.task }) else { continue }
                    try? await task.send(msg)
                }
            }
        }
        connect()
    }

    private func connect() {
        let (sid, cols, rows, gen): (String?, Int, Int, Int) = lock.withLock {
            generation += 1
            return (sessionID, size.cols, size.rows, generation)
        }
        guard let url = Self.url(relay: endpoint.relay, cwd: cwd, cols: cols, rows: rows, session: sid) else {
            onState?(.ended("Bad relay address"))
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        let t = urlSession.webSocketTask(with: req)
        t.maximumMessageSize = 4 << 20
        lock.withLock { task = t }
        onState?(sid == nil ? .connecting : .reconnecting)
        t.resume()
        receive(t, gen)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let d)):
                self.onOutput?(d)
                self.receive(t, gen)
            case .success(.string(let s)):
                self.control(s)
                self.receive(t, gen)
            case .success:
                self.receive(t, gen)
            case .failure(let error):
                self.dropped(gen, error)
            }
        }
    }

    private func control(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "hello":
            lock.withLock {
                sessionID = obj["session"] as? String
                droppedAt = nil
            }
            onState?(.connected)
        case "exit":
            lock.withLock { closed = true }
            onExit?((obj["code"] as? Int) ?? 0)
            onState?(.ended("Shell exited"))
        case "error":
            lock.withLock { closed = true }
            onState?(.ended((obj["detail"] as? String) ?? "Terminal error"))
        default: break
        }
    }

    private func dropped(_ gen: Int, _ error: Error) {
        let (isClosed, current, hasSession, since): (Bool, Bool, Bool, Date) = lock.withLock {
            if droppedAt == nil { droppedAt = Date() }
            return (closed, gen == generation, sessionID != nil, droppedAt!)
        }
        guard !isClosed, current else { return }
        let code = (lock.withLock { task })?.closeCode
        if code == .policyViolation || (error as? URLError)?.code == .userAuthenticationRequired {
            onState?(.ended("Relay refused the connection"))
            return
        }
        guard Date().timeIntervalSince(since) < Self.reattachWindow else {
            lock.withLock { closed = true }
            onState?(.ended(hasSession ? "Connection lost" : "Can't reach the relay"))
            return
        }
        onState?(.reconnecting)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.lock.withLock({ self.closed }) else { return }
            self.connect()
        }
    }

    func send(_ data: Data) {
        outbox.yield(.data(data))
    }

    func resize(cols: Int, rows: Int) {
        let changed: Bool = lock.withLock {
            let new = (max(cols, 2), max(rows, 2))
            defer { size = new }
            return size != new
        }
        guard changed else { return }
        outbox.yield(.string(#"{"type":"resize","cols":\#(max(cols, 2)),"rows":\#(max(rows, 2))}"#))
    }

    /// Closing the tab: the relay kills the shell's process group at once.
    func close() {
        let t: URLSessionWebSocketTask? = lock.withLock {
            closed = true
            return task
        }
        guard let t else { return }
        t.send(.string(#"{"type":"close"}"#)) { _ in
            t.cancel(with: .normalClosure, reason: nil)
        }
        sender?.cancel()
    }
}
