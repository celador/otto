import Foundation
import Testing
@testable import Hermes

struct LimitPaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func window(used: Double, hoursLeft: Double, of hours: Double = 168) -> LimitWindow {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(hoursLeft * 3600))
        return LimitWindow(id: "w", label: "Weekly", windowMinutes: hours * 60, usedPercent: used,
                           resetsAt: reset, resetDescription: nil, pace: nil)
    }

    @Test func colourFollowsUsageAgainstTime() {
        // Half the week gone.
        #expect(window(used: 30, hoursLeft: 84).pace(at: now) == .under)
        #expect(window(used: 51, hoursLeft: 84).pace(at: now) == .onPace)
        #expect(window(used: 58, hoursLeft: 84).pace(at: now) == .ahead)
        #expect(window(used: 70, hoursLeft: 84).pace(at: now) == .farAhead)
        #expect(window(used: 80, hoursLeft: 84).pace(at: now) == .out)
        #expect(window(used: 100, hoursLeft: 1).pace(at: now) == .out)
    }

    @Test func earlyInWindowIsForgiving() {
        #expect(window(used: 6, hoursLeft: 167).pace(at: now) == .onPace)
    }

    @Test func pastResetIsFresh() {
        #expect(window(used: 90, hoursLeft: -1).pace(at: now) == .under)
    }
}
