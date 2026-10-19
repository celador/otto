import Foundation

/// Small on-disk cache so the app opens instantly (and readable offline or
/// when Tailscale is off) with the last-known session list and transcripts.
enum LocalCache {
    private static var dir: URL {
        let base = AppDirs.caches
        let d = base.appendingPathComponent("hermes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func saveSessions(_ sessions: [SessionSummary]) {
        write(sessions, to: "sessions.json")
    }

    static func loadSessions() -> [SessionSummary] {
        read([SessionSummary].self, from: "sessions.json") ?? []
    }

    static func saveMessages(_ messages: [CachedMessage], sessionID: String) {
        write(messages, to: "m-\(safe(sessionID)).json")
    }

    static func loadMessages(sessionID: String) -> [StoredMessage]? {
        read([CachedMessage].self, from: "m-\(safe(sessionID)).json")?.map(\.stored)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }

    private static func safe(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Codable mirror of `StoredMessage` for the cache (keeps the last 300 rows).
struct CachedMessage: Codable, Sendable {
    var id: Int
    var role: String
    var content: String?
    var toolCallId: String?
    var toolCalls: [ToolCall]?
    var toolName: String?
    var displayKind: String?
    /// Optional: caches written before build 78 lack it.
    var timestamp: Double?

    init(_ m: StoredMessage) {
        id = m.id; role = m.role; content = m.content.map { String($0.prefix(20_000)) }
        toolCallId = m.toolCallId; toolCalls = m.toolCalls; toolName = m.toolName; displayKind = m.displayKind
        timestamp = m.timestamp
    }

    var stored: StoredMessage {
        StoredMessage(id: id, role: role, content: content, toolCallId: toolCallId,
                      toolCalls: toolCalls, toolName: toolName, timestamp: timestamp, displayKind: displayKind)
    }

    static func from(_ messages: [StoredMessage]) -> [CachedMessage] {
        messages.suffix(300).map(CachedMessage.init)
    }
}
