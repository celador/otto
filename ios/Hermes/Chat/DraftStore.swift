import Foundation

/// Unsent composer text per chat, so switching apps (or iOS evicting the
/// app in the background) never loses what you were typing or dictating.
enum DraftStore {
    private static let newChatKey = "draft.new"
    private static func key(_ sessionID: String?) -> String {
        sessionID.map { "draft.\($0)" } ?? newChatKey
    }

    static func get(sessionID: String?) -> String {
        UserDefaults.standard.string(forKey: key(sessionID)) ?? ""
    }

    static func set(_ text: String, sessionID: String?) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key(sessionID))
        } else {
            UserDefaults.standard.set(text, forKey: key(sessionID))
        }
    }
}

/// Text that reappears in the composer right after Send is an echo of the
/// sent message, not new typing: a late speech-recognizer result, the
/// keyboard's own dictation committing its pending text, or a pending
/// autocorrection committing on the Send tap. All of them write back the
/// message (or its ending) within a moment of the clear.
enum ComposerEcho {
    static let window: TimeInterval = 2

    static func isEcho(_ draft: String, sent: String?, sentAt: Date?, now: Date = .now) -> Bool {
        guard let sent, let sentAt, now.timeIntervalSince(sentAt) < window else { return false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // One character is how new typing starts; never swallow it.
        guard text.count >= 2 else { return false }
        return sent.hasSuffix(text) || text == sent
    }
}
