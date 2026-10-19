import Foundation

// MARK: - Companion relay models (relay/companion.py)

struct HermesProfile: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let isDefault: Bool?
    let model: String?
    let provider: String?
    let skillCount: Int?
    let gatewayRunning: Bool?
    let description: String?
    let displayName: String?
    let botTitle: String?

    var id: String { name }
    var title: String {
        if let d = displayName, !d.isEmpty { return d }
        return name == "default" ? "Main agent" : name.replacingOccurrences(of: "-", with: " ").capitalized
    }
    /// Short model name for subtitles ("claude-opus-5-5").
    var modelShort: String? { model.map { $0.split(separator: "/").last.map(String.init) ?? $0 } }
}

struct ProfilesResponse: Decodable, Sendable {
    let profiles: [HermesProfile]
    let active: String
}

struct HermesSkill: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let description: String?
    let category: String?
    var enabled: Bool
    let usage: Int?
    let provenance: String?

    var id: String { name }
    var summary: String {
        (description ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

struct SkillsResponse: Decodable, Sendable { let skills: [HermesSkill] }
struct SkillContent: Decodable, Sendable { let name: String; let content: String }

struct MemoryState: Decodable, Sendable {
    let memory: [String]
    let user: [String]
    let limits: Limits
    let error: String?

    struct Limits: Decodable, Sendable { let memory: Int; let user: Int }

    func entries(_ target: MemoryTarget) -> [String] { target == .memory ? memory : user }
    func limit(_ target: MemoryTarget) -> Int { target == .memory ? limits.memory : limits.user }
    /// Characters used, counting the "\n§\n" delimiter Hermes puts between entries.
    func used(_ target: MemoryTarget) -> Int {
        let e = entries(target)
        return e.reduce(0) { $0 + $1.count } + max(0, e.count - 1) * 3
    }
}

enum MemoryTarget: String, CaseIterable, Identifiable, Sendable {
    case memory, user
    var id: String { rawValue }
    var title: String { self == .memory ? "Notes" : "About you" }
    var footer: String {
        self == .memory
            ? "Things your agent noted about your setup, tools and conventions. Loaded into every chat."
            : "What your agent knows about you: who you are and how you like to work."
    }
}

struct HermesStatus: Decodable, Sendable {
    let version: String?
    let releaseDate: String?
    let gatewayRunning: Bool?
    let gatewayState: String?
    let canUpdate: Bool?
    let platforms: [String: Platform]

    struct Platform: Decodable, Sendable {
        let state: String?
        let errorMessage: String?
        let needsAttention: Bool?
    }
}

struct UsageResponse: Decodable, Sendable {
    let daily: [Day]
    let totals: Totals?
    let models: [ModelUsage]
    let periodDays: Int

    struct Day: Decodable, Identifiable, Sendable {
        let day: String
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let estimatedCost: Double?
        let actualCost: Double?
        let sessions: Int?
        let apiCalls: Int?
        var id: String { day }
        var cost: Double { max(actualCost ?? 0, estimatedCost ?? 0) }
        var date: Date? {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            return f.date(from: day)
        }
    }

    struct Totals: Decodable, Sendable {
        let totalInput: Int?
        let totalOutput: Int?
        let totalCacheRead: Int?
        let totalEstimatedCost: Double?
        let totalActualCost: Double?
        let totalApiCalls: Int?
        let totalSessions: Int?
        var cost: Double { max(totalActualCost ?? 0, totalEstimatedCost ?? 0) }
    }

    struct ModelUsage: Decodable, Identifiable, Sendable {
        let model: String?
        let provider: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let estimatedCost: Double?
        let actualCost: Double?
        let sessions: Int?
        let apiCalls: Int?
        var id: String { "\(provider ?? "")/\(model ?? "?")" }
        var cost: Double { max(actualCost ?? 0, estimatedCost ?? 0) }
        var tokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }
    }
}
