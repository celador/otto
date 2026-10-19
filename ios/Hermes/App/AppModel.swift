import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var client: HermesClient?
    private(set) var sessions: [SessionSummary] = []
    private(set) var isRefreshing = false
    private(set) var serverVersion: String?
    private(set) var modelOptions: ModelOptions?
    /// The desktop app's model shortlist; the last good copy survives relaunches and relay outages.
    private(set) var modelVisibility: DesktopModelVisibility? = DesktopModelVisibility.saved {
        didSet { modelVisibility?.save() }
    }
    /// Telegram's slash-command menu (built-ins + skills), from the relay; built-ins until it answers.
    private(set) var slashCommands: [SlashCommand] = SlashCommands.fallback
    private var slashLoadedAt: Date?
    /// Last refresh failed: the list shown is the cached copy.
    private(set) var isOffline = false
    var errorMessage: String?
    var showArchived = false
    /// Chats with a turn running anywhere right now (relay GET /hermes/running), for the sidebar dots.
    private(set) var runningSessionIDs: Set<String> = []

    init() {
        if let config = KeychainStore.load() {
            client = HermesClient(config: config)
            sessions = LocalCache.loadSessions()
        }
        syncSharedVault()
    }

    /// Lets the widgets reach the relay (limits) without opening the app.
    func syncSharedVault() {
        if let c = companionClient, let key = client?.config.apiKey {
            SharedVault.saveRelay(.init(relay: c.baseURL, apiKey: key))
        } else {
            SharedVault.saveRelay(nil)
        }
        SharedVault.saveGateway(client?.config.baseURL)
    }

    /// For simulator screenshots and previews.
    init(config: HermesConfig) {
        client = HermesClient(config: config)
        sessions = LocalCache.loadSessions()
        syncSharedVault()
    }

    var isConnected: Bool { client != nil }

    /// Optional override for the Kanban relay URL (Settings). Empty = gateway host, port 8651.
    var kanbanRelayOverride: String = UserDefaults.standard.string(forKey: "kanban.relayURL") ?? "" {
        didSet { UserDefaults.standard.set(kanbanRelayOverride, forKey: "kanban.relayURL"); syncSharedVault() }
    }

    /// Same API key as the gateway; the relay adds the dashboard token itself.
    var kanbanClient: KanbanClient? {
        guard let config = client?.config,
              let url = KanbanClient.relayURL(forGateway: config.baseURL, override: kanbanRelayOverride)
        else { return nil }
        return KanbanClient(baseURL: url, apiKey: config.apiKey)
    }

    /// Profiles, skills, memory, status and usage live on the same relay.
    var companionClient: CompanionClient? {
        guard let k = kanbanClient, let key = client?.config.apiKey else { return nil }
        return CompanionClient(baseURL: k.baseURL, apiKey: key)
    }

    /// Validates the gateway (reachable + key accepted) before saving it.
    func connect(urlString: String, apiKey: String) async throws {
        guard let url = Self.normalizedURL(urlString) else { throw HermesError.badURL }
        let key = apiKey.trimmed
        let candidate = HermesClient(config: HermesConfig(baseURL: url, apiKey: key))
        let health = try await candidate.health()
        _ = try await candidate.capabilities()  // 401 here means a wrong key
        try KeychainStore.save(candidate.config)
        client = candidate
        syncSharedVault()
        serverVersion = health.version
        await refresh()
    }

    func disconnect() {
        KeychainStore.clear()
        LocalCache.clear()
        client = nil
        sessions = []
        syncSharedVault()
    }

    func refresh() async {
        guard let client else { return }
        // Weft needs no setup: the Hermes host hands Otto the gateway + token (WeftAutoConfig.swift).
        let weft = WeftStore.shared
        weft.autoSource = { [weak self] in self?.companionClient }
        Task { await weft.autoConfigure() }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await client.sessions(limit: 150).data
            sessions = list
            LocalCache.saveSessions(list)
            WorkspaceStore.shared.noteSessions(list)
            errorMessage = nil
            isOffline = false
            if serverVersion == nil { serverVersion = try? await client.health().version }
            await WorkspaceStore.shared.load(companionClient, kanban: kanbanClient)
        } catch {
            isOffline = true
            errorMessage = Self.friendly(error)
        }
    }

    func refreshRunning() async {
        guard let c = companionClient, let ids = try? await c.runningSessions() else { return }
        if ids != runningSessionIDs { runningSessionIDs = ids }
    }

    /// Sidebar dots: every 8 s while the app is visible (one cheap SQLite read on the Mac per poll).
    func pollRunning(isVisible: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled {
            if isVisible() { await refreshRunning() }
            try? await Task.sleep(for: .seconds(8))
        }
    }

    func loadModelOptions(force: Bool = false) async {
        guard let client, force || modelOptions == nil else { return }
        // Same catalog as the desktop app (relay → dashboard, explicit providers only); the gateway's
        // own list also has ambient providers (Nous Portal, Copilot) the desktop hides.
        let companion = companionClient
        async let desktopOptions = try? companion?.modelOptions(refresh: force)
        async let visibility = try? companion?.modelVisibility(refresh: force)
        let (d, v) = await (desktopOptions, visibility)
        if let v, v.available { modelVisibility = v }
        if let d, !d.providers.isEmpty {
            modelOptions = d
        } else {
            modelOptions = try? await client.modelOptions(refresh: force)
        }
        VoiceTurn.fastAvailable = modelOptions?.supportsFast(VoiceTurn.model) ?? false
    }

    func loadSlashCommands(force: Bool = false) async {
        if !force, let at = slashLoadedAt, Date().timeIntervalSince(at) < 600 { return }
        guard let list = try? await companionClient?.slashCommands(refresh: force), !list.isEmpty else { return }
        slashCommands = list
        slashLoadedAt = Date()
    }

    /// Pinned first, then most recent. Archived hidden unless asked for.
    var visibleSessions: [SessionSummary] {
        sessions
            .filter { showArchived || !($0.archived ?? false) }
            .sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.lastActiveDate > $1.lastActiveDate
            }
    }

    func setPinned(_ session: SessionSummary, _ pinned: Bool) async {
        await patch(session, ["pinned": pinned]) { $0.pinned = pinned }
    }

    func setArchived(_ session: SessionSummary, _ archived: Bool) async {
        if !archived, !sessions.contains(where: { $0.id == session.id }) {
            // Restoring from the Archived screen: that chat isn't in the main list yet.
            guard let client else { return }
            archivedSessions.removeAll { $0.id == session.id }
            do {
                try await client.updateSession(id: session.id, json: try JSONSerialization.data(withJSONObject: ["archived": false]))
                WorkspaceStore.shared.noteArchived(session.id, false)
                await refresh()
            } catch {
                archivedSessions.append(session)
                errorMessage = error.localizedDescription
            }
            return
        }
        await patch(session, ["archived": archived]) { $0.archived = archived }
        WorkspaceStore.shared.noteArchived(session.id, archived)
        if archived {
            var s = session; s.archived = true
            archivedSessions.removeAll { $0.id == s.id }
            archivedSessions.insert(s, at: 0)
        }
    }

    /// Archived chats for the Archived screen (loaded on demand; the main list never has them).
    var archivedSessions: [SessionSummary] = []
    var archivedLoaded = false

    func loadArchived() async {
        guard let c = companionClient else { return }
        do {
            var all: [SessionSummary] = []
            var offset = 0
            while offset < 1000 {
                let page = try await c.archivedSessions(limit: 100, offset: offset)
                all += page.data
                guard page.hasMore == true, !page.data.isEmpty else { break }
                offset += page.data.count
            }
            archivedSessions = all
            archivedLoaded = true
        } catch {
            archivedLoaded = true
            errorMessage = Self.friendly(error)
        }
    }

    func rename(_ session: SessionSummary, to title: String) async {
        let t = title.trimmed
        guard !t.isEmpty else { return }
        await patch(session, ["title": t]) { $0.title = t }
    }

    private func patch(_ session: SessionSummary, _ fields: [String: Any],
                       apply: (inout SessionSummary) -> Void) async {
        guard let client, let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let before = sessions[idx]
        apply(&sessions[idx])
        do {
            let json = try JSONSerialization.data(withJSONObject: fields)
            try await client.updateSession(id: session.id, json: json)
            LocalCache.saveSessions(sessions)
        } catch {
            if let i = sessions.firstIndex(where: { $0.id == session.id }) { sessions[i] = before }
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func friendly(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .timedOut, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed:
                return "Can't reach your gateway. Is Tailscale on?"
            default: break
            }
        }
        return error.localizedDescription
    }

    func delete(_ session: SessionSummary) async {
        guard let client else { return }
        do {
            try await client.deleteSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
            archivedSessions.removeAll { $0.id == session.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func noteCreated(_ session: SessionSummary) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
    }

    // MARK: Parsing

    nonisolated static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmed
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// Parses a pasted `hermes://connect?url=…&key=…` link (copied from the Mac).
    nonisolated static func parseConnectionLink(_ raw: String) -> (url: String, key: String)? {
        guard let comps = URLComponents(string: raw.trimmed),
              comps.scheme == "hermes", comps.host == "connect",
              let url = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              let key = comps.queryItems?.first(where: { $0.name == "key" })?.value,
              !url.isEmpty, !key.isEmpty else { return nil }
        return (url, key)
    }
}
