import AppKit
import SwiftUI

// MARK: - Local server (this Mac)

/// The Hermes server on this Mac. Otto is sandboxed (Mac App Store), so it can't read
/// ~/.hermes/.env: it pairs once through the relay instead (`LocalPairing`: the relay shows an
/// Allow dialog with a code on this Mac) and keeps the URL + key in the Keychain like any server.
enum LocalServer {
    static let modeKey = "mac.connection"   // "local" (default) or "custom"
    /// "https://<host>:8642" for the tailnet host set at build time (OTTO_DEFAULT_HOST in
    /// Config/Local.xcconfig → Info.plist HermesDefaultHost); nil when none is set, and the
    /// "Use Tailscale" buttons are hidden (enter the server under "Or enter another server").
    static var tailscaleURL: String? { tailscaleURL(host: Bundle.main.object(forInfoDictionaryKey: "HermesDefaultHost") as? String) }

    static func tailscaleURL(host: String?) -> String? {
        let h = (host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.hasPrefix("$(") else { return nil }
        return "https://\(h):8642"
    }
    static let defaultURL = "http://127.0.0.1:8642"

    static var useLocal: Bool {
        get { (UserDefaults.standard.string(forKey: modeKey) ?? "local") == "local" }
        set { UserDefaults.standard.set(newValue ? "local" : "custom", forKey: modeKey) }
    }

    static func isLocal(_ client: HermesClient?) -> Bool {
        guard let url = client?.config.baseURL else { return false }
        return KanbanClient.isLoopback(url)
    }

    /// The key Otto already holds (current server, else the Keychain).
    @MainActor static func savedKey(_ app: AppModel) -> String? {
        app.client?.config.apiKey ?? KeychainStore.load()?.apiKey
    }
}

/// "Use This Mac" / "Use Tailscale", shared by the connect screen and Settings → Connection.
@MainActor
@Observable
final class MacPairingFlow {
    /// The code the relay's dialog shows, while it waits for the click.
    var code: String?
    var busy = false
    var error: String?
    var message: String?
    private var task: Task<Void, Never>?
    /// The connect screen pairs by itself once per launch (first run on this Mac: one click).
    static var autoTried = false

    func useThisMac(_ app: AppModel, quietIfNoRelay: Bool = false) {
        run(done: "Connected to this Mac.", quietIfNoRelay: quietIfNoRelay) {
            // A key Otto already has (e.g. from Tailscale) is the same server's key: try it first.
            if let key = LocalServer.savedKey(app),
               (try? await app.connect(urlString: LocalServer.defaultURL, apiKey: key)) != nil {
                LocalServer.useLocal = true
                return
            }
            let r = try await self.pair()
            try await app.connect(urlString: r.gateway.absoluteString, apiKey: r.apiKey)
            LocalServer.useLocal = true
        }
    }

    func useTailscale(_ app: AppModel) {
        guard let url = LocalServer.tailscaleURL else { return }
        run(done: "Connected over Tailscale.") {
            let key: String
            if let saved = LocalServer.savedKey(app) { key = saved } else { key = try await self.pair().apiKey }
            try await app.connect(urlString: url, apiKey: key)
            LocalServer.useLocal = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        code = nil
        busy = false
    }

    private func pair() async throws -> LocalPairing.Result {
        defer { code = nil }
        return try await LocalPairing().pair { start in
            await MainActor.run { self.code = start.displayCode }
        }
    }

    private func run(done: String, quietIfNoRelay: Bool = false, _ work: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        busy = true; error = nil; message = nil
        task = Task {
            defer { if !Task.isCancelled { busy = false; code = nil } }
            do {
                try await work()
                message = done
            } catch is CancellationError {
            } catch LocalPairing.Failure.noRelay where quietIfNoRelay {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? LocalPairing.Failure)?.errorDescription ?? AppModel.friendly(error)
            }
        }
    }
}

extension AppModel {
    static func macLaunchModel() -> AppModel {
        #if DEBUG
        let d = UserDefaults.standard
        if let url = d.string(forKey: "hermes.url").flatMap(AppModel.normalizedURL), let key = d.string(forKey: "hermes.key") {
            return AppModel(config: HermesConfig(baseURL: url, apiKey: key))
        }
        #endif
        return AppModel()   // the Keychain (paired with this Mac, Tailscale or a custom server)
    }
}

// MARK: - Root

struct MacRootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.isConnected {
            MacShell()
        } else {
            MacConnectView()
        }
    }
}

/// Which chat/screen a window shows. Kept apart from the sidebar highlight so a new chat
/// that gets its session id keeps its view (and its streaming reply) instead of reloading.
enum MacRoute: Hashable {
    case newChat(UUID)
    case chat(SessionSummary)
    case screen(Screen)
    /// A running card's worker session, read-only (click a running card on the board).
    case watch(WatchTarget)
}

enum SidebarItem: Hashable {
    case chat(String)
    case screen(String)
}

/// Equatable by a per-window id, so publishing it from `body` doesn't invalidate the menu
/// commands (and through them the scene) on every render — that loop pegged the main thread.
struct ShellActions: Equatable {
    let id: UUID
    /// Inside a workspace (enables Exit Workspace and the board/usage toggles).
    var inWorkspace = false
    var newChat: () -> Void
    var refresh: () -> Void
    var exitWorkspace: () -> Void = {}
    var toggleTerminal: () -> Void = {}
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.inWorkspace == b.inWorkspace }
}

extension FocusedValues {
    @Entry var shellActions: ShellActions? = nil
}

// MARK: - Shell: sidebar + detail

struct MacShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("mac.openChat") private var openChat = ""
    @AppStorage("mac.workspaceExpanded") private var workspaceExpanded = true
    @State private var route: MacRoute = .newChat(UUID())
    @State private var currentSessionID: String?
    @State private var query = ""
    @State private var draggingWorkspace: String?
    /// Sidebar sections folded away ("workspaces", "menu", "pinned", "recents"), remembered across launches.
    @AppStorage("mac.collapsedSections") private var collapsedRaw = ""
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var deleting: SessionSummary?
    @State private var restored = false
    @State private var windowID = UUID()
    /// One clock for every row's "13h" label, ticked by the refresh loop (no per-row timers).
    @State private var now = Date()
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The workspace the open new chat starts in ("New chat in <workspace>").
    @State private var newChatWorkspace: String?
    @State private var creatingWorkspace = false
    @State private var workspaces = WorkspaceStore.shared
    @AppStorage("mac.expandedWorkspaces") private var expandedRaw = ""
    /// The workspace this window is "in" (sidebar = its chats, detail = chat + board + usage).
    @State private var mode = WorkspaceMode()
    /// Workspace row a chat is being dragged over (highlighted).
    @State private var chatHover: String?
    @State private var exitHover = false
    @AppStorage(DashboardPrefs.showBoard) private var showBoard = true
    @AppStorage(DashboardPrefs.showUsage) private var showUsage = true
    @AppStorage(DashboardPrefs.showWeft) private var showWeft = true
    @AppStorage(DashboardPrefs.showPanel) private var showPanel = true
    /// Terminal pane (Ghostty) under the chat: its tabs live as long as the window.
    @State private var terminalTabs = TerminalTabs()
    @SceneStorage("mac.terminalOpen") private var terminalOpen = false
    @State private var terminalKeys = MacTerminalKeys()
    /// Where "← Back to your chat" returns to from watching a card.
    @State private var watchReturn: MacRoute?

    private var chats: [SessionSummary] {
        app.sessions.filter { !($0.archived ?? false) && !SessionKind.isAutomated($0) }
            .sorted { $0.lastActiveDate > $1.lastActiveDate }
    }

    private var results: [SessionSummary] {
        let q = query.trimmed.lowercased()
        return app.sessions.filter {
            $0.displayTitle.lowercased().contains(q) || ($0.preview ?? "").lowercased().contains(q)
        }
        .sorted { $0.lastActiveDate > $1.lastActiveDate }
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            switch route {
            case .newChat: currentSessionID.map { .chat($0) }
            case .chat(let s): .chat(s.id)
            case .screen(let s): .screen(s.storageKey ?? "")
            case .watch: currentSessionID.map { .chat($0) }
            }
        } set: { item in
            switch item {
            case .chat(let id)?:
                if id == currentSessionID { return }   // already showing it (maybe as the new chat)
                if let s = app.sessions.first(where: { $0.id == id }) { go(.chat(s)) }
            case .screen(let key)?:
                if let s = Screen.from(storageKey: key) { go(.screen(s)) }
            case nil: break
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            MacTerminalDock(isOpen: $terminalOpen, tabs: terminalTabs, cwd: terminalFolder) {
                detailArea
                    .background(Color(.systemBackground))
            }
        }
        .background(WindowReader { terminalKeys.window = $0 })
        .onAppear {
            terminalKeys.toggle = { toggleTerminal() }
            terminalKeys.newTab = { newTerminalTab() }
            terminalKeys.closeTab = { closeTerminalTab() }
            terminalKeys.install()
        }
        .onDisappear {
            terminalKeys.remove()
            terminalTabs.closeAll()
        }
        .task {
            await app.refresh()
            restore()
            if let c = app.companionClient { await LimitsStore.shared.load(c) }
        }
        .task {
            // Keep the sidebar fresh (chats started on the phone, Telegram or cron) while open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = .now
                if scenePhase != .background { await app.refresh() }
            }
        }
        .task { await app.pollRunning(isVisible: { scenePhase != .background }) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchRequest.notification)) { _ in
            guard activeState == .key, LaunchRequest.take() != nil else { return }
            newChat()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouter.openSession)) { note in
            guard activeState == .key, let id = note.userInfo?["sessionID"] as? String else { return }
            Task {
                if !app.sessions.contains(where: { $0.id == id }) { await app.refresh() }
                if let s = app.sessions.first(where: { $0.id == id }) { go(.chat(s)) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchCard)) { note in
            // The window whose board was clicked is the key window (only it reacts).
            guard activeState == .key || DebugFlags.forceActive, let t = note.object as? WatchTarget else { return }
            if case .watch = route {} else { watchReturn = route }
            route = .watch(t)
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatNav.closeChat)) { _ in
            guard activeState == .key else { return }
            newChat()
        }
        .focusedSceneValue(\.shellActions, ShellActions(
            id: windowID,
            inWorkspace: mode.isActive,
            newChat: { newChat() },
            refresh: { Task { await app.refresh() } },
            exitWorkspace: { exitWorkspace() },
            toggleTerminal: { toggleTerminal() }
        ))
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let s = renaming { Task { await app.rename(s, to: renameText) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = deleting {
                    Task {
                        await app.delete(s)
                        if s.id == currentSessionID { newChat() }
                    }
                }
                deleting = nil
            }
        } message: {
            Text("It's removed from your agent server too.")
        }
    }

    // MARK: Sidebar (Hermes desktop density: 28pt rows, dot + title + age)

    /// Global screens that aren't about one project: kept in the footer's More menu.
    private static let more: [(String, String, Screen)] = [
        ("Board", "rectangle.split.3x1", .board),
        ("Automations", "clock", .automations),
        ("Changes", "point.3.connected.trianglepath.dotted", .changes),
        ("Artifacts", "doc.on.doc", .artifacts),
        ("Agents", "person.2", .agents),
        ("Skills", "sparkles", .skills),
        ("Memory", "brain", .memory),
        ("Usage", "chart.bar", .usage),
        ("Archived", "archivebox", .archived),
    ]

    /// Board, Automations, Usage… as sidebar rows under a "Menu" header that folds away.
    @ViewBuilder private var menuSection: some View {
        sectionHeader("Menu", icon: "square.grid.2x2", key: "menu")
        if !isCollapsed("menu") {
            ForEach(Self.more, id: \.0) { title, icon, screen in destinationRow(title, icon, screen) }
        }
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private func isCollapsed(_ key: String) -> Bool { collapsed.contains(key) }
    private func toggleSection(_ key: String) {
        var set = collapsed
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.snappy(duration: 0.18)) { collapsedRaw = set.sorted().joined(separator: ",") }
    }

    /// Clickable section header: title + chevron. Folded, it shows the item count and a pulsing
    /// dot when something inside is running, so nothing hides silently.
    private func sectionHeader(_ title: String, icon: String, key: String, count: Int = 0, running: Bool = false) -> some View {
        let folded = isCollapsed(key)
        return Button { toggleSection(key) } label: {
            HStack(spacing: 4) {
                SidebarHeader(title: title, icon: icon, accent: true)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
                Spacer(minLength: 0)
                if folded {
                    if running { PulsingDot(size: 7).padding(.top, 10).help("Something here is working…") }
                    if count > 0 {
                        Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            .padding(.top, 10)
                    }
                }
            }
            .padding(.trailing, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folded ? "Show \(title)" : "Hide \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(folded ? "Collapsed, \(count)" : "Expanded")
        .id("section." + key)
    }

    private func isSelected(_ screen: Screen) -> Bool {
        if case .screen(let s) = route { return s == screen }
        return false
    }

    private func isSelected(_ s: SessionSummary) -> Bool { s.id == currentSessionID }

    /// Pinned stay pinned; the rest of the flat list is what no workspace claims.
    private var otherChats: [SessionSummary] {
        chats.filter { !$0.isPinned && workspaces.workspace(forSession: $0.id) == nil }
    }

    private var expanded: Set<String> { Set(expandedRaw.split(separator: ",").map(String.init)) }

    private func toggleExpanded(_ id: String) {
        var e = expanded
        if e.contains(id) { e.remove(id) } else { e.insert(id) }
        withAnimation(.snappy(duration: 0.18)) { expandedRaw = e.sorted().joined(separator: ",") }
    }

    private var sidebar: some View {
        Group {
            if let id = mode.activeID {
                workspaceSidebar(id)
            } else {
                allChatsSidebar
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let error = workspaces.errorMessage { errorToast(error) }
                statusFooter
            }
        }
        .background(MacPalette.sidebar)
        .onExitCommand { if mode.isActive { exitWorkspace() } }
        .sheet(isPresented: $creatingWorkspace) {
            WorkspaceEditor { w in enterWorkspace(w.id) }
        }
        #if DEBUG
        .task { if UserDefaults.standard.bool(forKey: "hermes.newWorkspace") { creatingWorkspace = true } }
        #endif
    }

    /// A failed move (drag and drop, menus): says so for a few seconds; the row is already back.
    private func errorToast(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { workspaces.errorMessage = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10).padding(.bottom, 6)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(5))
            if workspaces.errorMessage == text { workspaces.errorMessage = nil }
        }
    }

    // MARK: Inside a workspace: back arrow + that workspace's chats only

    private func workspaceSidebar(_ id: String) -> some View {
        let w = workspaces.workspace(id: id)
        let rows = WorkspaceRouting.sidebarRows(workspaces.sessions(for: id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                Button { exitWorkspace() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 16)
                        WorkspaceIcon(workspace: w, size: 18, filled: true)
                        Text(w?.name ?? "Workspace").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if exitHover {
                            Text("Remove from workspace").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(exitHover ? Theme.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .help("Exit workspace (Esc / ⌘[) · drop a chat here to take it out of \(w?.name ?? "the workspace")")
                .accessibilityLabel("Exit workspace")
                .chatDropTarget(nil, hovering: $exitHover)
                if let folder = w?.shortFolder {
                    Text(folder).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .padding(.leading, 44).padding(.trailing, 16).padding(.bottom, 4)
                }
                SidebarRow(title: "New chat in \(w?.name ?? "workspace")",
                           selected: { if case .newChat = route { return currentSessionID == nil } else { return false } }(),
                           trailingKeys: ["⌘", "N"]) {
                    Image(systemName: "square.and.pencil").font(.system(size: 13))
                } action: { newChat() }
                SidebarHeader(title: rows.isEmpty ? "Chats" : "Chats · \(rows.count)", icon: "bubble.left.and.bubble.right", accent: true)
                if rows.isEmpty {
                    Text(workspaces.isKnownEmpty(id) ? "No chats here yet. Type below to start one, or drag a chat onto this workspace." : "Loading…")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 18)
                }
                ForEach(SidebarSectionRow.rows(rows, section: "workspace.\(id)")) { row in
                    let r = row.item
                    chatRow(app.sessions.first(where: { $0.id == r.id }) ?? r.summary)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        .task(id: id) {
            try? await workspaces.refreshSessions(id, client: app.companionClient)
        }
    }

    private var allChatsSidebar: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                SidebarRow(title: "New chat", selected: { if case .newChat = route { return currentSessionID == nil && newChatWorkspace == nil } else { return false } }(),
                           trailingKeys: ["⌘", "N"]) {
                    Image(systemName: "square.and.pencil").font(.system(size: 13))
                } action: { newChat() }
                searchField
                    .padding(.top, 4)
                if !query.trimmed.isEmpty {
                    SidebarHeader(title: "Results")
                    if results.isEmpty {
                        Text("No chats match “\(query)”.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 18)
                    }
                    ForEach(SidebarSectionRow.rows(results, section: "results")) { chatRow($0.item) }
                } else {
                    workspaceSection
                    menuSection
                    let pinned = chats.filter(\.isPinned)
                    if !pinned.isEmpty {
                        sectionHeader("Pinned", icon: "pin.fill", key: "pinned", count: pinned.count,
                                      running: pinned.contains { app.runningSessionIDs.contains($0.id) })
                        if !isCollapsed("pinned") { ForEach(SidebarSectionRow.rows(pinned, section: "pinned")) { chatRow($0.item) } }
                    }
                    sectionHeader(workspaces.active.isEmpty ? "Recents" : "Other chats", icon: "clock", key: "recents",
                                  count: otherChats.count,
                                  running: otherChats.contains { app.runningSessionIDs.contains($0.id) })
                    if !isCollapsed("recents") {
                        if otherChats.isEmpty, !app.isRefreshing {
                            Text(chats.isEmpty ? "No chats yet" : "Every chat is in a workspace.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 18)
                        }
                        ForEach(SidebarSectionRow.rows(otherChats, section: "recents")) { chatRow($0.item) }
                    }
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        #if DEBUG
        // Unattended screenshots of lower sections: -mac.sidebarScrollTo pinned|recents
        .task {
            guard let key = UserDefaults.standard.string(forKey: "mac.sidebarScrollTo") else { return }
            try? await Task.sleep(for: .seconds(4))
            proxy.scrollTo("section." + key, anchor: .top)
        }
        #endif
        }
    }

    // MARK: Workspaces (first in the sidebar; a chevron shows a workspace's recent chats)

    @ViewBuilder private var workspaceSection: some View {
        HStack(spacing: 5) {
            sectionHeader("Workspaces", icon: "square.stack.3d.up", key: "workspaces", count: workspaces.active.count,
                          running: workspaces.active.contains { w in
                              (w.sessionIds ?? []).contains { app.runningSessionIDs.contains($0) }
                          })
            Button { creatingWorkspace = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New workspace")
            .padding(.top, 10)
            .padding(.trailing, 12)
        }
        if !isCollapsed("workspaces") { workspaceRows }
    }

    @ViewBuilder private var workspaceRows: some View {
        if workspaces.active.isEmpty {
            SidebarRow(title: "New workspace…", selected: false) {
                Image(systemName: "folder.badge.plus").font(.system(size: 12)).foregroundStyle(.secondary)
            } action: { creatingWorkspace = true }
        }
        ForEach(workspaces.active) { w in
            workspaceRow(w)
                .workspaceReorderable(w, dragging: $draggingWorkspace, chatHover: $chatHover)
            if expanded.contains(w.id) {
                let recent = w.recent ?? []
                if recent.isEmpty {
                    Text("No chats yet").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        .padding(.leading, 44).frame(height: 22)
                }
                ForEach(SidebarSectionRow.rows(recent.prefix(5), section: "expanded.\(w.id)")) { row in
                    let r = row.item
                    let s = app.sessions.first(where: { $0.id == r.id }) ?? r.summary
                    chatRow(s).padding(.leading, 14)
                }
                if (w.sessionCount ?? 0) > recent.count {
                    SidebarRow(title: "All \(w.sessionCount ?? 0) chats", selected: false) {
                        EmptyView()
                    } action: { enterWorkspace(w.id) }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                }
            }
        }
    }

    private func workspaceRow(_ w: Workspace) -> some View {
        let running = (w.sessionIds ?? []).contains { app.runningSessionIDs.contains($0) }
        let open = expanded.contains(w.id)
        return SidebarRow(title: w.name, selected: isSelected(.workspace(w.id)) || (newChatWorkspace == w.id && currentSessionID == nil),
                          trailing: running ? nil : (w.sessionCount ?? 0) > 0 ? "\(w.sessionCount ?? 0)" : nil) {
            WorkspaceIcon(workspace: w, size: 15)
        } action: { enterWorkspace(w.id) }
        .background {
            if chatHover == w.id {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.18))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5) }
                    .padding(.horizontal, 8)
            }
        }
        .help("Enter \(w.name): its chats, board and usage side by side. Drop chats here to move them.")
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                if running { PulsingDot(size: 7).help("A chat here is working…") }
                Button { toggleExpanded(w.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Hide recent chats" : "Show recent chats")
            }
            .padding(.trailing, running ? 16 : 40)
        }
        .contextMenu {
            Button { enterWorkspace(w.id) } label: { Label("Enter \(w.name)", systemImage: "arrow.right.square") }
            Button { newChat(in: w.id) } label: { Label("New chat in \(w.name)", systemImage: "square.and.pencil") }
            Button { go(.screen(.workspace(w.id))) } label: { Label("Workspace details", systemImage: "info.circle") }
            Button { toggleExpanded(w.id) } label: { Label(open ? "Hide recent chats" : "Show recent chats", systemImage: "list.bullet") }
        }
    }

    private func destinationRow(_ title: String, _ icon: String, _ screen: Screen) -> some View {
        SidebarRow(title: title, selected: isSelected(screen)) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary)
        } action: { go(.screen(screen)) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField("Search chats…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .padding(.horizontal, 8)
    }

    private func chatRow(_ s: SessionSummary) -> some View {
        SidebarRow(title: s.displayTitle, selected: isSelected(s), trailing: RelativeShort.string(s.lastActiveDate, now: now)) {
            if app.runningSessionIDs.contains(s.id) {
                PulsingDot(size: 7).help("Working…")
            } else {
                Circle()
                    .fill(SessionDot.color(for: s.id))
                    .frame(width: 6, height: 6)
            }
        } action: { go(.chat(s)) }
        .help(s.preview ?? s.displayTitle)
        .chatDraggable(s.id, workspaceDrag: $draggingWorkspace)
        .contextMenu {
            Button("Open in New Window") {
                PendingWindowChat.id = s.id
                openWindow(id: "main")
            }
            Divider()
            Button {
                renameText = s.displayTitle
                renaming = s
            } label: { Label("Rename…", systemImage: "pencil") }
            Button { Task { await app.setPinned(s, !s.isPinned) } } label: {
                Label(s.isPinned ? "Unpin" : "Pin", systemImage: s.isPinned ? "pin.slash" : "pin")
            }
            Button { Task { await app.setArchived(s, !(s.archived ?? false)) } } label: {
                Label(s.archived ?? false ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            MoveToWorkspaceMenu(sessionID: s.id)
            Divider()
            Button(role: .destructive) { deleting = s } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(app.isOffline ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(app.isOffline ? (app.errorMessage ?? "Offline") : connectionLabel)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if app.isRefreshing { ProgressView().controlSize(.mini) }
            KeepAwakeSidebarControl(awake: .shared)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(MacPalette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(MacPalette.border).frame(height: 1) }
        .help(app.client?.config.baseURL.absoluteString ?? "")
    }

    private var connectionLabel: String {
        guard let url = app.client?.config.baseURL else { return "Not connected" }
        if KanbanClient.isLoopback(url) { return "Connected to this Mac" }
        return url.host() ?? url.absoluteString
    }

    private var panelState: DashboardPanel {
        DashboardPanel(showPanel: showPanel, board: showBoard, usage: showUsage, weft: showWeft)
    }

    /// A section toggle as the menu shows it: on = on screen (switched on and the panel expanded).
    private func panelSection(_ s: DashboardSection) -> Binding<Bool> {
        Binding(get: { panelState.shows(s) },
                set: { on in DashboardPanel.update { p in if p.shows(s) != on { p.showOrHide(s) } } })
    }

    // MARK: Detail

    /// Inside a workspace: the dashboard (chat | board / usage); the chat pane rebuilds per route while
    /// the board and usage panes stay put. Outside: the chat or screen alone.
    @ViewBuilder private var detailArea: some View {
        if let id = mode.activeID {
            WorkspaceDashboard(workspaceID: id, currentSessionID: currentSessionID) {
                detail.id(route)
            }
            .id(id)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Which sections the right panel shows (⇧⌘B / ⇧⌘U / ⇧⌘E), grouped in one menu.
                    Menu {
                        Toggle("Board", isOn: panelSection(.board))
                        Toggle("Usage", isOn: panelSection(.usage))
                        Toggle("Weft", isOn: panelSection(.weft))
                    } label: {
                        Label("Panel Sections", systemImage: "rectangle.split.1x2")
                    }
                    .help("Choose what the right panel shows: board, usage, Weft")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    // Primary control: collapse / expand the whole right panel (⌥⌘0), like Xcode's inspector.
                    Button { DashboardPanel.update { $0.togglePanel() } } label: {
                        Label(panelState.columnVisible ? "Hide Panel" : "Show Panel", systemImage: "sidebar.right")
                    }
                    .help(panelState.columnVisible ? "Hide the right panel (⌥⌘0)" : "Show the right panel (⌥⌘0)")
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
        } else {
            detail.id(route)
        }
    }

    @ViewBuilder private var detail: some View {
        switch route {
        case .newChat(let id):
            MacChatHost(sessionID: nil, title: "New chat", key: id.uuidString,
                        workspaceID: WorkspaceRouting.newChatWorkspace(explicit: newChatWorkspace, active: mode.activeID), onCreated: { created in
                app.noteCreated(created)
                currentSessionID = created.id
                openChat = "session:" + created.id
            })
        case .chat(let s):
            MacChatHost(sessionID: s.id, title: s.displayTitle, key: s.id, onCreated: nil)
        case .screen(let screen):
            screenView(screen)
        case .watch(let t):
            WatchCardView(target: t, onBack: { closeWatch() })
        }
    }

    private func closeWatch() {
        route = watchReturn ?? .newChat(UUID())
        watchReturn = nil
    }

    @ViewBuilder private func screenView(_ screen: Screen) -> some View {
        switch screen {
        case .board: BoardView()
        case .changes: ChangesView()
        case .automations: AutomationsView()
        case .artifacts:
            ArtifactsView { id, title in
                if let s = app.sessions.first(where: { $0.id == id }) { go(.chat(s)); return }
                go(.chat(SessionSummary(id: id, source: nil, title: title, preview: nil, model: nil, startedAt: nil,
                                        lastActive: nil, messageCount: nil, pinned: nil, archived: nil)))
            }
        case .archived: ArchivedView { go(.chat($0)) }
        case .agents:
            AgentsView(onOpenSkills: { ProfilesStore.shared.selected = $0; go(.screen(.skills)) },
                       onOpenMemory: { ProfilesStore.shared.selected = $0; go(.screen(.memory)) })
        case .skills: SkillsView()
        case .memory: MemoryView()
        case .usage: UsageView()
        case .workspace(let id):
            WorkspaceView(workspaceID: id, currentSessionID: currentSessionID,
                          onOpenChat: { go(.chat($0)) }, onNewChat: { newChat(in: $0) })
                .id(id)
        case .chat: EmptyView()
        }
    }

    // MARK: Terminal

    /// The open workspace's folder (chat in a workspace, new chat in one, or the workspace page).
    private var terminalFolder: String? {
        switch route {
        case .newChat: workspaces.workspace(id: newChatWorkspace)?.folder
        case .chat(let s): workspaces.workspace(forSession: s.id)?.folder
        case .screen(.workspace(let id)): workspaces.workspace(id: id)?.folder
        case .screen: nil
        case .watch: mode.activeID.flatMap { workspaces.workspace(id: $0)?.folder }
        }
    }

    private func toggleTerminal() {
        withAnimation(.snappy(duration: 0.2)) { terminalOpen.toggle() }
        if terminalOpen { terminalTabs.selected?.state.requestFocus() }
    }

    private func newTerminalTab() {
        guard let e = app.terminalEndpoint else { return }
        if !terminalOpen { withAnimation(.snappy(duration: 0.2)) { terminalOpen = true } }
        terminalTabs.newTab(endpoint: e, cwd: terminalFolder)
    }

    private func closeTerminalTab() {
        guard let tab = terminalTabs.selected else { return }
        terminalTabs.close(tab.id)
        if terminalTabs.tabs.isEmpty { withAnimation(.snappy(duration: 0.2)) { terminalOpen = false } }
        else { terminalTabs.selected?.state.requestFocus() }
    }

    // MARK: Navigation

    /// ⌘N: inside a workspace the chat starts there; outside, an ordinary new chat.
    private func newChat() {
        go(.newChat(UUID()))
        newChatWorkspace = WorkspaceRouting.newChatWorkspace(explicit: nil, active: mode.activeID)
    }

    /// Click a workspace: work inside it. Keeps the open chat if it belongs there, else an empty
    /// new chat in the workspace (its composer starts a chat there).
    private func enterWorkspace(_ id: String) {
        let keep: Bool = {
            switch route {
            case .chat, .newChat: WorkspaceRouting.keepsChat(currentSessionID, in: workspaces.sessions(for: id))
            case .screen, .watch: false
            }
        }()
        mode.enter(id, from: openChat)
        if !keep { newChat() }
        NSLog("WSMODE enter %@", id)
        Task { try? await workspaces.refreshSessions(id, client: app.companionClient) }
    }

    /// ← / Esc / ⌘[: back to all chats and the screen you were on before entering.
    private func exitWorkspace() {
        guard mode.isActive else { return }
        let back = mode.exit()
        if let back, back.hasPrefix("session:"), let s = app.sessions.first(where: { $0.id == String(back.dropFirst("session:".count)) }) {
            go(.chat(s))
        } else if let back, back.hasPrefix("screen:"), let s = Screen.from(storageKey: String(back.dropFirst("screen:".count))) {
            go(.screen(s))
        } else if case .chat = route {
            // stay on the chat you're reading
        } else {
            go(.newChat(UUID()))
        }
    }

    private func newChat(in workspaceID: String) {
        go(.newChat(UUID()))
        newChatWorkspace = workspaceID
    }

    private func go(_ target: MacRoute) {
        newChatWorkspace = nil
        watchReturn = nil
        route = target
        switch target {
        case .newChat: currentSessionID = nil; openChat = ""
        case .chat(let s): currentSessionID = s.id; openChat = "session:" + s.id
        case .screen(let s): currentSessionID = nil; openChat = "screen:" + (s.storageKey ?? "")
        case .watch: break
        }
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        mode.validate(known: workspaces.active.map(\.id))
        #if DEBUG
        // Window snapshot after a delay (unattended screenshots): -hermes.shot <png> [-hermes.shotDelay 10]
        if let shot = UserDefaults.standard.string(forKey: "hermes.shot") {
            Task {
                try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "hermes.shotDelay").nonZero ?? 10))
                Self.snapshotWindow(to: URL(fileURLWithPath: shot))
                NSLog("WSSHOT %@", shot)
            }
        }
        if let name = UserDefaults.standard.string(forKey: "hermes.enterWorkspace")?.lowercased(),
           let w = workspaces.active.first(where: { $0.name.lowercased() == name }) {
            enterWorkspace(w.id)
            if let id = UserDefaults.standard.string(forKey: "hermes.open"), let s = app.sessions.first(where: { $0.id == id }) { go(.chat(s)) }
            return
        }
        #endif
        if let id = PendingWindowChat.take(), let s = app.sessions.first(where: { $0.id == id }) {
            go(.chat(s)); return
        }
        #if DEBUG
        // Store screenshots: no sidebar (it lists the owner's real workspaces and chats).
        if UserDefaults.standard.bool(forKey: "hermes.hideSidebar") { columns = .detailOnly }
        if UserDefaults.standard.bool(forKey: "hermes.keepAwakeSettings") { OpenKeepAwakeSettings(openSettings: openSettings)() }
        // Terminal pane open from launch; "-hermes.terminalType '<text>'" types into the first tab.
        if UserDefaults.standard.bool(forKey: "hermes.openTerminal") {
            terminalOpen = true
            if let text = UserDefaults.standard.string(forKey: "hermes.terminalType") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    terminalTabs.selected?.typeRaw(text.replacingOccurrences(of: "\\n", with: "\n"))
                }
            }
        }
        if let id = UserDefaults.standard.string(forKey: "hermes.open"), let s = app.sessions.first(where: { $0.id == id }) {
            go(.chat(s)); return
        }
        if let w = UserDefaults.standard.string(forKey: "hermes.newChatIn") { newChat(in: w); return }
        // Click through workspaces by name ("Otto,Story Grove,Weft") to check they draw without a spinner.
        if let tour = UserDefaults.standard.string(forKey: "hermes.workspaceTour") {
            let names = tour.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            Task {
                try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "hermes.tourDelay").nonZero ?? 2))
                for name in names {
                    guard let w = WorkspaceStore.shared.active.first(where: { $0.name.lowercased() == name }) else { continue }
                    go(.screen(.workspace(w.id)))
                    NSLog("WSTOUR open %@ rows=%d", w.name, WorkspaceStore.shared.sessions(for: w.id).count)
                    if let dir = UserDefaults.standard.string(forKey: "hermes.tourShots") {
                        try? await Task.sleep(for: .milliseconds(150))
                        Self.snapshotWindow(to: URL(fileURLWithPath: dir).appendingPathComponent("\(w.name).png"))
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            return
        }
        if let t = UserDefaults.standard.string(forKey: "hermes.tab"), let s = Screen.from(storageKey: t) {
            go(.screen(s)); return
        }
        #endif
        if openChat.hasPrefix("session:") {
            let id = String(openChat.dropFirst("session:".count))
            if let s = app.sessions.first(where: { $0.id == id }) { go(.chat(s)) }
        } else if openChat.hasPrefix("screen:"), let s = Screen.from(storageKey: String(openChat.dropFirst("screen:".count))) {
            go(.screen(s))
        }
    }
}

/// "Open in New Window" hands the chat id to the window that opens next.
@MainActor
enum PendingWindowChat {
    static var id: String?
    static func take() -> String? { defer { id = nil }; return id }
}

// MARK: - Connect (not paired yet, or disconnected)

/// While the relay's dialog is up: the same code, so the person can match the two.
struct MacPairingCode: View {
    let code: String
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("Click Allow in the dialog on this Mac").font(.headline)
            Text(code).font(.system(.title, design: .monospaced).weight(.semibold))
            Text("Allow only if the dialog shows this code.").font(.callout).foregroundStyle(.secondary)
            Button("Cancel", action: cancel).controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

struct MacConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var flow = MacPairingFlow()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                OttoMark(size: 64)
                Text("Connect Otto").font(.title.bold())
                Text("Otto talks to the agent server on this Mac, or to one on your tailnet.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        flow.useThisMac(app)
                    } label: {
                        Label("Use This Mac", systemImage: "desktopcomputer").frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(flow.busy)
                    .keyboardShortcut(.defaultAction)
                    if LocalServer.tailscaleURL != nil {
                        Button {
                            flow.useTailscale(app)
                        } label: {
                            Label("Use Tailscale", systemImage: "network").frame(minWidth: 140)
                        }
                        .controlSize(.large)
                        .disabled(flow.busy)
                    }
                }
                if let code = flow.code {
                    MacPairingCode(code: code) { flow.cancel() }
                } else if flow.busy {
                    ProgressView().controlSize(.small)
                }
                if let error = flow.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .padding(28)
            Divider()
            Text("Or enter another server").font(.headline).padding(.top, 14)
            ConnectView()
                .formStyle(.grouped)
                .frame(maxHeight: 420)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: app.isConnected) { _, connected in
            if connected, !LocalServer.isLocal(app.client) { LocalServer.useLocal = false }
        }
        .task {
            // First run on this Mac: ask for the key right away (one click on Allow). Not after a
            // Disconnect (that switches the mode off), and silent if Hermes isn't running here.
            guard LocalServer.useLocal, !MacPairingFlow.autoTried else { return }
            MacPairingFlow.autoTried = true
            flow.useThisMac(app, quietIfNoRelay: true)
        }
        .onDisappear { if !app.isConnected { flow.cancel() } }
    }
}

// MARK: - Settings window (⌘,)

struct MacSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(MacSettingsTab.key) private var tab = MacSettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            Group {
                if app.isConnected {
                    SettingsView().formStyle(.grouped)
                } else {
                    ContentUnavailableView("Not connected", systemImage: "bolt.horizontal.circle",
                                           description: Text("Connect to a server in the main window first."))
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(MacSettingsTab.general.rawValue)
            MacConnectionSettings()
                .tabItem { Label("Connection", systemImage: "network") }
                .tag(MacSettingsTab.connection.rawValue)
            KeepAwakeSettings(awake: .shared)
                .tabItem { Label("Keep Awake", systemImage: "cup.and.saucer") }
                .tag(MacSettingsTab.keepAwake.rawValue)
            HotspotSettings(hotspot: .shared)
                .tabItem { Label("Hotspot", systemImage: "personalhotspot") }
                .tag(MacSettingsTab.hotspot.rawValue)
        }
        .frame(width: 560, height: 640)
    }
}

struct MacConnectionSettings: View {
    @Environment(AppModel.self) private var app
    @State private var flow = MacPairingFlow()

    var body: some View {
        Form {
            Section("Current server") {
                LabeledContent("Gateway", value: app.client?.config.baseURL.absoluteString ?? "—")
                LabeledContent("Relay", value: app.kanbanClient?.baseURL.absoluteString ?? "—")
                LabeledContent("Status", value: !app.isConnected ? "Not connected" : app.isOffline ? "Unreachable" : "Connected")
            }
            Section {
                Button("Use This Mac") { flow.useThisMac(app) }
                    .disabled(flow.busy)
                if let tailscale = LocalServer.tailscaleURL {
                    Button("Use Tailscale (\(tailscale))") { flow.useTailscale(app) }
                        .disabled(flow.busy)
                }
                if let code = flow.code {
                    MacPairingCode(code: code) { flow.cancel() }.frame(maxWidth: .infinity)
                }
                if let text = flow.error ?? flow.message {
                    Text(text).font(.callout).foregroundStyle(flow.error == nil ? Color.secondary : Color.red)
                }
            } header: {
                Text("Switch server")
            } footer: {
                Text("This Mac: the first time, Otto asks Hermes on this Mac for its access token. A dialog with a code appears; click Allow and the token is kept in your Keychain. Tailscale uses the same token. The relay is found automatically (port 8650 here, 8651 on the tailnet); you can override it under General → Board.")
            }
            Section {
                Button("Disconnect", role: .destructive) {
                    app.disconnect()
                    LocalServer.useLocal = false
                }
                .disabled(!app.isConnected)
            } footer: {
                Text("Removes the saved server, its token and cached chats. Otto then shows the connect screen.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu bar commands

struct OttoCommands: Commands {
    @FocusedValue(\.shellActions) private var shell
    @FocusedValue(\.chatCommands) private var chat
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DashboardPrefs.showBoard) private var showBoard = true
    @AppStorage(DashboardPrefs.showUsage) private var showUsage = true
    @AppStorage(DashboardPrefs.showWeft) private var showWeft = true
    @AppStorage(DashboardPrefs.showPanel) private var showPanel = true

    private var panel: DashboardPanel {
        DashboardPanel(showPanel: showPanel, board: showBoard, usage: showUsage, weft: showWeft)
    }

    private func toggleSection(_ s: DashboardSection) { DashboardPanel.update { $0.showOrHide(s) } }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { shell?.newChat() }
                .keyboardShortcut("n")
                .disabled(shell == nil)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh Chats") { shell?.refresh() }
                .keyboardShortcut("r")
                .disabled(shell == nil)
            Button("Terminal") { shell?.toggleTerminal() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(shell == nil)
            Divider()
            Button(panel.columnVisible ? "Hide Panel" : "Show Panel") { DashboardPanel.update { $0.togglePanel() } }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(shell?.inWorkspace != true)
            Button(panel.shows(.board) ? "Hide Board" : "Show Board") { toggleSection(.board) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(shell?.inWorkspace != true)
            Button(panel.shows(.usage) ? "Hide Usage" : "Show Usage") { toggleSection(.usage) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(shell?.inWorkspace != true)
            Button(panel.shows(.weft) ? "Hide Weft" : "Show Weft") { toggleSection(.weft) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(shell?.inWorkspace != true)
            Button("Exit Workspace") { shell?.exitWorkspace() }
                .keyboardShortcut("[")
                .disabled(shell?.inWorkspace != true)
            Divider()
            Menu("Keep Mac Awake") { KeepAwakeMenu(awake: .shared) }
        }
        CommandMenu("Chat") {
            Button("Focus Message Field") { chat?.focusComposer() }
                .keyboardShortcut("l")
                .disabled(chat == nil)
            Divider()
            Button("Choose Model…") { chat?.showModels() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(chat == nil)
            Button("Slash Commands…") { chat?.showCommands() }
                .keyboardShortcut("/")
                .disabled(chat == nil)
            Button("Find in Chat…") { chat?.find() }
                .keyboardShortcut("f")
                .disabled(chat?.hasSession != true)
            Divider()
            Button("Voice Mode") { chat?.voice() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(chat == nil)
            Button("Stop Response") { chat?.stop() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(chat?.isRunning != true)
        }
    }
}

/// Owns one chat's ChatModel for as long as the chat is on screen. Building the model in the
/// shell's `body` (as before) re-created it, and re-read its cache from disk, on every render.
struct MacChatHost: View {
    let sessionID: String?
    let title: String
    let key: String
    var workspaceID: String? = nil
    let onCreated: ((SessionSummary) -> Void)?
    @Environment(AppModel.self) private var app
    @State private var model: ChatModel?

    var body: some View {
        Group {
            if let model {
                ChatView(model: model, title: title, launch: sessionID == nil ? .newChat : nil)
            } else {
                Color(.systemBackground)
            }
        }
        .task(id: key) {
            guard model == nil, let client = app.client else { return }
            let m = ChatModel(client: client, sessionID: sessionID, onSessionCreated: onCreated, onRunFinished: { [app] in
                Task { await app.refresh() }
            }, loadCache: false)
            m.workspaceID = workspaceID
            model = m
            if let sessionID {
                // Saved transcript: decoded off the main thread, shown until the live history lands.
                let cached = await Task.detached(priority: .userInitiated) { LocalCache.loadMessages(sessionID: sessionID) }.value
                if let cached { m.applyCached(cached) }
            }
        }
    }
}

#if DEBUG
extension MacShell {
    /// The front Otto window drawn to a PNG (works when the window is covered or on another Space).
    static func snapshotWindow(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
#endif
