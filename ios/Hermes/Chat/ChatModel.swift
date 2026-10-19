import Foundation
import Observation

/// Drives one chat session: history, sending, live run streaming, approvals.
///
/// Runs live on the gateway, not the phone. The event stream is only a view:
/// when iOS suspends the app the stream drops, the run keeps going, and
/// `resume()` reattaches with `Last-Event-ID` to replay what was missed.
@MainActor
@Observable
final class ChatModel {
    private(set) var sessionID: String?
    private(set) var transcript = Transcript()
    /// Messages the gateway hasn't accepted yet (sending, or failed with Retry).
    private(set) var pending: [PendingMessage] = []
    private(set) var activeRunID: String?
    private(set) var isLoading = false
    /// True while showing cached history that hasn't been confirmed by the server yet.
    private(set) var isStale = false
    /// Set when this screen creates or renames the session.
    private(set) var title: String?
    /// Per-chat model override; nil = gateway default.
    var modelChoice: ModelChoice? {
        didSet { if let sessionID { ModelPrefs.set(modelChoice, sessionID: sessionID) } }
    }
    /// Per-chat Fast Mode; nil = never touched (Hermes's own setting applies).
    var fastMode: Bool? {
        didSet { if let sessionID { FastPrefs.set(fastMode, sessionID: sessionID) } }
    }
    /// Set by the chat screen from the model's capabilities; fast is only sent when it exists.
    var fastAvailable = false
    /// Workspace a new chat starts in (its session is filed under that Hermes project when created).
    var workspaceID: String?
    /// Slash commands run in this chat and their results (local to the phone, like a terminal log).
    private(set) var slashLog: [SlashEntry] = []
    /// `/queue` turns waiting for the current run to finish.
    private(set) var queued: [String] = []
    /// Model for the next turn only (`/moa`).
    private var oneShotModel: ModelChoice?
    var errorMessage: String?

    private let client: HermesClient
    private var streamTask: Task<Void, Never>?
    private var onSessionCreated: ((SessionSummary) -> Void)?
    private var onRunFinished: (() -> Void)?

    /// `loadCache: false` skips the synchronous read of the saved transcript (the Mac loads it
    /// off the main thread and hands it over with `applyCached`).
    init(client: HermesClient, sessionID: String?,
         onSessionCreated: ((SessionSummary) -> Void)? = nil,
         onRunFinished: (() -> Void)? = nil,
         loadCache: Bool = true) {
        self.client = client
        self.sessionID = sessionID
        self.onSessionCreated = onSessionCreated
        self.onRunFinished = onRunFinished
        if let sessionID {
            modelChoice = ModelPrefs.get(sessionID: sessionID)
            fastMode = FastPrefs.get(sessionID: sessionID)
            if loadCache, let cached = LocalCache.loadMessages(sessionID: sessionID) {
                transcript = Transcript.fromHistory(cached)
                transcript.attachStoredPhotos(sessionID: sessionID)
                isStale = true
            }
        } else {
            modelChoice = ModelPrefs.defaultChoice
        }
        slashLog = SlashLogStore.load(sessionID: sessionID)
        pending = Outbox.restoredAfterLaunch(Outbox.load(sessionID: sessionID))
        Outbox.save(pending, sessionID: sessionID)
    }

    /// The saved transcript, read elsewhere; ignored once the live history (or a turn) is in.
    func applyCached(_ cached: [StoredMessage]) {
        guard let sessionID, items.isEmpty, activeRunID == nil else { return }
        transcript = Transcript.fromHistory(cached)
        transcript.attachStoredPhotos(sessionID: sessionID)
        isStale = true
    }

    var isRunning: Bool { activeRunID != nil }
    private(set) var runStartedAt: Date?

    /// What Hermes is doing right now ("Running a command"), or nil when just thinking.
    var liveStatus: String? { isRunning ? transcript.liveStatus : nil }

    /// The text of the last user turn, for "Try again" after an interrupted reply.
    var lastUserText: String? {
        for item in transcript.items.reversed() {
            if case .user(let m) = item, !m.isSteer, !m.text.isEmpty { return m.text }
        }
        return nil
    }

    func retryLastTurn() async {
        guard !isRunning, let text = lastUserText else { return }
        await send(OutgoingMessage(text: text))
    }
    /// Server/streamed transcript, then anything not yet delivered.
    var items: [ChatItem] { transcript.items + pending.map(\.chatItem) }

    /// What the screen shows: the transcript with slash-command results slotted in where they ran.
    var rows: [ChatRow] { ChatRow.merge(items: items, log: slashLog) }

    /// When a message came through (server time for stored rows, queue time for unsent ones).
    func date(for id: String) -> Date? {
        transcript.date(for: id) ?? pending.first { $0.id == id }?.queuedAt
    }

    /// Rows that open a new day, with that day: the chat draws a day separator above them.
    var dayStarts: [String: Date] {
        ChatTimeline.dayStarts(rows.map { row in
            if case .item(let item) = row { (row.id, date(for: item.id)) } else { (row.id, nil) }
        })
    }

    // MARK: Lifecycle

    /// `remoteRun`: a turn is running elsewhere, so tool calls without a result show as running.
    func load(remoteRun: Bool = false) async {
        guard let sessionID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let messages = try await client.messages(sessionID: sessionID)
            LocalCache.saveMessages(CachedMessage.from(messages), sessionID: sessionID)
            if activeRunID == nil {
                var fresh = Transcript.fromHistory(messages)
                fresh.adoptLocalImages(from: transcript)
                fresh.attachStoredPhotos(sessionID: sessionID)
                if remoteRun { fresh.markOpenToolsRunning() }
                if fresh.items != transcript.items || fresh.dates != transcript.dates { transcript = fresh }
            }
            isStale = false
            let unsent = Set(Outbox.load(sessionID: sessionID).map(\.id))
            pending.removeAll { !unsent.contains($0.id) }
        } catch {
            if transcript.items.isEmpty { errorMessage = error.localizedDescription }
        }
        // Reattach to a run that was in flight when the app was last closed.
        if activeRunID == nil, let runID = RunBookmark.get(sessionID: sessionID) {
            if let status = try? await client.runStatus(id: runID), !status.isTerminal {
                activeRunID = runID
                runStartedAt = runStartedAt ?? Date()
                RunWatcher.shared.track(runID: runID, sessionID: sessionID, title: title ?? "Otto")
                LiveActivityController.shared.start(sessionID: sessionID, title: title ?? "Otto")
                transcript.beginRun()
                attach(runID: runID)
            } else {
                RunBookmark.clear(sessionID: sessionID)
            }
        }
    }

    /// Call when the app returns to the foreground.
    func resume() {
        if let runID = activeRunID {
            if streamTask == nil { attach(runID: runID) }
        } else {
            Task { await load() }
        }
    }

    func detach() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: Actions

    /// Sends a new turn, or — while a run is in progress — steers it.
    /// The message sits in the outbox until the gateway accepts it.
    func send(_ message: OutgoingMessage) async {
        let text = message.text.trimmed
        guard !text.isEmpty || !message.images.isEmpty else { return }
        errorMessage = nil
        let steering = activeRunID != nil
        if steering && text.isEmpty { return }
        let outgoing = PendingMessage(id: UUID().uuidString, text: text,
                                      images: steering ? [] : message.images, isSteer: steering,
                                      voice: message.voice ? true : nil, queuedAt: Date())
        pending.append(outgoing)
        Outbox.add(outgoing, sessionID: sessionID)
        await deliver(outgoing)
    }

    func retry(_ id: String) async {
        guard let i = pending.firstIndex(where: { $0.id == id }), pending[i].error != nil else { return }
        pending[i].error = nil
        Outbox.add(pending[i], sessionID: sessionID)
        await deliver(pending[i])
    }

    func discard(_ id: String) {
        pending.removeAll { $0.id == id }
        Outbox.remove(id: id, sessionID: sessionID)
    }

    private func deliver(_ message: PendingMessage) async {
        do {
            if let runID = activeRunID {
                guard message.images.isEmpty else {
                    throw HermesError.http(409, "Wait for the current reply to finish, then retry.")
                }
                do {
                    try await client.steer(runID: runID, text: message.text)
                    accepted(message, isSteer: true)
                    return
                } catch let error as HermesError where error.runNotAcceptingSteer {
                    // The run ended while the stream was detached (e.g. in the
                    // background). The text belongs in a new turn, not the bin.
                    await finishRun(runID)
                }
            }
            let sid = try await ensureSession(firstMessage: message.text.isEmpty ? "Photo" : message.text)
            let health = await HealthContext.contextIfRelevant(message.text)
            let place = WorkspaceStore.shared.instructions(forSession: sid, pending: workspaceID)
            let context = [health, place].compactMap { $0 }.joined(separator: "\n\n")
            let run = try await client.startRun(
                sessionID: sid, message: OutgoingMessage(text: message.text, images: message.images,
                                                         voice: message.voice == true,
                                                         context: context.isEmpty ? nil : context),
                model: oneShotModel ?? modelChoice, fast: fastAvailable ? fastMode : nil,
                voiceFast: VoiceTurn.fastAvailable, idempotencyKey: message.id)
            oneShotModel = nil
            PhotoStore.save(message.images, text: message.text, sessionID: sid)
            accepted(message, isSteer: false)
            activeRunID = run.runId
            runStartedAt = Date()
            LiveActivityController.shared.start(sessionID: sid, title: title ?? "Otto")
            RunBookmark.set(sessionID: sid, runID: run.runId)
            RunWatcher.shared.track(runID: run.runId, sessionID: sid, title: title ?? "Otto")
            transcript.beginRun()
            attach(runID: run.runId)
        } catch {
            let reason = error.localizedDescription
            if let i = pending.firstIndex(where: { $0.id == message.id }) { pending[i].error = reason }
            Outbox.markFailed(id: message.id, error: reason, sessionID: sessionID)
        }
    }

    /// The gateway has it: move it from the outbox into the transcript.
    private func accepted(_ message: PendingMessage, isSteer: Bool) {
        pending.removeAll { $0.id == message.id }
        Outbox.remove(id: message.id, sessionID: sessionID)
        transcript.appendUser(message.text, images: message.images, isSteer: isSteer, at: message.queuedAt ?? Date())
    }

    func send(_ raw: String) async { await send(OutgoingMessage(text: raw)) }

    func stop() async {
        guard let runID = activeRunID else { return }
        do { try await client.stopRun(id: runID) } catch { errorMessage = error.localizedDescription }
    }

    func answer(_ approval: ApprovalRequest, choice: String) async {
        do {
            try await client.respondToApproval(runID: approval.runID, choice: choice, requestID: approval.requestID)
            transcript.resolveApproval(requestID: approval.requestID, choice: choice)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(to newTitle: String) async {
        let t = newTitle.trimmed
        guard let sessionID, !t.isEmpty else { return }
        do {
            try await client.updateSession(id: sessionID, json: try JSONEncoder().encode(["title": t]))
            title = t
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Slash commands

    /// Adds a result line for a command the phone handled itself.
    func note(_ command: String, _ text: String?, isError: Bool = false, openSessionID: String? = nil) {
        addNote(command, text, isError: isError, openSessionID: openSessionID)
    }

    @discardableResult
    private func addNote(_ command: String, _ text: String?, isError: Bool = false, running: Bool = false,
                         openSessionID: String? = nil) -> String {
        let entry = SlashEntry(command: command, output: text, isError: isError, running: running,
                               afterRow: ChatRow.newestRow(transcript.items), openSessionID: openSessionID)
        slashLog.append(entry)
        saveSlashLog()
        return entry.id
    }

    func updateNote(_ id: String, _ text: String?, isError: Bool = false, openSessionID: String? = nil) {
        guard let i = slashLog.firstIndex(where: { $0.id == id }) else { return }
        slashLog[i].output = text
        slashLog[i].isError = isError
        slashLog[i].running = false
        if let openSessionID { slashLog[i].openSessionID = openSessionID }
        saveSlashLog()
    }

    /// After a command that rewrote the chat (/compress, /undo), its card belongs after the new transcript.
    private func moveNoteToEnd(_ id: String) {
        guard let i = slashLog.firstIndex(where: { $0.id == id }) else { return }
        slashLog[i].afterRow = ChatRow.newestRow(transcript.items)
        saveSlashLog()
    }

    func removeNote(_ id: String) {
        slashLog.removeAll { $0.id == id }
        saveSlashLog()
    }

    func clearSlashLog() {
        slashLog = []
        saveSlashLog()
    }

    private func saveSlashLog() {
        SlashLogStore.save(slashLog, sessionID: sessionID)
    }

    /// `/queue <text>`: sent as the next turn once the current one finishes.
    func enqueue(_ text: String) async {
        if isRunning { queued.append(text) } else { await send(text) }
    }

    /// `/moa <prompt>`: one turn through the Mixture of Agents preset, then back to this chat's model.
    func send(_ text: String, oneShot model: ModelChoice) async {
        oneShotModel = model
        await send(text)
    }

    /// `/bg <prompt>`: a new chat that runs on its own; this one stays open.
    func startBackground(_ prompt: String) async throws -> SessionSummary {
        let session: SessionSummary
        let title = String(("⏳ " + prompt).prefix(60))
        do {
            session = try await client.createSession(title: title)
        } catch let HermesError.http(_, message?) where message.localizedCaseInsensitiveContains("already in use") {
            session = try await client.createSession(title: Self.uniqueTitle(title))
        }
        let run = try await client.startRun(sessionID: session.id, message: OutgoingMessage(text: prompt),
                                            model: modelChoice, fast: fastAvailable ? fastMode : nil,
                                            idempotencyKey: UUID().uuidString)
        ModelPrefs.set(modelChoice, sessionID: session.id)
        RunBookmark.set(sessionID: session.id, runID: run.runId)
        RunWatcher.shared.track(runID: run.runId, sessionID: session.id, title: session.displayTitle)
        return session
    }

    /// Runs a command on the Mac (`POST /hermes/slash`) and shows the result here.
    /// Returns text for the composer when the command hands one back (`/undo`).
    func runOnMac(_ command: String, companion: CompanionClient) async -> String? {
        let id = addNote(command, nil, running: true)
        do {
            let reply = try await companion.slash(sessionID: sessionID, command: command)
            if let moved = reply.sessionId, moved != sessionID {
                updateNote(id, (reply.text ?? "Done.") + "\n\nContinued in a new session.", openSessionID: moved)
                return nil
            }
            switch reply.kind {
            case "send":
                updateNote(id, reply.notice)
                await load()
                if let m = reply.message, !m.isEmpty { await send(m) }
            case "prefill":
                updateNote(id, reply.notice ?? "Back in the composer: edit and send.")
                await load()
                moveNoteToEnd(id)
                return reply.message
            case "open_session":
                updateNote(id, reply.text, openSessionID: reply.sessionId)
            case "error":
                updateNote(id, reply.text ?? "That didn't work.", isError: true)
            default:
                let text = reply.text == "(no output)" ? "Done." : reply.text
                updateNote(id, text ?? "Done.")
                if !isRunning {  // /title, /compress… change the stored chat
                    await load()
                    moveNoteToEnd(id)
                }
            }
        } catch {
            let text = (error as? CompanionError) != nil
                ? "The relay on your Mac is out of date. Restart it to use slash commands."
                : AppModel.friendly(error)
            updateNote(id, text, isError: true)
        }
        return nil
    }

    // MARK: Streaming

    private func attach(runID: String) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.follow(runID: runID)
        }
    }

    private func follow(runID: String) async {
        var backoff: UInt64 = 1
        while !Task.isCancelled, activeRunID == runID {
            do {
                for try await event in client.runEvents(runID: runID, lastSeq: transcript.lastSeq) {
                    transcript.apply(event, runID: runID)
                    LiveActivityController.shared.update(status: transcript.liveStatus,
                                                         tools: transcript.toolsThisTurn,
                                                         needsApproval: transcript.pendingApproval != nil)
                    backoff = 1
                    if transcript.terminalStatus != nil { break }
                }
            } catch {
                if Task.isCancelled { break }
            }
            if Task.isCancelled { break }
            if transcript.terminalStatus != nil { await finishRun(runID); break }
            // Stream ended without a terminal event: ask the server directly.
            if let status = try? await client.runStatus(id: runID), status.isTerminal {
                await finishRun(runID)
                break
            }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 15)
        }
        if activeRunID != runID || Task.isCancelled { streamTask = nil }
    }

    private func finishRun(_ runID: String) async {
        guard activeRunID == runID else { return }
        activeRunID = nil
        streamTask = nil
        runStartedAt = nil
        let answer = transcript.items.reversed().lazy.compactMap { item -> String? in
            if case .assistant(_, let text, _) = item, !text.isEmpty { return text }
            return nil
        }.first
        LiveActivityController.shared.end(status: transcript.terminalStatus ?? "completed",
                                          tools: transcript.toolsThisTurn, answer: answer)
        if let sessionID { RunBookmark.clear(sessionID: sessionID) }
        RunWatcher.shared.finishedInForeground(runID: runID)
        onRunFinished?()
        // A steer that arrived after the agent's last tool call never reached it; the server hands it
        // back. It goes out as the next turn (after the transcript reload below) instead of being lost.
        let replaySteer = transcript.pendingSteer
        if replaySteer == nil, !queued.isEmpty {
            let next = queued.removeFirst()
            Task { await self.send(next) }
        }
        // The server transcript is canonical; replace the streamed view with it,
        // but keep this run's error/stop notice and phone-side images visible.
        if let sessionID, let messages = try? await client.messages(sessionID: sessionID) {
            LocalCache.saveMessages(CachedMessage.from(messages), sessionID: sessionID)
            var fresh = Transcript.fromHistory(messages)
            fresh.adoptLocalImages(from: transcript)
            fresh.attachStoredPhotos(sessionID: sessionID)
            if case .notice(let id, let text, let isError) = transcript.items.last {
                fresh.appendNotice(text, isError: isError, at: transcript.date(for: id))
            }
            transcript = fresh
        }
        if let replaySteer, activeRunID == nil {
            // After this run's follow task has wound down (it clears `streamTask` on the way out).
            Task { await self.send(OutgoingMessage(text: replaySteer)) }
        }
    }

    /// `/new <name>`: the next new chat's title.
    static var pendingNewTitle: String?

    private func ensureSession(firstMessage: String) async throws -> String {
        if let sessionID { return sessionID }
        let title = String((Self.pendingNewTitle ?? SkillInvocation.describe(firstMessage) ?? firstMessage).prefix(60))
        Self.pendingNewTitle = nil
        let session: SessionSummary
        do {
            session = try await client.createSession(title: title)
        } catch let HermesError.http(_, message?) where message.localizedCaseInsensitiveContains("already in use") {
            // Hermes titles are unique; the same first message twice gets a suffix. The gateway says
            // "Title '…' is already in use by session …".
            session = try await client.createSession(title: Self.uniqueTitle(title))
        }
        sessionID = session.id
        Outbox.move(fromNewChatTo: session.id)
        SlashLogStore.save([], sessionID: nil)
        saveSlashLog()
        self.title = session.displayTitle
        ModelPrefs.set(modelChoice, sessionID: session.id)
        FastPrefs.set(fastMode, sessionID: session.id)
        if let workspaceID { await WorkspaceStore.shared.adopt(session.id, into: workspaceID, summary: session) }
        onSessionCreated?(session)
        return session.id
    }
}

extension ChatModel {
    /// "hi" → "hi · 22:41" (falls back to a short random tag if that's taken too).
    nonisolated static func uniqueTitle(_ base: String, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "\(base.prefix(48)) · \(f.string(from: now))"
    }
}

/// Remembers the in-flight run per session so a relaunch can reattach.
enum RunBookmark {
    private static func key(_ sessionID: String) -> String { "activeRun.\(sessionID)" }
    static func get(sessionID: String) -> String? { UserDefaults.standard.string(forKey: key(sessionID)) }
    static func set(sessionID: String, runID: String) { UserDefaults.standard.set(runID, forKey: key(sessionID)) }
    static func clear(sessionID: String) { UserDefaults.standard.removeObject(forKey: key(sessionID)) }
}

/// Per-chat model overrides, plus the default for new chats.
enum FastPrefs {
    private static func key(_ sessionID: String) -> String { "fast.\(sessionID)" }
    static func get(sessionID: String) -> Bool? { UserDefaults.standard.object(forKey: key(sessionID)) as? Bool }
    static func set(_ on: Bool?, sessionID: String) {
        if let on { UserDefaults.standard.set(on, forKey: key(sessionID)) }
        else { UserDefaults.standard.removeObject(forKey: key(sessionID)) }
    }
}

enum ModelPrefs {
    private static func key(_ sessionID: String) -> String { "model.\(sessionID)" }
    private static let defaultKey = "model.default"

    static func get(sessionID: String) -> ModelChoice? { decode(key(sessionID)) }
    static func set(_ choice: ModelChoice?, sessionID: String) { encode(choice, key(sessionID)) }
    static var defaultChoice: ModelChoice? {
        get { decode(defaultKey) }
        set { encode(newValue, defaultKey) }
    }

    private static func decode(_ key: String) -> ModelChoice? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ModelChoice.self, from: $0) }
    }
    private static func encode(_ choice: ModelChoice?, _ key: String) {
        if let choice, let data = try? JSONEncoder().encode(choice) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
