import Foundation

/// What Hermes is doing right now, for the watch's live line and complications.
/// Written by the watch app (its own runs, or pushed from the iPhone's runs) into the shared keychain.
struct LiveStatus: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case idle, working, needsYou, done, failed }

    var state: State
    /// "Searching the web", "Writing…", or the first line of the answer when done.
    var line: String
    var title: String?
    var sessionID: String?
    var steps: Int
    var startedAt: Date?
    var updatedAt: Date

    static let idle = LiveStatus(state: .idle, line: "Ready", title: nil, sessionID: nil, steps: 0,
                                    startedAt: nil, updatedAt: .distantPast)

    /// Done/failed fade back to idle after a while so the face doesn't show a stale result all day.
    func current(at now: Date = .now) -> LiveStatus {
        let age = now.timeIntervalSince(updatedAt)
        if (state == .done || state == .failed) && age > 2 * 3600 { return .idle }
        if (state == .working || state == .needsYou) && age > 45 * 60 { return .idle }   // lost track of it
        return self
    }

    var dictionary: [String: Any] { (try? JSONEncoder().encode(self)).map { ["status": $0] } ?? [:] }
    static func from(_ dict: [String: Any]) -> LiveStatus? {
        (dict["status"] as? Data).flatMap { try? JSONDecoder().decode(LiveStatus.self, from: $0) }
    }
}

extension SharedVault {
    static func saveStatus(_ s: LiveStatus) { writeData("status", try? JSONEncoder().encode(s)) }
    static func status() -> LiveStatus {
        readData("status").flatMap { try? JSONDecoder().decode(LiveStatus.self, from: $0) } ?? .idle
    }
}

/// A limits window's used percent, treating a window whose reset time has passed as empty again.
extension LimitWindow {
    func effectivePercent(at date: Date) -> Double {
        if let r = resetDate, r <= date { return 0 }
        return usedPercent
    }
}

extension LimitsSnapshot {
    func tightest(at date: Date) -> (provider: LimitProvider, window: LimitWindow, percent: Double)? {
        providers.flatMap { p in p.windows.map { (p, $0, $0.effectivePercent(at: date)) } }
            .max { $0.2 < $1.2 }
    }

    /// Upcoming reset times, so a timeline can redraw the ring when a window empties.
    var resetDates: [Date] { providers.flatMap { $0.windows.compactMap(\.resetDate) }.filter { $0 > .now }.sorted() }
}
