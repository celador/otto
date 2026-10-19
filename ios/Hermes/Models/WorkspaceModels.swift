import Foundation
import Observation
import SwiftUI

// MARK: - Workspaces = Hermes projects (relay /hermes/workspaces)
//
// A workspace is a Hermes project (~/.hermes/projects.db): a folder, a look (icon + color) and a
// kanban board. Chats belong to it by their working folder, the same rule the Hermes desktop uses,
// so moving a chat re-homes it in Hermes (session.workspace.move) and a chat started here shows up
// under the project there too.

struct WorkspaceFolder: Codable, Hashable, Sendable {
    let path: String
    let label: String?
    let isPrimary: Bool?
}

/// A chat as the project tree lists it (any source: Otto, the desktop, Telegram…).
struct WorkspaceSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    let preview: String?
    let source: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
    let model: String?
    let archived: Bool?

    var summary: SessionSummary {
        SessionSummary(id: id, source: source, title: title, preview: preview, model: model, startedAt: startedAt,
                       lastActive: lastActive, messageCount: messageCount, pinned: nil, archived: archived)
    }

    /// Sort key, the same one the relay uses ("newest first").
    var recency: Double { lastActive ?? startedAt ?? 0 }
}

extension WorkspaceSession {
    init(_ s: SessionSummary) {
        self.init(id: s.id, title: s.title, preview: s.preview, source: s.source, startedAt: s.startedAt,
                  lastActive: s.lastActive, messageCount: s.messageCount, model: s.model, archived: s.archived)
    }

    func with(archived: Bool) -> WorkspaceSession {
        WorkspaceSession(id: id, title: title, preview: preview, source: source, startedAt: startedAt,
                         lastActive: lastActive, messageCount: messageCount, model: model, archived: archived)
    }
}

/// Each workspace's last chat list from the relay, on disk so the first open after launch draws at once.
enum WorkspaceSessionCache {
    nonisolated static var defaultURL: URL {
        let d = AppDirs.caches.appendingPathComponent("hermes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("workspace-sessions.json")
    }

    nonisolated static func load(from url: URL = defaultURL) -> [String: [WorkspaceSession]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [WorkspaceSession]].self, from: data)) ?? [:]
    }

    nonisolated static func save(_ cache: [String: [WorkspaceSession]], to url: URL = defaultURL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The chats to draw for a workspace right now, without the network: the last relay list if there is
    /// one, else built from what the app already knows (the workspace's member ids and 5 recent chats,
    /// the main chat list's summaries). Fresher titles/activity from `known` win; chats moved since the
    /// last relay answer (`pending`: session id -> new workspace id, nil = Other chats) are applied.
    nonisolated static func rows(for workspaceID: String, workspace: Workspace?, cached: [WorkspaceSession]?,
                                 known: [SessionSummary], pending: [String: String?] = [:],
                                 others: [String: [WorkspaceSession]] = [:]) -> [WorkspaceSession] {
        let byID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [WorkspaceSession]
        if let cached {
            rows = cached
        } else {
            var seen = Set<String>()
            rows = []
            for r in workspace?.recent ?? [] where seen.insert(r.id).inserted { rows.append(r) }
            for id in workspace?.sessionIds ?? [] where !seen.contains(id) {
                if let s = byID[id] { seen.insert(id); rows.append(WorkspaceSession(s)) }
            }
        }
        // Moved away / moved in since the relay last answered.
        rows.removeAll { r in pending[r.id].map { $0 != workspaceID } ?? false }
        for (sid, target) in pending where target == workspaceID && !rows.contains(where: { $0.id == sid }) {
            if let s = byID[sid] { rows.append(WorkspaceSession(s)) }
            else if let r = others.values.lazy.compactMap({ $0.first { $0.id == sid } }).first { rows.append(r) }
        }
        // Fresher title / activity from the main list.
        rows = rows.map { r in
            guard let s = byID[r.id], (s.lastActive ?? 0) >= (r.lastActive ?? 0) else { return r }
            var fresh = WorkspaceSession(s)
            if fresh.archived == nil, let a = r.archived { fresh = fresh.with(archived: a) }
            return fresh
        }
        return rows.sorted { $0.recency > $1.recency }
    }
}

struct Workspace: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let slug: String?
    var name: String
    var description: String?
    var icon: String?
    var color: String?
    var boardSlug: String?
    var primaryPath: String?
    var archived: Bool?
    var folders: [WorkspaceFolder]?
    var sessionCount: Int?
    var lastActive: Double?
    var sessionIds: [String]?
    var recent: [WorkspaceSession]?

    var isArchived: Bool { archived ?? false }
    var folder: String? { primaryPath ?? folders?.first(where: { $0.isPrimary == true })?.path ?? folders?.first?.path }
    /// "~/code/hermes-ios"
    var shortFolder: String? { folder.map(WorkspaceLook.tildePath) }
    var tint: Color { WorkspaceLook.color(color) ?? Theme.accent }
}

struct WorkspaceList: Decodable, Sendable { let workspaces: [Workspace] }
struct WorkspaceEnvelope: Decodable, Sendable { let workspace: Workspace }
struct WorkspaceSessions: Decodable, Sendable { let sessions: [WorkspaceSession] }
struct WorkspaceFolderChoice: Decodable, Hashable, Identifiable, Sendable {
    let path: String
    let label: String?
    let sessions: Int?
    var id: String { path }
}
struct WorkspaceFolderChoices: Decodable, Sendable { let folders: [WorkspaceFolderChoice] }

/// The fields a create/edit sends. `nil` = leave alone; "" clears icon/color/board.
struct WorkspaceDraft: Sendable {
    var name = ""
    var icon = "folder-library"
    var color = WorkspaceLook.swatches[1]
    var path = ""
    var boardSlug = ""
    var createBoard = false

    var json: [String: Any] {
        var out: [String: Any] = ["name": name.trimmed, "icon": icon, "color": color, "path": path.trimmed,
                                  "board_slug": boardSlug]
        if createBoard { out["create_board"] = true }
        return out
    }
}

// MARK: - Look: Hermes desktop's icon names (codicons) and color swatches, drawn natively

enum WorkspaceLook {
    /// The desktop's project icon set (PROJECT_ICONS), so a workspace looks the same in both apps.
    static let icons: [(codicon: String, symbol: String)] = [
        ("folder-library", "folder"), ("repo", "book.closed"), ("rocket", "paperplane"),
        ("beaker", "flask"), ("flame", "flame"), ("star-full", "star.fill"), ("heart", "heart"),
        ("zap", "bolt"), ("target", "scope"), ("lightbulb", "lightbulb"), ("tools", "hammer"),
        ("device-desktop", "desktopcomputer"), ("device-mobile", "iphone"), ("terminal", "terminal"),
        ("dashboard", "gauge.with.dots.needle.33percent"), ("globe", "globe"),
        ("broadcast", "dot.radiowaves.left.and.right"), ("cloud", "cloud"), ("database", "cylinder.split.1x2"),
        ("package", "shippingbox"), ("book", "book"), ("organization", "person.3"), ("bug", "ladybug"),
        ("shield", "shield"), ("key", "key"), ("gift", "gift"), ("telescope", "binoculars"), ("home", "house"),
    ]

    /// The desktop's 12 swatches: hsl(hue 68% 58%) every 30°.
    static let swatches: [String] = (0..<12).map { "hsl(\($0 * 30) 68% 58%)" }

    /// SF Symbol for a stored icon (a codicon name, or an SF Symbol name typed by hand); nil for emoji.
    static func symbol(_ icon: String?) -> String? {
        guard let icon, !icon.isEmpty else { return "folder" }
        if let hit = icons.first(where: { $0.codicon == icon }) { return hit.symbol }
        if icon.unicodeScalars.contains(where: { !$0.isASCII }) { return nil }   // an emoji
        return icon
    }

    static func color(_ raw: String?) -> Color? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#"), raw.count == 7, let v = UInt32(raw.dropFirst(), radix: 16) {
            return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                         blue: Double(v & 0xFF) / 255)
        }
        if raw.hasPrefix("hsl(") {
            let nums = raw.dropFirst(4).split(whereSeparator: { " ,%)/".contains($0) }).compactMap { Double($0) }
            guard nums.count >= 3 else { return nil }
            return hsl(nums[0], nums[1] / 100, nums[2] / 100)
        }
        return nil
    }

    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return Color(red: r + m, green: g + m, blue: b + m)
    }

    static func tildePath(_ path: String) -> String {
        #if os(macOS)
        // The real home, not the sandbox container that homeDirectoryForCurrentUser returns.
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        #endif
        // On the phone the Mac's home isn't ours: shorten any /Users/<name>/.
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Users" { return "~/" + parts.dropFirst(2).joined(separator: "/") }
        return path
    }

    static func slug(_ name: String) -> String {
        let plain = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let s = plain.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return String(s.prefix(64))
    }
}

/// The workspace glyph: tinted SF Symbol (or the emoji itself) on a soft rounded square.
struct WorkspaceIcon: View {
    let workspace: Workspace?
    var size: CGFloat = 16
    var filled = false

    var body: some View {
        let tint = workspace?.tint ?? .secondary
        Group {
            if let w = workspace, WorkspaceLook.symbol(w.icon) == nil, let icon = w.icon {
                Text(icon).font(.system(size: size * 0.8))
            } else {
                Image(systemName: WorkspaceLook.symbol(workspace?.icon) ?? "folder")
                    .font(.system(size: size * (filled ? 0.55 : 0.8), weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background {
            if filled {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.opacity(0.16))
            }
        }
    }
}

// MARK: - Relay client

extension CompanionClient {
    func workspaces(refresh: Bool = false) async throws -> [Workspace] {
        let data = try await rawRequest("GET", "/hermes/workspaces", query: refresh ? ["refresh": "1"] : [:])
        return try HermesClient.decoder.decode(WorkspaceList.self, from: data).workspaces
    }

    func workspaceSessions(_ id: String) async throws -> [WorkspaceSession] {
        let data = try await rawRequest("GET", "/hermes/workspaces/\(id.pathEscaped)/sessions")
        return try HermesClient.decoder.decode(WorkspaceSessions.self, from: data).sessions
    }

    func workspaceFolders() async throws -> [WorkspaceFolderChoice] {
        let data = try await rawRequest("GET", "/hermes/workspaces/folders")
        return try HermesClient.decoder.decode(WorkspaceFolderChoices.self, from: data).folders
    }

    @discardableResult
    func createWorkspace(_ draft: WorkspaceDraft) async throws -> Workspace {
        let data = try await rawRequest("POST", "/hermes/workspaces", body: try JSONSerialization.data(withJSONObject: draft.json))
        return try HermesClient.decoder.decode(WorkspaceEnvelope.self, from: data).workspace
    }

    @discardableResult
    func updateWorkspace(_ id: String, fields: [String: Any]) async throws -> Workspace {
        let data = try await rawRequest("PATCH", "/hermes/workspaces/\(id.pathEscaped)",
                                        body: try JSONSerialization.data(withJSONObject: fields))
        return try HermesClient.decoder.decode(WorkspaceEnvelope.self, from: data).workspace
    }

    /// The sidebar order (active workspace ids, top first), kept by the relay for every device.
    func setWorkspaceOrder(_ ids: [String]) async throws {
        _ = try await rawRequest("PUT", "/hermes/workspaces/order",
                                 body: try JSONSerialization.data(withJSONObject: ["ids": ids]))
    }

    func archiveWorkspace(_ id: String, restore: Bool = false) async throws {
        _ = try await rawRequest("POST", "/hermes/workspaces/\(id.pathEscaped)/archive",
                                 body: try JSONSerialization.data(withJSONObject: ["restore": restore]))
    }

    func moveSession(_ sessionID: String, to workspaceID: String?) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["session_id": sessionID])
        if let workspaceID {
            _ = try await rawRequest("POST", "/hermes/workspaces/\(workspaceID.pathEscaped)/move-session", body: body)
        } else {
            _ = try await rawRequest("POST", "/hermes/workspaces/unassign-session", body: body)
        }
    }
}

// MARK: - Store

/// Every workspace and which chat belongs to which. Refreshed with the chat list.
@MainActor
@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private(set) var all: [Workspace] = WorkspaceStore.loadSaved()
    private(set) var owner: [String: String] = [:]   // session id -> workspace id
    private(set) var loaded = false
    var errorMessage: String?
    /// Chats moved here before the next refresh confirms it (keeps rows from jumping back).
    private var pendingOwner: [String: String?] = [:]
    /// The relay client from the last load (chats adopt into workspaces through it).
    private var client: CompanionClient?
    /// An order dragged here that the relay hasn't confirmed yet (refreshes keep it instead of snapping back).
    private var orderOverride: [String]?
    private var orderSave: Task<Void, Never>?
    /// Last relay chat list per workspace id (disk-backed): what a workspace draws on its first frame.
    private(set) var sessionCache: [String: [WorkspaceSession]] = WorkspaceSessionCache.load()
    /// The main chat list's summaries (fresh titles, and rows for workspaces never fetched).
    private(set) var known: [SessionSummary] = LocalCache.loadSessions()
    /// Last board per slug (memory only): the Board segment draws at once and refreshes behind.
    private(set) var boards: [String: KanbanBoard] = [:]
    private var kanban: KanbanClient?
    private var prefetching: Task<Void, Never>?
    private var lastPrefetch: Date = .distantPast

    private init() { rebuildOwner() }

    var active: [Workspace] { all.filter { !$0.isArchived } }
    var archived: [Workspace] { all.filter(\.isArchived) }

    func workspace(id: String?) -> Workspace? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    func workspace(forSession id: String?) -> Workspace? {
        guard let id else { return nil }
        if let pending = pendingOwner[id] { return workspace(id: pending) }
        return workspace(id: owner[id])
    }

    /// The chats to show for a workspace now: never waits on the network (see WorkspaceSessionCache.rows).
    func sessions(for workspaceID: String) -> [WorkspaceSession] {
        WorkspaceSessionCache.rows(for: workspaceID, workspace: workspace(id: workspaceID),
                                   cached: sessionCache[workspaceID], known: known, pending: pendingOwner,
                                   others: sessionCache)
    }

    /// True only when the relay (or the workspace's own count) says there's nothing here.
    func isKnownEmpty(_ workspaceID: String) -> Bool {
        guard sessions(for: workspaceID).isEmpty else { return false }
        if let cached = sessionCache[workspaceID] { return cached.isEmpty }
        return (workspace(id: workspaceID)?.sessionCount ?? 0) == 0
    }

    func hasCachedSessions(_ workspaceID: String) -> Bool { sessionCache[workspaceID] != nil }

    /// Fetch one workspace's chats from the relay into the cache (the view redraws in place).
    func refreshSessions(_ workspaceID: String, client: CompanionClient? = nil) async throws {
        guard let c = client ?? self.client else { return }
        let list = try await c.workspaceSessions(workspaceID)
        storeSessions(list, for: workspaceID)
        #if DEBUG
        NSLog("WSFETCH %@ rows=%d", workspaceID, list.count)
        #endif
    }

    private func storeSessions(_ list: [WorkspaceSession], for workspaceID: String) {
        guard sessionCache[workspaceID] != list else { return }
        sessionCache[workspaceID] = list
        WorkspaceSessionCache.save(sessionCache)
    }

    /// The main chat list changed (AppModel.refresh): fresher titles for workspace rows.
    func noteSessions(_ list: [SessionSummary]) {
        if list != known { known = list }
    }

    func noteBoard(_ board: KanbanBoard, slug: String) { boards[slug] = board }

    /// A chat was archived / restored: keep cached workspace rows in step.
    func noteArchived(_ sessionID: String, _ archived: Bool) {
        var changed = false
        for (wid, rows) in sessionCache {
            guard let i = rows.firstIndex(where: { $0.id == sessionID }) else { continue }
            var next = rows
            next[i] = rows[i].with(archived: archived)
            sessionCache[wid] = next
            changed = true
        }
        if changed { WorkspaceSessionCache.save(sessionCache) }
    }

    /// Move a cached row between workspaces at once (the relay confirms on the next fetch).
    private func moveCached(_ sessionID: String, to workspaceID: String?, summary: SessionSummary? = nil) {
        var row = summary.map(WorkspaceSession.init)
        for (wid, rows) in sessionCache where rows.contains(where: { $0.id == sessionID }) {
            if row == nil { row = rows.first { $0.id == sessionID } }
            if wid != workspaceID { sessionCache[wid] = rows.filter { $0.id != sessionID } }
        }
        if row == nil, let s = known.first(where: { $0.id == sessionID }) { row = WorkspaceSession(s) }
        if let workspaceID, let row, var rows = sessionCache[workspaceID] {
            rows.removeAll { $0.id == sessionID }
            rows.insert(row, at: 0)
            sessionCache[workspaceID] = rows.sorted { $0.recency > $1.recency }
        }
        WorkspaceSessionCache.save(sessionCache)
    }

    /// Warm every workspace (chats, and boards when a kanban client is known) so none waits when opened.
    func prefetchAll(force: Bool = false) {
        guard let client, prefetching == nil, force || Date().timeIntervalSince(lastPrefetch) > 20 else { return }
        lastPrefetch = Date()
        #if DEBUG
        NSLog("WSPREFETCH %d workspaces, %d boards", active.count, kanban == nil ? 0 : active.filter { $0.boardSlug?.isEmpty == false }.count)
        #endif
        let ids = active.map(\.id)
        let slugs = Array(Set(active.compactMap { $0.boardSlug.flatMap { $0.isEmpty ? nil : $0 } }))
        let kanban = self.kanban
        prefetching = Task { [self] in
            await withTaskGroup(of: Void.self) { group in
                var jobs: [@Sendable () async -> Void] = ids.map { id in
                    { @Sendable in
                        do {
                            let list = try await client.workspaceSessions(id)
                            await self.storeSessions(list, for: id)
                        } catch {
                            #if DEBUG
                            NSLog("WSPREFETCH %@ failed: %@", id, String(describing: error))
                            #endif
                        }
                    }
                }
                if let kanban {
                    jobs += slugs.map { slug in
                        { @Sendable in
                            if let b = try? await kanban.board(slug) {
                                await self.noteBoard(b, slug: slug)
                            }
                        }
                    }
                }
                var next = 0
                for _ in 0..<min(4, jobs.count) { let j = jobs[next]; next += 1; group.addTask { await j() } }
                while await group.next() != nil, next < jobs.count {
                    let j = jobs[next]; next += 1; group.addTask { await j() }
                }
            }
            self.prefetching = nil
        }
    }

    func load(_ client: CompanionClient?, force: Bool = false, kanban: KanbanClient? = nil, prefetch: Bool = true) async {
        guard let client else { return }
        self.client = client
        if let kanban { self.kanban = kanban }
        do {
            var list = try await client.workspaces(refresh: force)
            if let o = orderOverride {
                if list.filter({ !$0.isArchived }).map(\.id) == o { orderOverride = nil } else { list = Self.ordered(list, by: o) }
            }
            if list != all { all = list }
            pendingOwner.removeAll()
            rebuildOwner()
            loaded = true
            errorMessage = nil
            Self.save(list)
            if prefetch { prefetchAll() }
        } catch {
            #if DEBUG
            NSLog("WSLOAD failed: %@", String(describing: error))
            #endif
            // A view that went away cancelled its refresh: nothing failed.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = (error as? CompanionError)?.errorDescription ?? AppModel.friendly(error)
        }
    }

    /// Reorder the sidebar (drag and drop): applied at once, saved on the relay shortly after the last move.
    func reorder(_ ids: [String]) {
        all = Self.ordered(all, by: ids)
        orderOverride = ids
        Self.save(all)
        orderSave?.cancel()
        orderSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let client = self.client else { return }
            do {
                try await client.setWorkspaceOrder(ids)
            } catch {
                self.orderOverride = nil
                self.errorMessage = "Couldn't save the workspace order: \(AppModel.friendly(error))"
            }
            await self.load(client, force: true)
        }
    }

    /// Active workspaces in `ids` order (unknown ones first, as the relay does); archived ones after.
    static func ordered(_ list: [Workspace], by ids: [String]) -> [Workspace] {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let active = list.filter { !$0.isArchived }
        let fresh = active.filter { rank[$0.id] == nil }
        let known = active.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return fresh + known + list.filter(\.isArchived)
    }

    func move(_ sessionID: String, to workspaceID: String?) async {
        guard let client else { return }
        let from = workspace(forSession: sessionID)?.id
        pendingOwner[sessionID] = .some(workspaceID)
        moveCached(sessionID, to: workspaceID)
        do {
            try await client.moveSession(sessionID, to: workspaceID)
            await load(client, force: true, prefetch: false)
            for id in Set([from, workspaceID].compactMap { $0 }) { try? await refreshSessions(id, client: client) }
        } catch {
            pendingOwner[sessionID] = nil
            errorMessage = "Couldn't move the chat: \(AppModel.friendly(error))"
            for id in Set([from, workspaceID].compactMap { $0 }) { try? await refreshSessions(id, client: client) }
        }
    }

    /// A new chat started inside a workspace: put it in the project's folder on the Mac.
    func adopt(_ sessionID: String, into workspaceID: String, summary: SessionSummary? = nil) async {
        pendingOwner[sessionID] = .some(workspaceID)
        if let summary, !known.contains(where: { $0.id == sessionID }) { known.insert(summary, at: 0) }
        moveCached(sessionID, to: workspaceID, summary: summary)
        do {
            try await client?.moveSession(sessionID, to: workspaceID)
        } catch {
            errorMessage = "The chat started, but couldn't be filed under the workspace: \(AppModel.friendly(error))"
        }
    }

    /// Per-turn note for the agent (API-server runs start in Hermes's default folder).
    func instructions(forSession id: String?, pending workspaceID: String?) -> String? {
        guard let w = workspace(forSession: id) ?? workspace(id: workspaceID), let folder = w.folder else { return nil }
        var note = "This chat is in the \(w.name) workspace; its project folder is \(folder). Your terminal starts "
            + "in the home folder, so cd into \(folder) before running commands, and read/write that project's "
            + "files, unless the user says otherwise."
        if let board = w.boardSlug, !board.isEmpty { note += " The project's kanban board is \"\(board)\"." }
        return note
    }

    func noteChanged(_ w: Workspace) {
        if let i = all.firstIndex(where: { $0.id == w.id }) {
            var merged = w
            merged.sessionCount = all[i].sessionCount
            merged.sessionIds = all[i].sessionIds
            merged.recent = all[i].recent
            merged.lastActive = all[i].lastActive
            all[i] = merged
        } else {
            all.append(w)
        }
    }

    private func rebuildOwner() {
        var map: [String: String] = [:]
        for w in all where !w.isArchived {
            for id in w.sessionIds ?? [] { map[id] = w.id }
        }
        owner = map
    }

    // Last good list, so the sidebar draws workspaces before the relay answers.
    private static let saveKey = "workspaces.saved"
    private static func loadSaved() -> [Workspace] {
        UserDefaults.standard.data(forKey: saveKey).flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []
    }
    private static func save(_ list: [Workspace]) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: saveKey) }
    }
}
