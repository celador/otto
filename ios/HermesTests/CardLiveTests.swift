import Foundation
import Testing
@testable import Hermes

/// Running cards: the relay's live payload, the Now line, stall signals, the step trail, and the
/// card → worker-session link the watch view opens.
@MainActor
@Suite struct CardLiveTests {
    static let payload = """
    {"board": "otto", "now": 1000.0, "cards": {
      "t_2ede9e2d": {"run_id": 51, "run_started_at": 100, "heartbeat_at": 990, "worker_alive": true,
        "session_id": "20261018_030951_5e40de",
        "now": {"phrase": "Running tests", "tool": "terminal", "summary": "xcodebuild test -scheme Hermes",
                "wait": "long", "running": true, "since": 700.5, "started_at": 760.0},
        "trail": [{"phrase": "Merging", "state": "done", "at": 300}, {"phrase": "Running tests", "state": "running", "at": 700}],
        "said": {"text": "Now the tests.", "at": 699}, "last_activity_at": 760.0},
      "t_aaaaaaaa": {"run_id": 3, "run_started_at": 50, "worker_alive": false, "session_id": null, "now": null,
        "trail": [], "said": null, "last_activity_at": null, "future_field": {"x": 1}}
    }}
    """

    private func step(_ phrase: String = "Running tests", wait: String? = nil, running: Bool = true, since: Double = 0) -> CardLive.Step {
        CardLive.Step(phrase: phrase, tool: "terminal", summary: nil, wait: wait, running: running, since: since, startedAt: since)
    }

    // MARK: Decoding

    @Test func decodesCardIdsVerbatimAndToleratesNullsAndExtras() throws {
        let r = try CardLiveResponse.decode(Data(Self.payload.utf8))
        #expect(Set(r.cards.keys) == ["t_2ede9e2d", "t_aaaaaaaa"])  // not "t2ede9e2d" (snake-case key conversion)
        let a = try #require(r.cards["t_2ede9e2d"])
        #expect(a.sessionId == "20261018_030951_5e40de" && a.workerAlive == true && a.runId == 51)
        #expect(a.now?.phrase == "Running tests" && a.now?.running == true && a.now?.since == 700.5 && a.now?.startedAt == 760)
        #expect(a.trail.map(\.state) == ["done", "running"] && a.said?.text == "Now the tests.")
        let b = try #require(r.cards["t_aaaaaaaa"])
        #expect(b.sessionId == nil && b.now == nil && b.workerAlive == false && b.trail.isEmpty)
    }

    // MARK: Now line

    @Test func nowLineCountsFromTheStepGroupAndTicks() throws {
        let live = CardLive(runStartedAt: 0, sessionId: "s", now: step(since: 1000), lastActivityAt: 1030)
        let n = try #require(CardNow.of(live, now: Date(timeIntervalSince1970: 1130)))
        #expect(n.label(now: Date(timeIntervalSince1970: 1130)) == "Running tests · 2m")
        #expect(n.label(now: Date(timeIntervalSince1970: 1042)) == "Running tests · 42s")
    }

    @Test func finishedStepBecomesThinkingAfterAPause() {
        let live = CardLive(runStartedAt: 0, sessionId: "s", now: step(running: false, since: 1000), lastActivityAt: 1010)
        #expect(CardNow.of(live, now: Date(timeIntervalSince1970: 1040))?.phrase == "Running tests")   // just finished
        let later = CardNow.of(live, now: Date(timeIntervalSince1970: 1100))
        #expect(later?.phrase == "Thinking" && later?.since == Date(timeIntervalSince1970: 1010))
    }

    @Test func linkedButNoCallsYetIsStarting() {
        #expect(CardNow.of(CardLive(runStartedAt: 500, sessionId: "s"), now: .now)?.phrase == "Starting")
        #expect(CardNow.of(CardLive(runStartedAt: 500), now: .now) == nil)  // no session found: no line
        #expect(CardNow.of(nil, now: .now) == nil)
    }

    // MARK: Stall signals

    @Test func quietAfterFiveMinutesOfNoActivity() {
        let live = CardLive(runStartedAt: 0, workerAlive: true, sessionId: "s",
                            now: step("Reading code", running: false, since: 0), lastActivityAt: 1000)
        #expect(CardSignal.of(live, now: Date(timeIntervalSince1970: 1000 + 299)) == CardSignal.none)
        #expect(CardSignal.of(live, now: Date(timeIntervalSince1970: 1000 + 301)) == .quiet(minutes: 5))
        #expect(CardSignal.of(live, now: Date(timeIntervalSince1970: 1000 + 6 * 60 + 10)).label == "No activity for 6m")
    }

    @Test func heartbeatAloneIsNotActivity() {
        // Fresh heartbeat (999) but the transcript last moved at 100: still quiet.
        let live = CardLive(runStartedAt: 0, heartbeatAt: 999, workerAlive: true, sessionId: "s",
                            now: step("Editing code", running: true, since: 100), lastActivityAt: 100)
        #expect(CardSignal.of(live, now: Date(timeIntervalSince1970: 1000)) == .quiet(minutes: 15))
    }

    @Test func longStepsGetTwentyMinutes() {
        let live = CardLive(runStartedAt: 0, workerAlive: true, sessionId: "s",
                            now: step("Running tests", wait: "long", running: true, since: 0), lastActivityAt: 0)
        #expect(CardSignal.of(live, now: Date(timeIntervalSince1970: 19 * 60)) == CardSignal.none)
        #expect(CardSignal.of(live, now: Date(timeIntervalSince1970: 21 * 60)) == .quiet(minutes: 21))
        // Once the build finished, the normal 5-minute rule applies again.
        let done = CardLive(runStartedAt: 0, workerAlive: true, sessionId: "s",
                            now: step("Running tests", wait: "long", running: false, since: 0), lastActivityAt: 0)
        #expect(CardSignal.of(done, now: Date(timeIntervalSince1970: 6 * 60)) == .quiet(minutes: 6))
    }

    @Test func expectedWaitingIsGreyNotAmber() {
        let apple = CardLive(runStartedAt: 0, workerAlive: true, sessionId: "s",
                             now: step("Waiting for Apple", wait: "apple", running: true, since: 0), lastActivityAt: 0)
        #expect(CardSignal.of(apple, now: Date(timeIntervalSince1970: 120)) == CardSignal.none)
        #expect(CardSignal.of(apple, now: Date(timeIntervalSince1970: 3600)) == .waiting("Waiting on Apple"))
        let net = CardLive(runStartedAt: 0, workerAlive: true, sessionId: "s",
                           now: step("Calling a server", wait: "network", running: true, since: 0), lastActivityAt: 0)
        #expect(CardSignal.of(net, now: Date(timeIntervalSince1970: 3600)).label == "Waiting on network")
    }

    @Test func deadWorkerIsRedWhateverElse() {
        let live = CardLive(runStartedAt: 0, workerAlive: false, sessionId: "s",
                            now: step(wait: "apple", running: true, since: 0), lastActivityAt: 999)
        #expect(CardSignal.of(live, now: Date(timeIntervalSince1970: 1000)) == .stopped)
        #expect(CardSignal.stopped.label == "Worker stopped")
        // Unknown liveness (no pid) never claims "stopped".
        #expect(CardSignal.of(CardLive(runStartedAt: 990, workerAlive: nil), now: Date(timeIntervalSince1970: 1000)) == CardSignal.none)
    }

    // MARK: Trail

    @Test func trailText() {
        let trail = [CardLive.TrailStep(phrase: "Merging", state: "done", at: nil),
                     CardLive.TrailStep(phrase: "Running tests", state: "failed", at: nil),
                     CardLive.TrailStep(phrase: "Uploading to TestFlight", state: "running", at: nil)]
        #expect(CardTrail.text(trail) == "Merging ✓ · Running tests ✗ · Uploading to TestFlight …")
        #expect(CardTrail.text([]) == nil)
    }

    // MARK: Card → worker session (what a click opens)

    private func task(_ id: String, status: String = "running") -> KanbanTask {
        KanbanTask(id: id, title: "Card \(id)", body: nil, assignee: "default", status: status, priority: 0,
                   createdAt: 1, startedAt: 2, completedAt: nil, result: nil, latestSummary: nil, commentCount: nil,
                   lastFailureError: nil, blockKind: nil)
    }

    @Test func watchTargetOnlyForRunningCardsWithASession() throws {
        let store = CardLiveStore()
        store.apply(try CardLiveResponse.decode(Data(Self.payload.utf8)), board: "otto")
        let t = try #require(store.watchTarget(task("t_2ede9e2d"), board: "otto"))
        #expect(t.sessionID == "20261018_030951_5e40de" && t.board == "otto" && t.title == "Card t_2ede9e2d")
        #expect(store.watchTarget(task("t_aaaaaaaa"), board: "otto") == nil)            // no session linked
        #expect(store.watchTarget(task("t_2ede9e2d", status: "done"), board: "otto") == nil)  // not running any more
        #expect(store.watchTarget(task("t_unknown0"), board: "otto") == nil)
    }

    @Test func aCardThatStopsRunningDropsOutOnTheNextAnswer() throws {
        let store = CardLiveStore()
        store.apply(try CardLiveResponse.decode(Data(Self.payload.utf8)), board: "otto")
        store.apply(CardLiveResponse(board: "weft", now: nil, cards: ["t_weft0001": CardLive(sessionId: "w")]), board: "weft")
        store.apply(CardLiveResponse(board: "otto", now: nil, cards: ["t_aaaaaaaa": CardLive(workerAlive: false)]), board: "otto")
        #expect(store.live("t_2ede9e2d") == nil)          // finished: gone, so the watch view does its final read
        #expect(store.live("t_aaaaaaaa")?.workerAlive == false)
        #expect(store.live("t_weft0001")?.sessionId == "w")  // other boards untouched
    }
}
