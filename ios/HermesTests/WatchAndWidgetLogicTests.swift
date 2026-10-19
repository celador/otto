import Foundation
import Testing
@testable import Hermes

struct WatchAndWidgetLogicTests {
    @Test func jobDatesFromPythonIsoformat() {
        #expect(JobLite.date("2026-10-03T22:58:14.082950-03:00") != nil)
        #expect(JobLite.date("2026-10-04T07:00:00-03:00") != nil)
        #expect(JobLite.date("garbage") == nil)
    }

    @Test func agentJobsComeFirst() throws {
        let json = """
        {"jobs":[
         {"id":"w","name":"Watchdog","state":"scheduled","next_run_at":"2026-10-03T22:00:00-03:00","no_agent":true},
         {"id":"b","name":"Briefing","state":"scheduled","next_run_at":"2026-10-04T07:00:00-03:00","no_agent":false},
         {"id":"p","name":"Paused","state":"paused","next_run_at":"2026-10-03T21:00:00-03:00","no_agent":false}]}
        """
        struct Env: Decodable { let jobs: [JobLite] }
        let jobs = try JSONDecoder().decode(Env.self, from: Data(json.utf8)).jobs
        #expect(JobsAPI.ordered(jobs).map(\.id) == ["b", "w", "p"])
    }

    @Test func kickFinishesWhenLastRunMoves() {
        let job = JobLite(id: "a", name: nil, profile: nil, state: nil, scheduleDisplay: nil, nextRunAt: nil,
                          lastRunAt: "2026-10-03T07:00:00-03:00", lastStatus: "ok", lastError: nil, deliver: "telegram", enabled: true)
        let kick = JobKick(jobID: "a", at: .now, previousLastRun: "2026-10-02T07:00:00-03:00")
        #expect(kick.finished(in: job))
        #expect(!JobKick(jobID: "a", at: .now, previousLastRun: job.lastRunAt).finished(in: job))
        #expect(job.deliveryLabel == "Telegram")
    }

    @Test func healthQuestionsAreRecognised() {
        #expect(HealthContext.isRelevant("How did I sleep last night?"))
        #expect(HealthContext.isRelevant("Should I train hard today?"))
        #expect(HealthContext.isRelevant("what's my HRV doing"))
        #expect(!HealthContext.isRelevant("Run the daily briefing"))
        #expect(!HealthContext.isRelevant("Summarize this article about Porto"))
    }

    @Test func yesNoQuestions() {
        #expect(WatchSnippet.asksYesNo("I found a flight for $389. Want me to hold it for you?"))
        #expect(!WatchSnippet.asksYesNo("Which do you prefer, TAP or Iberia?"))
        #expect(!WatchSnippet.asksYesNo("Done. The file is saved."))
    }

    @Test func siriAnswersStayShort() {
        let long = String(repeating: "This is a sentence. ", count: 60)
        let spoken = AskHermesForAnswerIntent.spoken(long)
        #expect(spoken.count < 700)
        #expect(spoken.hasSuffix("The rest is in the app."))
    }
}
