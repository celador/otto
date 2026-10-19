import Foundation

struct UserMessage: Equatable, Sendable {
    var id: String
    var text: String
    /// JPEG data for images sent from this phone during this app session.
    var images: [Data] = []
    /// Images known to exist in history (the server stores only a placeholder).
    var placeholderImages: Int = 0
    /// Sent while a run was in progress (steer), not as a new turn.
    var isSteer = false
    /// Only messages from the outbox are anything but `.sent`.
    var delivery: Delivery = .sent

    enum Delivery: Equatable, Sendable {
        case sent, sending
        case failed(String)
    }
}

/// One row in the chat transcript.
enum ChatItem: Identifiable, Equatable, Sendable {
    case user(UserMessage)
    case assistant(id: String, text: String, streaming: Bool)
    case tool(ToolActivity)
    case approval(ApprovalRequest)
    case notice(id: String, text: String, isError: Bool)

    var id: String {
        switch self {
        case .user(let m): m.id
        case .assistant(let id, _, _), .notice(let id, _, _): id
        case .tool(let t): t.id
        case .approval(let a): a.id
        }
    }
}

struct ToolActivity: Equatable, Sendable {
    enum State: Equatable, Sendable { case running, done, failed }
    var id: String
    var name: String
    var preview: String?
    var state: State
    var duration: Double?
    /// Raw JSON arguments (history only).
    var arguments: String?
    /// Result text: full from history, a ≤500-char redacted preview when live.
    var output: String?
}

struct ApprovalRequest: Equatable, Sendable {
    var id: String
    var runID: String
    var requestID: String?
    var command: String?
    var description: String?
    var choices: [String]
    var resolvedChoice: String?
}

/// Pure transcript reducer: server history in, run events applied on top.
/// Kept free of UI and networking so it is unit-testable.
struct Transcript: Equatable, Sendable {
    private(set) var items: [ChatItem] = []
    private(set) var lastSeq: Int?
    private(set) var terminalStatus: String?
    /// Steer text the run ended without delivering (the server sends it back for replay).
    private(set) var pendingSteer: String?
    /// When each message came through, by item id: the server's stored time for history rows,
    /// the moment it appeared on this device for live ones. Items without a known time have no entry.
    private(set) var dates: [String: Date] = [:]
    private var counter = 0

    func date(for id: String) -> Date? { dates[id] }

    init(items: [ChatItem] = []) { self.items = items }

    // MARK: History

    /// Builds a transcript from `GET /api/sessions/{id}/messages` rows.
    static func fromHistory(_ messages: [StoredMessage]) -> Transcript {
        var t = Transcript()
        var toolIndexByCallID: [String: Int] = [:]
        for m in messages where m.displayKind != "hidden" {
            let raw = m.content ?? ""
            let stamp = m.timestamp.map { Date(timeIntervalSince1970: $0) }
            if let stamp { t.dates["h\(m.id)"] = stamp }
            switch m.role {
            case "user":
                if let steer = HistoryCleaner.steerText(raw) {
                    if !steer.isEmpty { t.items.append(.user(UserMessage(id: "h\(m.id)", text: steer, isSteer: true))) }
                    continue
                }
                let (text, images) = HistoryCleaner.splitImages(HistoryCleaner.userText(raw))
                if !text.isEmpty || images > 0 {
                    t.items.append(.user(UserMessage(id: "h\(m.id)", text: text, placeholderImages: images)))
                }
            case "assistant":
                let text = raw.trimmed
                if let notice = Self.systemNotice(text) {
                    t.items.append(.notice(id: "h\(m.id)", text: notice, isError: true))
                } else if !text.isEmpty {
                    t.items.append(.assistant(id: "h\(m.id)", text: text, streaming: false))
                }
                for (i, call) in (m.toolCalls ?? []).enumerated() {
                    let activity = ToolActivity(
                        id: "h\(m.id)-\(i)", name: call.function?.name ?? "tool",
                        preview: Self.preview(fromArguments: call.function?.arguments),
                        state: .done, duration: nil, arguments: call.function?.arguments)
                    if let callID = call.id { toolIndexByCallID[callID] = t.items.count }
                    t.items.append(.tool(activity))
                }
            case "tool":
                if let callID = m.toolCallId, let idx = toolIndexByCallID[callID],
                   case .tool(var activity) = t.items[idx] {
                    activity.output = raw
                    if Self.looksLikeFailure(raw) { activity.state = .failed }
                    t.items[idx] = .tool(activity)
                    toolIndexByCallID[callID] = nil
                }
            default:
                break
            }
        }
        t.openToolIndices = Set(toolIndexByCallID.values)
        // Only rows that made it into the transcript keep a date.
        let shown = Set(t.items.map(\.id))
        t.dates = t.dates.filter { shown.contains($0.key) }
        return t
    }

    /// Stored tool calls with no result yet (a turn still running elsewhere, or one that died mid-tool).
    private(set) var openToolIndices: Set<Int> = []

    /// A turn is running elsewhere: its unanswered tool calls are in progress, not done.
    mutating func markOpenToolsRunning() {
        for i in openToolIndices where i < items.count {
            if case .tool(var a) = items[i], a.output == nil { a.state = .running; items[i] = .tool(a) }
        }
    }

    static func preview(fromArguments json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["command", "query", "url", "path", "code", "goal", "name"] {
            if let s = obj[key] as? String, !s.isEmpty { return String(s.prefix(200)) }
        }
        return obj.values.lazy.compactMap { $0 as? String }.first.map { String($0.prefix(200)) }
    }

    /// Gateway status lines stored as assistant messages ("Operation interrupted: …",
    /// "This turn did not complete…"). Shown as a notice, not as a reply.
    static func systemNotice(_ text: String) -> String? {
        guard text.count < 400 else { return nil }
        if text.hasPrefix("Operation interrupted") {
            return "This reply was interrupted before it finished."
        }
        if text.hasPrefix("This turn did not complete") {
            return "This turn didn't finish. Some steps may already have run."
        }
        if text.hasPrefix("API call failed") || text.hasPrefix("Error: ") {
            return text
        }
        return nil
    }

    static func looksLikeFailure(_ content: String?) -> Bool {
        guard let content, let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let code = obj["exit_code"] as? Int, code != 0 { return true }
        if let err = obj["error"], !(err is NSNull) {
            if let s = err as? String { return !s.isEmpty }
            return true
        }
        return false
    }

    // MARK: Live run

    mutating func appendUser(_ text: String, images: [Data] = [], isSteer: Bool = false, at date: Date = Date()) {
        append(.user(UserMessage(id: nextID("u"), text: SkillInvocation.describe(text) ?? text, images: images,
                                 isSteer: isSteer)), at: date)
    }

    mutating func beginRun() {
        lastSeq = nil
        terminalStatus = nil
        pendingSteer = nil
    }

    mutating func appendNotice(_ text: String, isError: Bool, at date: Date? = Date()) {
        append(.notice(id: nextID("n"), text: text, isError: isError), at: date)
    }

    /// Applies one run event. Replayed events (seq <= lastSeq) are ignored.
    /// New rows are stamped with the event's own time, else `now` (when it arrived).
    mutating func apply(_ e: RunEvent, runID: String, now: Date = Date()) {
        let date = e.timestamp.map { Date(timeIntervalSince1970: $0) } ?? now
        if let seq = e.seq {
            if let last = lastSeq, seq <= last { return }
            lastSeq = seq
        }
        if let steer = e.pendingSteer?.trimmingCharacters(in: .whitespacesAndNewlines), !steer.isEmpty {
            pendingSteer = steer
        }
        switch e.event {
        case "message.delta":
            appendDelta(e.delta ?? "", at: date)
        case "message.interim":
            if e.alreadyStreamed != true, let text = e.text?.trimmed, !text.isEmpty {
                closeStreaming()
                append(.assistant(id: nextID("a"), text: text, streaming: false), at: date)
            }
        case "tool.started":
            closeStreaming()
            append(.tool(ToolActivity(id: nextID("t"), name: e.tool ?? "tool",
                                            preview: e.preview, state: .running, duration: nil)), at: date)
        case "tool.completed":
            finishTool(named: e.tool, failed: e.isError, duration: e.duration, output: e.preview)
        case "subagent.start":
            closeStreaming()
            append(.tool(ToolActivity(id: nextID("t"), name: "subagent",
                                            preview: e.preview ?? e.text, state: .running, duration: nil)), at: date)
        case "subagent.complete":
            finishTool(named: "subagent", failed: e.isError, duration: e.duration, output: e.text)
        case "approval.request":
            closeStreaming()
            append(.approval(ApprovalRequest(
                id: nextID("p"), runID: runID, requestID: e.requestId, command: e.command,
                description: e.description, choices: e.choices ?? ["once", "deny"], resolvedChoice: nil)), at: date)
        case "approval.responded":
            resolveApproval(requestID: e.requestId, choice: e.choice ?? "resolved")
        case "run.completed":
            finishStreaming(finalOutput: e.output, at: date)
            terminalStatus = "completed"
        case "run.failed":
            closeStreaming()
            appendNotice(e.errorMessage ?? "The run failed.", isError: true, at: date)
            terminalStatus = "failed"
        case "run.cancelled":
            closeStreaming()
            appendNotice("Stopped.", isError: false, at: date)
            terminalStatus = "cancelled"
        case "run.interrupted":
            closeStreaming()
            appendNotice(e.errorMessage ?? "The run was interrupted.", isError: true, at: date)
            terminalStatus = "interrupted"
        case "replay.truncated":
            appendNotice("Some progress was missed while disconnected.", isError: false, at: date)
        default:
            break  // reasoning.available, run.steered, run.stopping, unknown future events
        }
    }

    /// Marks a pending approval as answered locally (optimistic).
    mutating func resolveApproval(requestID: String?, choice: String) {
        guard let idx = items.lastIndex(where: {
            if case .approval(let a) = $0 { return a.resolvedChoice == nil && (requestID == nil || a.requestID == nil || a.requestID == requestID) }
            return false
        }), case .approval(var a) = items[idx] else { return }
        a.resolvedChoice = choice
        items[idx] = .approval(a)
    }

    /// What the agent is doing right now, for the status line and Live Activity.
    var liveStatus: String? {
        for item in items.reversed() {
            switch item {
            case .tool(let tool) where tool.state == .running:
                return ToolInfo.liveLabel(name: tool.name, preview: tool.preview)
            case .approval(let a) where a.resolvedChoice == nil:
                return "Waiting for your approval"
            case .user:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// Tools finished so far in the current turn (since the last user message).
    var toolsThisTurn: Int {
        var n = 0
        for item in items.reversed() {
            if case .user = item { break }
            if case .tool(let t) = item, t.state != .running { n += 1 }
        }
        return n
    }

    var pendingApproval: ApprovalRequest? {
        for item in items.reversed() {
            if case .approval(let a) = item, a.resolvedChoice == nil { return a }
        }
        return nil
    }

    /// Fills "[screenshot]" placeholders with photos saved on this phone (PhotoStore),
    /// so pasted/camera images stay visible after reloads and relaunches.
    mutating func attachStoredPhotos(sessionID: String) {
        let stored = PhotoStore.entries(sessionID: sessionID)
        guard !stored.isEmpty else { return }
        var used = Set<String>()
        for i in items.indices {
            guard case .user(var m) = items[i], m.images.isEmpty, m.placeholderImages > 0 else { continue }
            if let match = stored.first(where: { !used.contains($0.id) && $0.text == m.text && $0.count == m.placeholderImages })
                ?? stored.first(where: { !used.contains($0.id) && $0.count == m.placeholderImages && $0.text.isEmpty == m.text.isEmpty })
                // The gateway keeps only "[screenshot]" for a photo message, dropping its text: take the text from here.
                ?? (m.text.isEmpty ? stored.first(where: { !used.contains($0.id) && $0.count == m.placeholderImages }) : nil) {
                let images = PhotoStore.load(match, sessionID: sessionID)
                if !images.isEmpty {
                    used.insert(match.id)
                    m.images = images
                    if m.text.isEmpty, !match.text.isEmpty { m.text = match.text }
                    m.placeholderImages = 0
                    items[i] = .user(m)
                }
            }
        }
    }

    /// Carries phone-side image data over to freshly loaded history (the server
    /// stores only a placeholder), matching the most recent user turns in order.
    mutating func adoptLocalImages(from old: Transcript) {
        var sent = old.items.compactMap { item -> UserMessage? in
            if case .user(let m) = item, !m.images.isEmpty { return m }
            return nil
        }
        guard !sent.isEmpty else { return }
        for i in items.indices.reversed() {
            guard let next = sent.last else { break }
            if case .user(var m) = items[i], m.images.isEmpty, m.placeholderImages == next.images.count {
                m.images = next.images
                if m.text.isEmpty { m.text = next.text }   // the gateway drops a photo message's text
                m.placeholderImages = 0
                items[i] = .user(m)
                sent.removeLast()
            }
        }
    }

    // MARK: Helpers

    private mutating func append(_ item: ChatItem, at date: Date?) {
        items.append(item)
        if let date { dates[item.id] = date }
    }

    /// The reply is stamped when its first words arrive, not when it finishes.
    private mutating func appendDelta(_ delta: String, at date: Date) {
        if case .assistant(let id, let text, true) = items.last {
            items[items.count - 1] = .assistant(id: id, text: text + delta, streaming: true)
        } else {
            let text = String(delta.drop(while: \.isNewline))
            guard !text.isEmpty else { return }
            append(.assistant(id: nextID("a"), text: text, streaming: true), at: date)
        }
    }

    private mutating func closeStreaming() {
        guard case .assistant(let id, let text, true) = items.last else { return }
        let trimmed = text.trimmed
        if trimmed.isEmpty {
            items.removeLast()
            dates[id] = nil
        } else {
            items[items.count - 1] = .assistant(id: id, text: trimmed, streaming: false)
        }
    }

    private mutating func finishStreaming(finalOutput: String?, at date: Date) {
        let output = finalOutput?.trimmed ?? ""
        if case .assistant(let id, let text, true) = items.last {
            items[items.count - 1] = .assistant(id: id, text: output.isEmpty ? text.trimmed : output, streaming: false)
        } else if !output.isEmpty {
            if case .assistant(_, let text, _) = items.last, text == output { return }
            append(.assistant(id: nextID("a"), text: output, streaming: false), at: date)
        }
    }

    private mutating func finishTool(named name: String?, failed: Bool, duration: Double?, output: String?) {
        guard let idx = items.lastIndex(where: {
            if case .tool(let t) = $0 { return t.state == .running && (name == nil || t.name == name) }
            return false
        }), case .tool(var t) = items[idx] else { return }
        t.state = failed ? .failed : .done
        t.duration = duration
        if let output, !output.isEmpty { t.output = output }
        items[idx] = .tool(t)
    }

    private mutating func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-live-\(counter)"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}


extension Transcript {
    /// Plain-text copy of the conversation for the share sheet.
    func shareText(title: String) -> String {
        var out = [title, ""]
        for item in items {
            switch item {
            case .user(let m):
                let photos = m.images.count + m.placeholderImages
                let note = photos > 0 ? " [\(photos == 1 ? "photo" : "\(photos) photos")]" : ""
                out.append("You:\(note) \(m.text)".trimmingCharacters(in: .whitespaces))
                out.append("")
            case .assistant(_, let text, _):
                out.append("Agent: \(text)")
                out.append("")
            default: break
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Item ids whose text contains `query` (case-insensitive), in order.
    func matches(_ query: String) -> [(id: String, snippet: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return items.compactMap { item in
            let text: String
            switch item {
            case .user(let m): text = m.text
            case .assistant(_, let a, _): text = a
            default: return nil
            }
            guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = (start > text.startIndex ? "…" : "") + text[start..<end]
                .replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
            return (item.id, snippet)
        }
    }
}
