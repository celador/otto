import Foundation

// MARK: - Kanban (via the Mac's Kanban relay, relay/kanban_relay.py)

struct KanbanBoardsResponse: Decodable, Sendable {
    let boards: [KanbanBoardInfo]
}

struct KanbanBoardInfo: Decodable, Identifiable, Hashable, Sendable {
    let slug: String
    let name: String?
    let description: String?
    let icon: String?
    let archived: Bool?
    let counts: [String: Int]?
    let total: Int?

    var id: String { slug }
    var displayName: String { (name?.isEmpty == false ? name : nil) ?? slug }
    /// Tasks that aren't done or archived.
    var openCount: Int {
        (counts ?? [:]).filter { !["done", "archived"].contains($0.key) }.values.reduce(0, +)
    }
}

struct KanbanBoard: Decodable, Sendable {
    let columns: [KanbanColumn]
}

struct KanbanColumn: Decodable, Identifiable, Sendable {
    let name: String
    let tasks: [KanbanTask]
    var id: String { name }
}

struct KanbanTask: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String?
    let assignee: String?
    let status: String
    let priority: Int?
    let createdAt: Double?
    let startedAt: Double?
    let completedAt: Double?
    let result: String?
    let latestSummary: String?
    let commentCount: Int?
    let lastFailureError: String?
    let blockKind: String?
    /// Start of the current run (`started_at` is the first-ever start; a retry starts a new run).
    var currentRunStartedAt: Double? = nil
    /// Last worker heartbeat of the current run.
    var lastHeartbeatAt: Double? = nil

    var createdDate: Date? { createdAt.map { Date(timeIntervalSince1970: $0) } }
    var completedDate: Date? { completedAt.map { Date(timeIntervalSince1970: $0) } }
}

struct KanbanTaskDetail: Decodable, Sendable {
    let task: KanbanTask
    let comments: [KanbanComment]
    let events: [KanbanEvent]
}

struct KanbanComment: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let author: String?
    let body: String
    let createdAt: Double

    var date: Date { Date(timeIntervalSince1970: createdAt) }
}

struct KanbanEvent: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let kind: String
    let createdAt: Double

    var date: Date { Date(timeIntervalSince1970: createdAt) }
}

struct KanbanTaskEnvelope: Decodable, Sendable {
    let task: KanbanTask?
    let warning: String?
}

struct KanbanAssignees: Decodable, Sendable {
    struct Assignee: Decodable, Sendable { let name: String }
    let assignees: [Assignee]
}

enum KanbanStatus {
    /// Column order and labels, as in the Hermes dashboard.
    static let order = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

    static func label(_ status: String) -> String {
        switch status {
        case "triage": "Triage"
        case "todo": "To do"
        case "scheduled": "Scheduled"
        case "ready": "Ready"
        case "running": "Running"
        case "blocked": "Blocked"
        case "review": "Review"
        case "done": "Done"
        case "archived": "Archived"
        default: status.capitalized
        }
    }

    static func symbol(_ status: String) -> String {
        switch status {
        case "triage": "tray"
        case "todo": "circle"
        case "scheduled": "calendar"
        case "ready": "play.circle"
        case "running": "bolt.circle"
        case "blocked": "exclamationmark.octagon"
        case "review": "eye"
        case "done": "checkmark.circle"
        default: "circle.dashed"
        }
    }

    /// Statuses a person can move a task to from the phone (running is set by workers).
    static let movable = ["triage", "todo", "ready", "blocked", "done"]
}

// MARK: - Automations (gateway /api/jobs)

struct JobList: Decodable, Sendable {
    let jobs: [CronJob]
}

struct JobEnvelope: Decodable, Sendable {
    let job: CronJob?
}

struct CronJob: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let prompt: String?
    let enabled: Bool?
    let state: String?
    let scheduleDisplay: String?
    let nextRunAt: String?
    let lastRunAt: String?
    let lastStatus: String?
    let lastError: String?
    let pausedAt: String?
    let deliver: String?
    let noAgent: Bool?
    let script: String?
    var profile: String? = nil
    var model: String? = nil
    var skills: [String]? = nil
    var failureStreak: Int? = nil
    var lastDeliveryError: String? = nil
    var pausedReason: String? = nil

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return String((prompt ?? id).prefix(60))
    }

    var isPaused: Bool { state == "paused" || pausedAt != nil || enabled == false }
    var nextRun: Date? { nextRunAt.flatMap(Self.parseDate) }
    var lastRun: Date? { lastRunAt.flatMap(Self.parseDate) }
    var lastFailed: Bool { lastStatus == "error" || lastStatus == "failed" }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
