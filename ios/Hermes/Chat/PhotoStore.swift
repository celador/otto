import Foundation

/// Keeps a copy of photos sent from this phone, per chat. The gateway stores only
/// a "[screenshot]" placeholder in history, so without this, a pasted image turns
/// into a "Photo" label after the chat reloads.
enum PhotoStore {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let text: String
        let count: Int
        let sentAt: Date
    }

    private static var root: URL {
        AppDirs.support
            .appendingPathComponent("SentPhotos", isDirectory: true)
    }

    private static func dir(_ sessionID: String) -> URL {
        root.appendingPathComponent(sessionID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private static func index(_ sessionID: String) -> URL { dir(sessionID).appendingPathComponent("index.json") }

    static func entries(sessionID: String) -> [Entry] {
        guard let data = try? Data(contentsOf: index(sessionID)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Saves JPEGs for a message the gateway accepted.
    static func save(_ images: [Data], text: String, sessionID: String) {
        guard !images.isEmpty else { return }
        let d = dir(sessionID)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let entry = Entry(id: UUID().uuidString, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          count: images.count, sentAt: Date())
        for (i, jpeg) in images.enumerated() {
            try? jpeg.write(to: d.appendingPathComponent("\(entry.id)-\(i).jpg"), options: .atomic)
        }
        var all = entries(sessionID: sessionID)
        all.append(entry)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: index(sessionID), options: .atomic) }
    }

    static func load(_ entry: Entry, sessionID: String? = nil) -> [Data] {
        guard let sid = sessionID ?? owner(of: entry) else { return [] }
        return (0..<entry.count).compactMap { try? Data(contentsOf: dir(sid).appendingPathComponent("\(entry.id)-\($0).jpg")) }
    }

    /// All photos for a chat, newest first (for "Photos in this chat").
    static func all(sessionID: String) -> [Data] {
        entries(sessionID: sessionID).reversed().flatMap { load($0, sessionID: sessionID) }
    }

    static func deleteAll(sessionID: String) {
        try? FileManager.default.removeItem(at: dir(sessionID))
    }

    private static func owner(of entry: Entry) -> String? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return dirs.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(entry.id)-0.jpg").path) }?
            .lastPathComponent
    }
}
