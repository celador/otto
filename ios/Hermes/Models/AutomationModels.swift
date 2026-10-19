import Foundation

struct CompanionJobs: Decodable, Sendable { let jobs: [CronJob] }

/// One run of an automation. Agent runs are sessions (`cron_<job>_<ts>`);
/// script-only runs are output docs (`cron_output:<job>:<stem>`).
struct JobRun: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    let preview: String?
    let source: String?
    let startedAt: Double?
    let endedAt: Double?
    let endReason: String?
    let model: String?
    let messageCount: Int?
    let toolCallCount: Int?
    let estimatedCostUsd: Double?
    let isActive: Bool?

    var isScriptOutput: Bool { id.hasPrefix("cron_output:") }
    var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0) } }
    var duration: TimeInterval? {
        guard let s = startedAt, let e = endedAt, e >= s else { return nil }
        return e - s
    }
    /// "COMPLETED · …" / "FAILED · …" prefixes from the dashboard, or the end reason.
    var failed: Bool {
        let t = (title ?? "").uppercased()
        return t.hasPrefix("FAILED") || t.hasPrefix("ERROR") || endReason == "cron_error" || endReason == "error"
    }
    var silent: Bool { (title ?? "").localizedCaseInsensitiveContains("silent") }
    var summary: String {
        if isScriptOutput {
            if silent { return "Nothing to report" }
            let t = (title ?? "").replacingOccurrences(of: #"^(COMPLETED|FAILED|ERROR) · "#, with: "", options: .regularExpression)
            return t.contains("# Cron Job") ? "Script run" : t
        }
        if failed { return "Didn't finish" }
        return [toolCallCount.flatMap { $0 > 0 ? "\($0) step\($0 == 1 ? "" : "s")" : nil },
                estimatedCostUsd.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2))) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct JobRuns: Decodable, Sendable { let runs: [JobRun] }
struct RunOutput: Decodable, Sendable { let text: String; let note: String? }

struct DeliveryTarget: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let homeTargetSet: Bool?
}
struct DeliveryTargets: Decodable, Sendable { let targets: [DeliveryTarget] }

enum Delivery {
    static func label(_ id: String) -> String {
        switch id {
        case "origin": return "Where it was set up"
        case "local": return "Don't send (save only)"
        case "all": return "Everywhere"
        case "telegram": return "Telegram"
        case "whatsapp": return "WhatsApp"
        default:
            if id.hasPrefix("bot-chat:") {
                let p = String(id.dropFirst("bot-chat:".count))
                return "Bot chat · " + (p == "default" ? "Main agent" : p)
            }
            return id.capitalized
        }
    }
}

// MARK: - Templates (cron blueprints)

struct Blueprint: Decodable, Identifiable, Hashable, Sendable {
    let key: String
    let title: String
    let description: String?
    let category: String?
    let fields: [Field]
    let scheduleHuman: String?
    var id: String { key }

    struct Field: Decodable, Hashable, Sendable {
        let name: String
        let type: String          // time · enum · text · weekdays
        let label: String
        let `default`: FlexibleValue?
        let options: [FlexibleValue]?
        let optional: Bool?
        let help: String?
    }

    var icon: String {
        switch key {
        case "morning-brief": "sun.horizon"
        case "important-mail": "envelope.badge"
        case "weekly-review": "calendar"
        case "workday-start": "briefcase"
        case "custom-reminder": "bell"
        case "evening-winddown": "moon.stars"
        case "news-digest": "newspaper"
        case "bill-renewal-watch": "creditcard"
        case "price-watch": "tag"
        case "competitor-watch": "binoculars"
        case "habit-checkin": "checkmark.circle"
        case "hydration-move": "drop"
        case "meal-plan": "fork.knife"
        case "learn-daily": "book"
        case "gratitude-journal": "heart.text.square"
        case "on-this-day": "clock.arrow.circlepath"
        default: "sparkles"
        }
    }
}

struct Blueprints: Decodable, Sendable { let blueprints: [Blueprint] }

/// Blueprint defaults/options can be strings or numbers.
enum FlexibleValue: Decodable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else { self = .number(try c.decode(Double.self)) }
    }

    var text: String {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): b ? "true" : "false"
        }
    }
}

// MARK: - Messaging access (pairing)

struct PairingState: Decodable, Sendable {
    let pending: [Pending]
    let approved: [Approved]

    struct Pending: Decodable, Identifiable, Hashable, Sendable {
        let platform: String
        let requestId: String
        let userId: String?
        let userName: String?
        let ageMinutes: Int?
        var id: String { platform + ":" + requestId }
    }

    struct Approved: Decodable, Identifiable, Hashable, Sendable {
        let platform: String
        let userId: String
        let userName: String?
        let approvedAt: Double?
        var id: String { platform + ":" + userId }
    }
}
