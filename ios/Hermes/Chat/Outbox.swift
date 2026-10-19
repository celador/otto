import Foundation

/// A message the gateway hasn't accepted yet.
struct PendingMessage: Codable, Equatable, Identifiable, Sendable {
    /// Also the run's Idempotency-Key, so a retry after a send that did get
    /// through (but whose response was lost) can't start a second turn.
    var id: String
    var text: String
    var images: [Data] = []
    var isSteer = false
    /// Said in voice mode: the run asks Hermes for short spoken sentences (optional: older outboxes lack it).
    var voice: Bool?
    /// nil while sending; set once a send fails.
    var error: String?
    /// When it was written (optional: older outboxes lack it). Shown as the message's time.
    var queuedAt: Date? = nil

    var chatItem: ChatItem {
        .user(UserMessage(id: id, text: SkillInvocation.describe(text) ?? text, images: images, isSteer: isSteer,
                          delivery: error.map { .failed($0) } ?? .sending))
    }
}

/// Unsent messages per chat, on disk. A message goes in before it is sent and
/// comes out only once the gateway accepts it, so it can never vanish when the
/// transcript is rebuilt from server history, the chat is closed, or iOS kills
/// the app mid-send. Failed ones stay in the chat with Retry / Delete.
enum Outbox {
    static let interruptedError = "Not sent — Otto closed before it was delivered."

    private static var dir: URL {
        let base = AppDirs.support
        let d = base.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(_ sessionID: String?) -> URL {
        let name = sessionID.map { "s-" + $0.replacingOccurrences(of: "/", with: "_") } ?? "new"
        return dir.appendingPathComponent(name + ".json")
    }

    static func load(sessionID: String?) -> [PendingMessage] {
        guard let data = try? Data(contentsOf: file(sessionID)) else { return [] }
        return (try? JSONDecoder().decode([PendingMessage].self, from: data)) ?? []
    }

    static func save(_ messages: [PendingMessage], sessionID: String?) {
        if messages.isEmpty {
            try? FileManager.default.removeItem(at: file(sessionID))
        } else if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: file(sessionID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func add(_ message: PendingMessage, sessionID: String?) {
        save(load(sessionID: sessionID).filter { $0.id != message.id } + [message], sessionID: sessionID)
    }

    static func remove(id: String, sessionID: String?) {
        save(load(sessionID: sessionID).filter { $0.id != id }, sessionID: sessionID)
    }

    static func markFailed(id: String, error: String, sessionID: String?) {
        save(load(sessionID: sessionID).map { var m = $0; if m.id == id { m.error = error }; return m },
             sessionID: sessionID)
    }

    /// A new chat just got its id on the server: its outbox moves with it.
    static func move(fromNewChatTo sessionID: String) {
        let unsent = load(sessionID: nil)
        guard !unsent.isEmpty else { return }
        save(load(sessionID: sessionID) + unsent, sessionID: sessionID)
        save([], sessionID: nil)
    }

    /// Nothing is in flight when a chat opens, so anything still marked
    /// "sending" was cut off (app killed, chat closed mid-send).
    static func restoredAfterLaunch(_ messages: [PendingMessage]) -> [PendingMessage] {
        messages.map { var m = $0; if m.error == nil { m.error = interruptedError }; return m }
    }
}

extension HermesError {
    /// `POST /v1/runs/{id}/steer` on a run that already ended (409
    /// `run_not_accepting_steer`): the text belongs in a new turn instead.
    var runNotAcceptingSteer: Bool {
        if case .http(409, _) = self { return true }
        return false
    }
}
