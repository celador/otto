import Foundation
import Security

// AI subscription limits (Codex, Claude, …) read by CodexBar on the Mac and served by the relay at
// GET /hermes/limits. Shared by the app, the widgets and the watch.

struct LimitsSnapshot: Codable, Sendable, Equatable {
    var providers: [LimitProvider]
    var fetchedAt: String?
    var error: String?
    var stale: Bool?

    var fetchedDate: Date? { fetchedAt.flatMap(LimitDates.parse) }

    /// The window closest to running out, across every provider (what a glance should show).
    var tightest: (provider: LimitProvider, window: LimitWindow)? {
        providers.flatMap { p in p.windows.map { (p, $0) } }.max { $0.1.usedPercent < $1.1.usedPercent }
    }

    static let empty = LimitsSnapshot(providers: [], fetchedAt: nil, error: nil, stale: nil)
}

struct LimitProvider: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let plan: String?
    let source: String?
    let windows: [LimitWindow]
    let credits: Double?
    let status: ProviderStatus?
    let error: String?
    let updatedAt: String?

    /// "plus" → "Plus"; "Claude Max 5x" → "Max 5x" (the provider name is already shown).
    var planLabel: String? {
        guard var p = plan?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        if p.lowercased().hasPrefix(name.lowercased() + " ") { p = String(p.dropFirst(name.count + 1)) }
        return p.prefix(1).uppercased() + p.dropFirst()
    }

    /// An incident worth flagging (anything but "all clear").
    var incident: String? {
        guard let s = status, let i = s.indicator, i != "none" else { return nil }
        return s.summary ?? "Service issue"
    }
}

struct LimitWindow: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let label: String
    let windowMinutes: Double?
    let usedPercent: Double
    let resetsAt: String?
    let resetDescription: String?
    let pace: Pace?

    var resetDate: Date? { resetsAt.flatMap(LimitDates.parse) }
    var fraction: Double { min(1, max(0, usedPercent / 100)) }
    var level: LimitLevel { LimitLevel(usedPercent) }

    struct Pace: Codable, Sendable, Hashable {
        let stage: String?
        let summary: String?
        let willLastToReset: Bool?
        let expectedUsedPercent: Double?

        /// CodexBar writes "20% in reserve | Expected 92% used | Lasts until reset | 1.5× headroom";
        /// keep the parts a person reads first.
        var short: String? {
            guard let summary else { return nil }
            let parts = summary.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            let keep = parts.filter { !$0.lowercased().hasPrefix("expected") && !$0.contains("headroom") }
            return keep.isEmpty ? nil : keep.joined(separator: " · ")
        }
    }
}

struct ProviderStatus: Codable, Sendable, Hashable {
    let indicator: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case indicator
        case summary = "description"
    }
}

enum LimitLevel: Int, Comparable, Sendable {
    case fine, getting, high, out
    init(_ used: Double) {
        self = used >= 100 ? .out : used >= 90 ? .high : used >= 75 ? .getting : .fine
    }
    static func < (a: LimitLevel, b: LimitLevel) -> Bool { a.rawValue < b.rawValue }
}

enum LimitDates {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// "in 2h 14m", "in 3 days", "now".
    static func countdown(to date: Date, from now: Date = .now) -> String {
        let s = date.timeIntervalSince(now)
        if s <= 60 { return "now" }
        let m = Int(s / 60), h = m / 60, d = h / 24
        if d >= 2 { return "in \(d) days" }
        if h >= 1 { return m % 60 == 0 || h >= 10 ? "in \(h)h" : "in \(h)h \(m % 60)m" }
        return "in \(m)m"
    }
}

enum LimitsWidgetKind {
    static let kind = "ai.elier.hermes.limits"
}

enum LimitsAPI {
    static func fetch(relay: URL, apiKey: String, refresh: Bool = false, timeout: TimeInterval = 100) async throws -> LimitsSnapshot {
        var c = URLComponents(url: relay.appendingPathComponent("hermes/limits"), resolvingAgainstBaseURL: false)!
        if refresh { c.queryItems = [URLQueryItem(name: "refresh", value: "1")] }
        var req = URLRequest(url: c.url!, timeoutInterval: timeout)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(LimitsSnapshot.self, from: data)
    }
}

/// The relay address + key and the last snapshot, in a keychain group the app and its widgets share.
/// (Keychain sharing needs no App ID capability: profiles already allow TEAMID.* access groups.)
enum SharedVault {
    static let group = "UFF39H3A3T.ai.elier.hermes.shared"
    private static let service = "ai.elier.hermes.shared"

    struct Relay: Codable, Sendable { let relay: URL; let apiKey: String }

    static func saveRelay(_ r: Relay?) { write("relay", r.flatMap { try? JSONEncoder().encode($0) }) }
    static func relay() -> Relay? { read("relay").flatMap { try? JSONDecoder().decode(Relay.self, from: $0) } }

    static func saveLimits(_ s: LimitsSnapshot) { write("limits", try? JSONEncoder().encode(s)) }
    static func limits() -> LimitsSnapshot? { read("limits").flatMap { try? JSONDecoder().decode(LimitsSnapshot.self, from: $0) } }

    /// A chat started from the share sheet when the extension couldn't open the app itself.
    static func savePendingShare(_ prompt: String) { write("pendingShare", prompt.data(using: .utf8)) }
    static func takePendingShare() -> String? {
        guard let d = read("pendingShare") else { return nil }
        write("pendingShare", nil)
        return String(data: d, encoding: .utf8)
    }

    /// Photos shared from the share sheet, handed to the app (small copies) so the chat shows them.
    struct SharedPhotos: Codable, Sendable { let sessionID: String; let text: String; let jpegs: [Data] }
    static func savePendingPhotos(_ p: SharedPhotos) {
        var all = pendingPhotos()
        all.append(p)
        write("pendingPhotos", try? JSONEncoder().encode(Array(all.suffix(3))))
    }
    static func pendingPhotos() -> [SharedPhotos] {
        read("pendingPhotos").flatMap { try? JSONDecoder().decode([SharedPhotos].self, from: $0) } ?? []
    }
    static func takePendingPhotos() -> [SharedPhotos] {
        let all = pendingPhotos()
        if !all.isEmpty { write("pendingPhotos", nil) }
        return all
    }

    static func writeData(_ account: String, _ data: Data?) { write(account, data) }
    static func readData(_ account: String) -> Data? { read(account) }

    // SecureStore: data protection keychain on macOS (no login-keychain prompts), plain SecItem elsewhere.
    private static func write(_ account: String, _ data: Data?) {
        SecureStore.write(service: service, account: account, group: group, data: data)
    }

    /// No legacy-keychain move on macOS: the relay + gateway are rewritten from KeychainStore at
    /// launch, limits is a cache, and the pending share items only exist on iOS.
    private static func read(_ account: String) -> Data? {
        SecureStore.read(service: service, account: account, group: group, migrateLegacy: false)
    }
}
