import Foundation
import Testing
@testable import Hermes

/// Otto for Mac's pairing with the relay on the same Mac (relay/macpair.py), against a fake relay.
struct LocalPairingTests {
    final class FakeRelay: @unchecked Sendable {
        let lock = NSLock()
        var polls: [String]           // statuses handed out in order, the last one repeats
        var startStatus = 200
        var startBodies: [[String: Any]] = []
        var pollCount = 0
        var throwOnStart: URLError?
        var cancels = 0

        init(polls: [String]) { self.polls = polls }

        func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) { try respond(req) }
        var cancelCount: Int { lock.withLock { cancels } }

        private func respond(_ req: URLRequest) throws -> (Data, URLResponse) {
            lock.lock(); defer { lock.unlock() }
            let url = req.url!
            func resp(_ code: Int, _ json: Any) -> (Data, URLResponse) {
                (try! JSONSerialization.data(withJSONObject: json),
                 HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            switch url.path {
            case "/macpair/start":
                if let e = throwOnStart { throw e }
                #expect(req.httpMethod == "POST")
                startBodies.append((try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:])
                return startStatus == 200
                    ? resp(200, ["id": "pid1", "code": "123456", "expires_in": 600])
                    : resp(startStatus, ["detail": "nope"])
            case "/macpair/poll":
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "pid1")
                let status = polls[min(pollCount, polls.count - 1)]
                pollCount += 1
                if status == "approved" {
                    return resp(200, ["status": "approved", "gateway": "http://127.0.0.1:8642",
                                      "relay": "http://127.0.0.1:8650", "api_key": "KEY"])
                }
                return resp(200, ["status": status])
            case "/macpair/cancel":
                #expect(req.httpMethod == "POST")
                cancels += 1
                return resp(200, ["ok": true])
            default:
                return resp(404, ["detail": "not found"])
            }
        }
    }

    func pairing(_ relay: FakeRelay) -> LocalPairing {
        var p = LocalPairing()
        p.pollInterval = .milliseconds(1)
        p.timeout = .seconds(5)
        p.fetch = { try await relay.fetch($0) }
        return p
    }

    @Test func approvedAfterPending() async throws {
        let relay = FakeRelay(polls: ["pending", "pending", "approved"])
        let shown = CodeBox()
        let r = try await pairing(relay).pair { s in shown.set(s.displayCode) }
        #expect(shown.value == "123 456")
        #expect(r == LocalPairing.Result(gateway: URL(string: "http://127.0.0.1:8642")!,
                                         relay: URL(string: "http://127.0.0.1:8650"), apiKey: "KEY"))
        #expect(relay.pollCount == 3)
        #expect(relay.startBodies.first?["name"] as? String == "Otto")
    }

    @Test func deniedAndExpired() async {
        await #expect(throws: LocalPairing.Failure.denied) {
            try await pairing(FakeRelay(polls: ["pending", "denied"])).pair { _ in }
        }
        await #expect(throws: LocalPairing.Failure.expired) {
            try await pairing(FakeRelay(polls: ["expired"])).pair { _ in }
        }
    }

    @Test func timesOutWhileNobodyClicks() async {
        var p = pairing(FakeRelay(polls: ["pending"]))
        p.timeout = .milliseconds(50)
        await #expect(throws: LocalPairing.Failure.expired) { try await p.pair { _ in } }
    }

    @Test func relayMissingOrBusy() async {
        let down = FakeRelay(polls: ["pending"])
        down.throwOnStart = URLError(.cannotConnectToHost)
        await #expect(throws: LocalPairing.Failure.noRelay) { try await pairing(down).pair { _ in } }
        let busy = FakeRelay(polls: ["pending"])
        busy.startStatus = 409
        await #expect(throws: LocalPairing.Failure.busy) { try await pairing(busy).pair { _ in } }
        let refused = FakeRelay(polls: ["pending"])
        refused.startStatus = 403
        await #expect(throws: LocalPairing.Failure.server("nope")) { try await pairing(refused).pair { _ in } }
    }

    @Test func cancellingStopsWaiting() async {
        let relay = FakeRelay(polls: ["pending"])
        var p = pairing(relay)
        p.pollInterval = .milliseconds(5)
        let task = Task { try await p.pair { _ in } }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<100 where relay.cancelCount == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(relay.cancelCount == 1)   // the relay closes the dialog
    }

    @Test func approvedWithoutKeyIsAnError() async throws {
        let relay = FakeRelay(polls: ["approved"])
        var p = pairing(relay)
        p.fetch = { req in
            if req.url!.path == "/macpair/poll" {
                return (Data(#"{"status":"approved","gateway":"http://127.0.0.1:8642"}"#.utf8),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return try await relay.fetch(req)
        }
        await #expect(throws: LocalPairing.Failure.self) { try await p.pair { _ in } }
    }

    final class CodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: String?
        func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return v }
    }
}
