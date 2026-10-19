import Foundation

// Wire models for the Hermes API server (gateway/platforms/api_server*.py).
// Decoded with `.convertFromSnakeCase`.

struct HermesConfig: Codable, Equatable, Sendable {
    var baseURL: URL
    var apiKey: String
}

struct Capabilities: Decodable, Sendable {
    struct Features: Decodable, Sendable {
        let runEventsSse: Bool?
        let runApprovalResponse: Bool?
        let runStop: Bool?
        let sessionChat: Bool?
    }
    let platform: String?
    let model: String?
    let features: Features?
}

struct Health: Decodable, Sendable {
    let status: String
    let version: String?
}

struct SessionSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let source: String?
    var title: String?
    let preview: String?
    let model: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
    var pinned: Bool?
    var archived: Bool?
    /// The gateway's running cost for this chat (estimated from token prices; actual when billed).
    var estimatedCostUsd: Double? = nil
    var actualCostUsd: Double? = nil

    var isPinned: Bool { pinned ?? false }
    var cost: Double? {
        guard estimatedCostUsd != nil || actualCostUsd != nil else { return nil }
        return max(actualCostUsd ?? 0, estimatedCostUsd ?? 0)
    }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return SkillInvocation.describe(title) ?? title
        }
        if let preview, !preview.isEmpty { return HistoryCleaner.userText(preview) }
        return "New chat"
    }

    var lastActiveDate: Date {
        Date(timeIntervalSince1970: lastActive ?? startedAt ?? 0)
    }
}

struct SessionList: Decodable, Sendable {
    let data: [SessionSummary]
    let hasMore: Bool?
}

struct SessionEnvelope: Decodable, Sendable {
    let session: SessionSummary
}

struct ToolCall: Codable, Hashable, Sendable {
    struct Function: Codable, Hashable, Sendable {
        let name: String
        let arguments: String?
    }
    let id: String?
    let function: Function?
}

/// A row from `GET /api/sessions/{id}/messages`.
struct StoredMessage: Decodable, Sendable {
    let id: Int
    let role: String
    let content: String?
    let toolCallId: String?
    let toolCalls: [ToolCall]?
    let toolName: String?
    let timestamp: Double?
    let displayKind: String?

    enum CodingKeys: String, CodingKey {
        case id, role, content, toolCallId, toolCalls, toolName, timestamp, displayKind
    }

    init(id: Int, role: String, content: String?, toolCallId: String? = nil, toolCalls: [ToolCall]? = nil,
         toolName: String? = nil, timestamp: Double? = nil, displayKind: String? = nil) {
        self.id = id; self.role = role; self.content = content; self.toolCallId = toolCallId
        self.toolCalls = toolCalls; self.toolName = toolName; self.timestamp = timestamp
        self.displayKind = displayKind
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        // Multimodal user turns store content as an array of parts; keep the text parts.
        if let text = try? c.decodeIfPresent(String.self, forKey: .content) {
            content = text
        } else if let parts = try? c.decodeIfPresent([ContentPart].self, forKey: .content) {
            content = parts.compactMap(\.text).joined(separator: "\n")
        } else {
            content = nil
        }
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolCalls = try? c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        timestamp = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
        displayKind = try? c.decodeIfPresent(String.self, forKey: .displayKind)
    }

    private struct ContentPart: Decodable { let text: String? }
}

struct MessageList: Decodable, Sendable {
    let data: [StoredMessage]
}

struct RunAccepted: Decodable, Sendable {
    let runId: String
    let status: String
}

struct RunStatus: Decodable, Sendable {
    let runId: String
    let status: String
    let output: String?

    static let terminal: Set<String> = ["completed", "failed", "cancelled", "interrupted"]
    var isTerminal: Bool { Self.terminal.contains(status) }
}

/// One event from `GET /v1/runs/{id}/events`. The event name is in the JSON
/// payload (`"event"`), not the SSE `event:` field.
struct RunEvent: Decodable, Equatable, Sendable {
    let event: String
    let runId: String?
    let seq: Int?
    let delta: String?
    let text: String?
    let tool: String?
    let preview: String?
    let duration: Double?
    /// `tool.completed` sends `error: Bool`; `run.failed` sends `error: String`.
    let isError: Bool
    let errorMessage: String?
    let output: String?
    let alreadyStreamed: Bool?
    let command: String?
    let description: String?
    let choices: [String]?
    let requestId: String?
    let choice: String?
    /// Terminal events: steer text the agent never got to (no tool call came after it). Replay it.
    let pendingSteer: String?
    /// When the gateway emitted the event (unix seconds); replays after a reconnect keep the original time.
    let timestamp: Double?

    enum CodingKeys: String, CodingKey {
        case event, runId, seq, delta, text, tool, preview, duration, error, output,
             alreadyStreamed, command, description, choices, requestId, choice, pendingSteer, timestamp
    }

    init(event: String, seq: Int? = nil, delta: String? = nil, text: String? = nil,
         tool: String? = nil, preview: String? = nil, duration: Double? = nil,
         isError: Bool = false, errorMessage: String? = nil, output: String? = nil,
         alreadyStreamed: Bool? = nil, command: String? = nil, description: String? = nil,
         choices: [String]? = nil, requestId: String? = nil, choice: String? = nil, pendingSteer: String? = nil,
         timestamp: Double? = nil) {
        self.event = event; self.runId = nil; self.seq = seq; self.delta = delta; self.text = text
        self.tool = tool; self.preview = preview; self.duration = duration
        self.isError = isError; self.errorMessage = errorMessage; self.output = output
        self.alreadyStreamed = alreadyStreamed; self.command = command
        self.description = description; self.choices = choices
        self.requestId = requestId; self.choice = choice; self.pendingSteer = pendingSteer
        self.timestamp = timestamp
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
        delta = try? c.decodeIfPresent(String.self, forKey: .delta)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        tool = try? c.decodeIfPresent(String.self, forKey: .tool)
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .error) {
            isError = flag
            errorMessage = nil
        } else if let message = try? c.decodeIfPresent(String.self, forKey: .error) {
            isError = true
            errorMessage = message
        } else {
            isError = false
            errorMessage = nil
        }
        output = try? c.decodeIfPresent(String.self, forKey: .output)
        alreadyStreamed = try? c.decodeIfPresent(Bool.self, forKey: .alreadyStreamed)
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        choices = try? c.decodeIfPresent([String].self, forKey: .choices)
        requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
        choice = try? c.decodeIfPresent(String.self, forKey: .choice)
        pendingSteer = try? c.decodeIfPresent(String.self, forKey: .pendingSteer)
        timestamp = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
    }
}

struct APIErrorBody: Decodable, Sendable {
    struct Inner: Decodable, Sendable { let message: String? ; let code: String? }
    let error: Inner?
}

enum HermesError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case http(Int, String?)
    case badURL

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Not connected to an agent server."
        case .unauthorized: "The server rejected the access token."
        case .http(let code, let message): message ?? "The server returned HTTP \(code)."
        case .badURL: "That server address isn't valid."
        }
    }
}

/// `GET /api/model/options`.
struct ModelOptions: Decodable, Sendable {
    struct Provider: Decodable, Identifiable, Sendable {
        let slug: String
        let name: String
        let isCurrent: Bool?
        let authenticated: Bool?
        let models: [String]?
        /// The desktop's default shortlist for aggregators (`featured_models`, one flagship per lab).
        let featuredModels: [String]?
        /// Per-model capabilities (`fast` = Anthropic Fast Mode / OpenAI Priority). Keys went through the
        /// decoder's snake-case conversion, so look them up with `capability(for:)`.
        let capabilities: [String: Capability]?
        var id: String { slug }

        struct Capability: Decodable, Sendable { let fast: Bool? }

        enum CodingKeys: String, CodingKey { case slug, name, isCurrent, authenticated, models, featuredModels, capabilities }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slug = try c.decode(String.self, forKey: .slug)
            name = try c.decode(String.self, forKey: .name)
            isCurrent = try? c.decodeIfPresent(Bool.self, forKey: .isCurrent)
            authenticated = try? c.decodeIfPresent(Bool.self, forKey: .authenticated)
            models = try? c.decodeIfPresent([String].self, forKey: .models)
            featuredModels = try? c.decodeIfPresent([String].self, forKey: .featuredModels)
            // Capabilities are optional garnish: a shape change must never break the model list.
            capabilities = try? c.decodeIfPresent([String: Capability].self, forKey: .capabilities)
        }

        func capability(for model: String) -> Capability? {
            guard let capabilities else { return nil }
            if let c = capabilities[model] { return c }
            // JSONDecoder's .convertFromSnakeCase also rewrites dictionary keys ("a_b" -> "aB").
            let parts = model.split(separator: "_", omittingEmptySubsequences: false)
            guard parts.count > 1 else { return nil }
            let camel = parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined()
            return capabilities[camel]
        }
    }
    let providers: [Provider]
    let model: String?
    let provider: String?

    /// Whether fast mode exists for this chat's model (nil choice = the gateway default).
    func supportsFast(_ choice: ModelChoice?) -> Bool {
        guard let slug = choice?.provider ?? provider, let model = choice?.model ?? model,
              let p = providers.first(where: { $0.slug == slug }) else { return false }
        return p.capability(for: model)?.fast ?? false
    }

    /// Providers worth showing: authenticated, with models.
    var usable: [Provider] {
        providers.filter { ($0.authenticated ?? false) && !($0.models ?? []).isEmpty }
            .sorted { ($0.isCurrent ?? false) && !($1.isCurrent ?? false) }
    }
}

/// A per-chat model override sent with each run (`model` + `provider`).
struct ModelChoice: Codable, Hashable, Sendable {
    var provider: String
    var model: String

    var shortName: String {
        let base = model.split(separator: "/").last.map(String.init) ?? model
        return base
    }
}

/// What the user sends: text plus optional JPEG images.
struct OutgoingMessage: Sendable {
    var text: String
    var images: [Data] = []
    /// Spoken in voice mode: Hermes is asked to answer in short spoken sentences.
    var voice = false
    /// Extra notes for this run only (e.g. an Apple Health summary); not shown in the transcript.
    var context: String? = nil
}

enum VoiceTurn {
    /// Voice must feel instant (John): every spoken turn runs on Haiku with low thinking, for that run
    /// only. Fast Mode is added when the gateway offers it for this model (`fastAvailable`).
    nonisolated static let model = ModelChoice(provider: "anthropic", model: "claude-haiku-5-5")
    nonisolated static let reasoningEffort = "low"
    /// Voice turns skip Honcho entirely (John, 2026-10-14): `model_options.memory = false` makes the
    /// gateway build that run's agent without the external memory provider, so the first turn has no
    /// memory wait. Typed turns keep Honcho.
    nonisolated static let memory = false
    /// Set from /api/model/options when it loads.
    @MainActor static var fastAvailable = false

    /// Same note Hermes's desktop voice mode adds to spoken turns, plus: long work goes to the background.
    nonisolated static let instructions = """
    This message is a voice transcript from a live spoken conversation (it may contain mis-hearings \
    and corrections; use the latest intent). Your reply will be read aloud: answer in plain \
    conversational sentences, keep it short (a few sentences unless asked for detail), no markdown, \
    no lists, no code blocks, no URLs. Do the work with your tools as usual; only the final facts \
    need to be spoken. Do not claim an action succeeded before it actually did. The user is waiting \
    on the line: if the work will take more than about 30 seconds, start it in the background \
    (delegate_task, or a background process), reply at once that it has started and what it is, and \
    report the result when it is done.
    """
}
