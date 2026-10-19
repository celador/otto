import ActivityKit
import Foundation

/// Live Activity for a running Hermes turn: lock screen + Dynamic Island.
/// Shared by the app (starts/updates/ends it) and the widget extension (draws it).
struct HermesRunAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// "Running a command", "Searching the web: …", "Thinking", "Done".
        var status: String
        var toolsUsed: Int
        var needsApproval: Bool
        var finished: Bool
        var failed: Bool
        /// Voice mode is open: "listening", "thinking", "speaking" or "muted"; nil otherwise.
        var voice: String? = nil
    }

    var sessionID: String
    var title: String
    var startedAt: Date
}
