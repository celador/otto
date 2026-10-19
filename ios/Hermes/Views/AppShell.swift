import SwiftUI

// MARK: - Routing

/// What the main area shows. Chats are the home screen, like ChatGPT.
enum Screen: Hashable {
    case chat(ChatRoute)
    case board
    case changes
    case automations
    case artifacts
    case archived
    case agents
    case skills
    case memory
    case usage
    /// A workspace (Hermes project) by id: its chats and board.
    case workspace(String)

    /// Persisted name for non-chat screens.
    var storageKey: String? {
        switch self {
        case .chat: nil
        case .board: "board"
        case .changes: "changes"
        case .automations: "automations"
        case .artifacts: "artifacts"
        case .archived: "archived"
        case .agents: "agents"
        case .skills: "skills"
        case .memory: "memory"
        case .usage: "usage"
        case .workspace(let id): "workspace:" + id
        }
    }

    static func from(storageKey: String) -> Screen? {
        if storageKey.hasPrefix("workspace:") { return .workspace(String(storageKey.dropFirst("workspace:".count))) }
        return [.board, .changes, .automations, .artifacts, .archived, .agents, .skills, .memory, .usage].first { $0.storageKey == storageKey }
    }
}

enum ChatRoute: Hashable {
    case session(SessionSummary)
    case new(UUID, LaunchAction? = nil)
}

/// Chat screen → shell: close the open chat (after delete/archive) and start a new one.
enum ChatNav {
    static let closeChat = Notification.Name("ai.elier.hermes.closeChat")
}

/// `ChatRoute` <-> the string kept in `openChat`, so a relaunch after iOS ends
/// the app in the background lands back in the same chat (with its draft).
enum OpenChat {
    static func encode(_ route: ChatRoute?) -> String {
        switch route {
        case .session(let s): "session:" + s.id
        case .new: "new"
        case nil: ""
        }
    }

    static func route(from raw: String, sessions: [SessionSummary]) -> ChatRoute? {
        if raw == "new" { return .new(UUID()) }
        guard raw.hasPrefix("session:") else { return nil }
        let id = String(raw.dropFirst("session:".count))
        return sessions.first { $0.id == id }.map { .session($0) }
    }
}

/// Sources that are machine-run, not conversations; kept out of Recents.
enum SessionKind {
    static let automated: Set<String> = ["cron", "kanban", "webhook", "subagent", "batch"]
    static func isAutomated(_ s: SessionSummary) -> Bool { automated.contains(s.source ?? "") }
}

// MARK: - Menu button (≡) injected into each screen's toolbar

struct OpenMenuAction {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var openMenu: OpenMenuAction? = nil
}

struct MenuToolbar: ViewModifier {
    @Environment(\.openMenu) private var openMenu

    func body(content: Content) -> some View {
        content.toolbar {
            if let openMenu {
                ToolbarItem(placement: .topBarLeading) {
                    Button { openMenu() } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel("Toggle Sidebar")
                }
            }
        }
    }
}

extension View {
    func menuButton() -> some View { modifier(MenuToolbar()) }
}

// MARK: - Shell: side drawer + main screen

struct AppShell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPad / wide windows: the drawer becomes a sidebar that stays open next to the screen.
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("openChat") private var openChat = ""
    @AppStorage("screen") private var storedScreen = ""
    @State private var screen: Screen = .chat(.new(UUID()))
    /// Session id of the chat on screen, including a new chat once it's created.
    @State private var currentSessionID: String?
    @State private var drawerOpen = false
    @State private var dragOffset: CGFloat = 0
    @State private var showSettings = false
    @State private var restored = false
    /// The workspace the open new chat starts in (set by "New chat in <workspace>").
    @State private var newChatWorkspace: String?
    /// The workspace being worked in: the drawer lists only its chats; wide = chat + board + usage.
    @State private var mode = WorkspaceMode()
    @State private var boardSheet = false
    @State private var usageSheet = false
    @State private var weftSheet = false

    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isWide { sidebarLayout } else { drawerLayout }
        }
        .modifier(ShellEvents(shell: self))
        .background {
            // Hardware keyboard: ⌘N = new chat (in the workspace you're in), ⌘[ = exit the workspace.
            Group {
                Button("New Chat") { newChat() }.keyboardShortcut("n")
                Button("Exit Workspace") { exitWorkspace() }.keyboardShortcut("[")
                    .disabled(!mode.isActive)
                // ⌥⌘0 = collapse / expand the dashboard's right panel (iPad in a workspace).
                Button("Toggle Panel") { DashboardPanel.update { $0.togglePanel() } }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(!mode.isActive || !isWide)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $boardSheet) {
            if let id = mode.activeID { WorkspaceBoardPanel(workspaceID: id).presentationDetents([.medium, .large]) }
        }
        .sheet(isPresented: $usageSheet) {
            WorkspaceUsagePanel(sessionID: currentSessionID).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $weftSheet) {
            if let id = mode.activeID { WeftStripPanel(workspaceID: id, compact: false).presentationDetents([.medium, .large]) }
        }
    }

    private func drawer() -> DrawerView {
        DrawerView(
            screen: screen, currentSessionID: currentSessionID,
            activeWorkspace: mode.activeID, showPanelButtons: !isWide,
            onNewChat: { newChat() },
            onOpen: { go($0) },
            onSettings: { showSettings = true },
            onEnterWorkspace: { enterWorkspace($0) },
            onExitWorkspace: { exitWorkspace() },
            onBoard: { setDrawer(false); boardSheet = true },
            onUsage: { setDrawer(false); usageSheet = true },
            onWeft: { setDrawer(false); weftSheet = true }
        )
    }

    /// iPad: sidebar + screen side by side; the ≡ button hides/shows the sidebar.
    private var sidebarLayout: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                drawer()
                .frame(width: 320)
                .transition(.move(edge: .leading))
                Divider().ignoresSafeArea()
            }
            Group {
                if let id = mode.activeID {
                    // iPad in a workspace: chat | board / usage, like the Mac.
                    WorkspaceDashboard(workspaceID: id, currentSessionID: currentSessionID) { main }
                        .id(id)
                } else {
                    main
                }
            }
                .frame(maxWidth: .infinity)
                .background(backdrop.ignoresSafeArea())
        }
        .animation(.snappy(duration: 0.28), value: sidebarVisible)
    }

    private var drawerLayout: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.82, 340)
            let progress = drawerProgress(width: width)
            ZStack(alignment: .leading) {
                drawer()
                .frame(width: width)
                .offset(x: (progress - 1) * width * 0.25)
                .opacity(progress == 0 ? 0 : 0.4 + 0.6 * progress)

                main
                    .frame(width: geo.size.width)
                    .background(backdrop.ignoresSafeArea())
                    .clipShape(RoundedRectangle(cornerRadius: progress > 0 ? 36 : 0, style: .continuous))
                    .shadow(color: .black.opacity(0.25 * progress), radius: 20)
                    .overlay {
                        if progress > 0 {
                            Color.black.opacity(0.001 + 0.15 * progress)
                                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                                .onTapGesture { setDrawer(false) }
                        }
                    }
                    .offset(x: progress * width)
                    .ignoresSafeArea(.container, edges: progress > 0 ? .vertical : [])
            }
            .gesture(drawerDrag(width: width))
            .animation(.snappy(duration: 0.28), value: drawerOpen)
        }
    }

    fileprivate func events<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            await app.refresh()
            restore()
            takePendingShare()
        }
        .task { await app.pollRunning(isVisible: { scenePhase == .active }) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                takePendingShare()
                Task { await app.refresh() }
                // Fresh limits for the iPhone widget and the watch's AI Limits ring.
                if let c = app.companionClient { Task { await LimitsStore.shared.load(c) } }
            }
        }
        .onContinueUserActivity("ai.elier.hermes.chat") { activity in
            if let id = activity.userInfo?["session"] as? String, !id.isEmpty {
                NotificationCenter.default.post(name: NotificationRouter.openSession, object: nil, userInfo: ["sessionID": id])
            }
        }
        .onOpenURL { url in
            if url.scheme == "hermes", url.host == "usage" { go(.usage); return }
            if url.scheme == "hermes", url.host == "automations" { go(.automations); return }
            if url.scheme == "hermes", url.host == "changes" { go(.changes); return }
            if url.scheme == "hermes", url.host == "weft" {
                // hermes://weft?url=…&token=… configures the Changes feed without showing the token.
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let u = q.first(where: { $0.name == "url" })?.value, let t = q.first(where: { $0.name == "token" })?.value {
                    Task { try? await WeftStore.shared.connect(url: u, token: t) }
                }
                go(.changes); return
            }
            if let action = LaunchAction(url: url) { go(.chat(.new(UUID(), action))); return }
            if url.scheme == "hermes", url.host == "open",
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "session" })?.value {
                // Started elsewhere (share extension): keep its photos for the chat view, and attach
                // to its run so the reply streams in.
                for p in SharedVault.takePendingPhotos() { PhotoStore.save(p.jpegs, text: p.text, sessionID: p.sessionID) }
                if let run = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "run" })?.value,
                   !run.isEmpty {
                    RunBookmark.set(sessionID: id, runID: run)
                }
                NotificationCenter.default.post(name: NotificationRouter.openSession, object: nil, userInfo: ["sessionID": id])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LaunchRequest.notification)) { _ in
            if let action = LaunchRequest.take() { go(.chat(.new(UUID(), action))) }
        }
        .onAppear {
            if let action = LaunchRequest.take() { go(.chat(.new(UUID(), action))) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRouter.openSession)) { note in
            guard let id = note.userInfo?["sessionID"] as? String else { return }
            Task {
                if !app.sessions.contains(where: { $0.id == id }) { await app.refresh() }
                if let s = app.sessions.first(where: { $0.id == id }) { go(.chat(.session(s))) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatNav.closeChat)) { _ in
            go(.chat(.new(UUID())))
        }
    }

    /// A chat queued by the share sheet (when it couldn't open the app directly).
    fileprivate func takePendingShare() {
        for p in SharedVault.takePendingPhotos() { PhotoStore.save(p.jpegs, text: p.text, sessionID: p.sessionID) }
        if let prompt = SharedVault.takePendingShare(), !prompt.isEmpty {
            go(.chat(.new(UUID(), .ask(prompt))))
        }
    }

    /// Behind the status bar and home indicator. List screens are grouped (grey in light mode), chat is plain;
    /// a single white backdrop left white bands above and below every list screen.
    private var backdrop: Color {
        switch screen {
        case .chat, .archived, .skills, .changes, .artifacts: return Color(.systemBackground)   // plain lists
        default: return Color(.systemGroupedBackground)
        }
    }

    @ViewBuilder private var main: some View {
        Group {
            switch screen {
            case .chat(let route):
                NavigationStack { chatView(route) }
                    .id(route)
            case .board:
                BoardView()
            case .changes:
                ChangesView()
            case .automations:
                AutomationsView()
            case .artifacts:
                ArtifactsView { id, title in openArtifactChat(id: id, title: title) }
            case .archived:
                ArchivedView { go(.chat(.session($0))) }
            case .agents:
                AgentsView(onOpenSkills: { ProfilesStore.shared.selected = $0; go(.skills) },
                           onOpenMemory: { ProfilesStore.shared.selected = $0; go(.memory) })
            case .skills:
                SkillsView()
            case .memory:
                MemoryView()
            case .usage:
                UsageView()
            case .workspace(let id):
                WorkspaceView(workspaceID: id, currentSessionID: currentSessionID,
                              onOpenChat: { go(.chat(.session($0))) },
                              onNewChat: { newChat(in: $0) })
                    .id(id)
            }
        }
        .environment(\.openMenu, OpenMenuAction {
            if isWide { sidebarVisible.toggle() } else { setDrawer(true) }
        })
        .allowsHitTesting(isWide || !drawerOpen)
    }

    @ViewBuilder private func chatView(_ route: ChatRoute) -> some View {
        if let client = app.client {
            switch route {
            case .session(let s):
                ChatView(model: ChatModel(client: client, sessionID: s.id, onRunFinished: {
                    Task { await app.refresh() }
                }), title: s.displayTitle)
            case .new(_, let launch):
                ChatView(model: newChatModel(client: client, onSessionCreated: { created in
                    app.noteCreated(created)
                    currentSessionID = created.id
                    openChat = OpenChat.encode(.session(created))
                }), title: "New chat", launch: launch)
            }
        }
    }

    // MARK: Navigation

    /// Opens the chat an artifact came from (uses the cached summary when we have it).
    private func openArtifactChat(id: String, title: String) {
        if let s = app.sessions.first(where: { $0.id == id }) { go(.chat(.session(s))); return }
        go(.chat(.session(SessionSummary(id: id, source: nil, title: title, preview: nil, model: nil, startedAt: nil,
                                         lastActive: nil, messageCount: nil, pinned: nil, archived: nil))))
    }

    /// A new chat filed under `workspaceID` (the session is re-homed to the project folder when created).
    private func newChatModel(client: HermesClient, onSessionCreated: @escaping (SessionSummary) -> Void) -> ChatModel {
        let m = ChatModel(client: client, sessionID: nil, onSessionCreated: onSessionCreated, onRunFinished: {
            Task { await app.refresh() }
        })
        m.workspaceID = WorkspaceRouting.newChatWorkspace(explicit: newChatWorkspace, active: mode.activeID)
        return m
    }

    private func newChat(in workspaceID: String) {
        go(.chat(.new(UUID())))
        newChatWorkspace = workspaceID
    }

    /// ⌘N / the Chat button: inside a workspace the chat starts there.
    private func newChat() {
        go(.chat(.new(UUID())))
        newChatWorkspace = WorkspaceRouting.newChatWorkspace(explicit: nil, active: mode.activeID)
    }

    /// Tap a workspace: work inside it (the drawer lists its chats; wide also shows board + usage).
    private func enterWorkspace(_ id: String) {
        let keep: Bool = {
            if case .chat = screen { return WorkspaceRouting.keepsChat(currentSessionID, in: WorkspaceStore.shared.sessions(for: id)) }
            return false
        }()
        mode.enter(id, from: storedScreen.isEmpty ? openChat : "screen:" + storedScreen)
        if !keep {
            newChat()
            // iPhone: stay in the drawer so the filtered list is what you see.
            if !isWide { drawerOpen = true }
        }
        Task { try? await WorkspaceStore.shared.refreshSessions(id, client: app.companionClient) }
    }

    private func exitWorkspace() {
        guard mode.isActive else { return }
        let back = mode.exit()
        if let back, back.hasPrefix("screen:"), let s = Screen.from(storageKey: String(back.dropFirst("screen:".count))) {
            go(s); drawerOpen = !isWide
        } else if let back, let route = OpenChat.route(from: back, sessions: app.sessions), case .session = route {
            go(.chat(route)); drawerOpen = !isWide
        }
    }

    private func go(_ target: Screen) {
        newChatWorkspace = nil
        screen = target
        switch target {
        case .chat(let route):
            if case .session(let s) = route { currentSessionID = s.id } else { currentSessionID = nil }
            openChat = OpenChat.encode(route)
            storedScreen = ""
        default: storedScreen = target.storageKey ?? ""
        }
        setDrawer(false)
    }

    private func restore() {
        guard !restored else { return }
        restored = true
        mode.validate(known: WorkspaceStore.shared.active.map(\.id))
        #if DEBUG
        let d = UserDefaults.standard
        if let t = d.string(forKey: "hermes.tab") { storedScreen = t == "chats" ? "" : t }
        if d.string(forKey: "hermes.settings") != nil { showSettings = true }
        if let raw = d.string(forKey: "hermes.launchURL"), let url = URL(string: raw), let a = LaunchAction(url: url) {
            go(.chat(.new(UUID(), a))); return
        }
        if DebugLaunch.autoSend != nil { go(.chat(.new(UUID()))); return }
        if let name = d.string(forKey: "hermes.enterWorkspace")?.lowercased(),
           let w = WorkspaceStore.shared.active.first(where: { $0.name.lowercased() == name }) {
            enterWorkspace(w.id)
            if d.bool(forKey: "hermes.drawer") { drawerOpen = true }
            return
        }
        if let id = d.string(forKey: "hermes.open"), let s = app.sessions.first(where: { $0.id == id }) {
            go(.chat(.session(s))); return
        }
        defer { if d.bool(forKey: "hermes.drawer") { drawerOpen = true } }
        #endif
        if let s = Screen.from(storageKey: storedScreen) {
            screen = s
        } else {
            if let route = OpenChat.route(from: openChat, sessions: app.sessions) {
                screen = .chat(route)
                if case .session(let s) = route { currentSessionID = s.id }
            }
        }
    }

    // MARK: Drawer

    private func setDrawer(_ open: Bool) {
        if open {
            #if os(iOS)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
            Haptics.tap()
            Task { await app.refresh() }
        }
        drawerOpen = open
        dragOffset = 0
    }

    private func drawerProgress(width: CGFloat) -> CGFloat {
        let base: CGFloat = drawerOpen ? width : 0
        return min(max((base + dragOffset) / width, 0), 1)
    }

    /// Swipe right from the left edge to open; swipe left anywhere to close.
    private func drawerDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { v in
                let horizontal = abs(v.translation.width) > abs(v.translation.height) * 1.5
                guard horizontal else { return }
                if drawerOpen {
                    dragOffset = min(0, v.translation.width)
                } else if v.startLocation.x < 28 {
                    dragOffset = max(0, v.translation.width)
                }
            }
            .onEnded { v in
                guard dragOffset != 0 else { return }
                let velocity = v.predictedEndTranslation.width - v.translation.width
                let progress = drawerProgress(width: width)
                withAnimation(.snappy(duration: 0.28)) {
                    if drawerOpen {
                        setDrawer(!(progress < 0.6 || velocity < -150))
                    } else {
                        setDrawer(progress > 0.4 || velocity > 150)
                    }
                }
            }
    }
}

private struct ShellEvents: ViewModifier {
    let shell: AppShell
    func body(content: Content) -> some View { shell.events(content) }
}

// MARK: - Drawer contents

struct DrawerView: View {
    @Environment(AppModel.self) private var app
    let screen: Screen
    let currentSessionID: String?
    var activeWorkspace: String? = nil
    /// iPhone: Board / Usage buttons in the workspace header (iPad shows them beside the chat).
    var showPanelButtons = false
    let onNewChat: () -> Void
    let onOpen: (Screen) -> Void
    let onSettings: () -> Void
    var onEnterWorkspace: (String) -> Void = { _ in }
    var onExitWorkspace: () -> Void = {}
    var onBoard: () -> Void = {}
    var onUsage: () -> Void = {}
    var onWeft: () -> Void = {}

    @State private var searching = false
    @State private var query = ""
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var deleting: SessionSummary?
    @State private var creatingWorkspace = false
    @State private var workspaces = WorkspaceStore.shared
    @FocusState private var searchFocused: Bool
    /// Sidebar sections the user folded away ("workspaces", "pinned", "recents"), remembered across launches.
    @AppStorage("sidebar.collapsedSections") private var collapsedRaw = ""
    @State private var draggingWorkspace: String?
    @State private var chatHover: String?
    @State private var exitHover = false

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private func isCollapsed(_ key: String) -> Bool { collapsed.contains(key) }
    private func toggle(_ key: String) {
        var set = collapsed
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.snappy) { collapsedRaw = set.sorted().joined(separator: ",") }
    }

    private var chats: [SessionSummary] {
        app.sessions.filter { !($0.archived ?? false) && !SessionKind.isAutomated($0) }
            .sorted { $0.lastActiveDate > $1.lastActiveDate }
    }
    private var pinned: [SessionSummary] { chats.filter(\.isPinned) }
    /// Chats that aren't pinned and aren't in a workspace.
    private var recents: [SessionSummary] { chats.filter { !$0.isPinned && workspaces.workspace(forSession: $0.id) == nil } }
    private var results: [SessionSummary] {
        let q = query.trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return app.sessions.filter {
            $0.displayTitle.lowercased().contains(q) || ($0.preview ?? "").lowercased().contains(q)
        }
        .sorted { $0.lastActiveDate > $1.lastActiveDate }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if searching {
                        searchResults
                    } else if let id = activeWorkspace {
                        workspaceList(id)
                    } else {
                        workspaceSection
                        menuSection
                        if let error = app.errorMessage {
                            Label(error, systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                        }
                        if !pinned.isEmpty {
                            sectionTitle("Pinned", key: "pinned", count: pinned.count,
                                         running: pinned.contains { app.runningSessionIDs.contains($0.id) })
                            if !isCollapsed("pinned") { ForEach(pinned) { chatRow($0) } }
                        }
                        if !recents.isEmpty {
                            sectionTitle(workspaces.active.isEmpty ? "Recents" : "Other chats", key: "recents",
                                         count: recents.count,
                                         running: recents.contains { app.runningSessionIDs.contains($0.id) })
                            if !isCollapsed("recents") { ForEach(recents) { chatRow($0) } }
                        }
                    }
                    Color.clear.frame(height: 110)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable { await app.refresh() }
            bottomBar
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $creatingWorkspace) {
            WorkspaceEditor { w in onEnterWorkspace(w.id) }
        }
        #if DEBUG
        .task { if UserDefaults.standard.bool(forKey: "hermes.newWorkspace") { creatingWorkspace = true } }
        #endif
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
                        if s.id == currentSessionID { onNewChat() }
                    }
                }
                deleting = nil
            }
        } message: {
            Text("It's removed from your agent server too.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(.secondarySystemBackground), in: Capsule())
                Button("Cancel") {
                    withAnimation(.snappy) { searching = false; query = "" }
                }
                .foregroundStyle(.primary)
            } else {
                Text("Otto").font(.title.bold())
                Spacer()
                Button {
                    withAnimation(.snappy) { searching = true }
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass").font(.title3)
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Search chats")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    /// Inside a workspace: back arrow, its name, Board / Usage (iPhone), then only its chats.
    @ViewBuilder private func workspaceList(_ id: String) -> some View {
        let w = workspaces.workspace(id: id)
        let rows = WorkspaceRouting.sidebarRows(workspaces.sessions(for: id))
        HStack(spacing: 10) {
            Button(action: onExitWorkspace) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    WorkspaceIcon(workspace: w, size: 26, filled: true)
                    Text(w?.name ?? "Workspace").font(.headline).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit workspace")
            .chatDropTarget(nil, hovering: $exitHover)
            Spacer(minLength: 0)
            if showPanelButtons {
                Button(action: onBoard) { Image(systemName: "rectangle.split.3x1").font(.title3) }
                    .accessibilityLabel("Board")
                Button(action: onUsage) { Image(systemName: "chart.bar").font(.title3) }
                    .accessibilityLabel("Usage")
                Button(action: onWeft) { Image(systemName: "point.3.connected.trianglepath.dotted").font(.title3) }
                    .accessibilityLabel("Weft")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(exitHover ? Theme.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
        if let folder = w?.shortFolder {
            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 20).padding(.bottom, 6)
        }
        sectionTitle(rows.isEmpty ? "Chats" : "Chats · \(rows.count)", key: "ws-chats", count: rows.count,
                     running: rows.contains { app.runningSessionIDs.contains($0.id) })
        if !isCollapsed("ws-chats") {
            if rows.isEmpty {
                Text(workspaces.isKnownEmpty(id) ? "No chats here yet. Tap Chat to start one." : "Loading…")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            ForEach(rows) { r in chatRow(app.sessions.first(where: { $0.id == r.id }) ?? r.summary) }
        }
    }

    /// Workspaces first: icon, name, chat count. Tap enters the workspace (its chats; iPad: + board + usage).
    @ViewBuilder private var workspaceSection: some View {
        HStack {
            collapseToggle("Workspaces", key: "workspaces", count: workspaces.active.count,
                           running: workspaces.active.contains { w in
                               (w.sessionIds ?? []).contains(where: { app.runningSessionIDs.contains($0) })
                           })
            Button { creatingWorkspace = true } label: { Image(systemName: "plus").font(.body.weight(.medium)) }
                .foregroundStyle(.secondary)
                .accessibilityLabel("New workspace")
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 6)
        if !isCollapsed("workspaces") { workspaceRows }
    }

    @ViewBuilder private var workspaceRows: some View {
        if workspaces.active.isEmpty {
            Button { creatingWorkspace = true } label: {
                Label("Group chats and a board by project", systemImage: "folder.badge.plus")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).frame(height: 36)
            }
            .buttonStyle(.plain)
        }
        ForEach(workspaces.active) { w in
            Button { onEnterWorkspace(w.id) } label: {
                HStack(spacing: 12) {
                    WorkspaceIcon(workspace: w, size: 26, filled: true)
                    Text(w.name).font(.body).lineLimit(1)
                    Spacer(minLength: 0)
                    if (w.sessionIds ?? []).contains(where: { app.runningSessionIDs.contains($0) }) {
                        PulsingDot(size: 7).accessibilityLabel("Working")
                    }
                    if let n = w.sessionCount, n > 0 {
                        Text("\(n)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(chatHover == w.id ? Theme.accent.opacity(0.18) :
                                screen == .workspace(w.id) ? Color(.secondarySystemBackground) : .clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .contextMenu {
                Button { onOpen(.workspace(w.id)) } label: { Label("Workspace details", systemImage: "info.circle") }
            }
            .workspaceReorderable(w, dragging: $draggingWorkspace, chatHover: $chatHover)
        }
    }

    /// The global screens (not about one project): Board, Automations, Usage… as plain rows,
    /// in a section that folds away like the others.
    @ViewBuilder private var menuSection: some View {
        sectionTitle("Menu", key: "menu", count: 0, running: false)
        if !isCollapsed("menu") {
            navRow("Board", icon: "rectangle.split.3x1", target: .board)
            navRow("Automations", icon: "clock", target: .automations)
            navRow("Changes", icon: "point.3.connected.trianglepath.dotted", target: .changes)
            navRow("Artifacts", icon: "square.on.square", target: .artifacts)
            navRow("Agents", icon: "person.2", target: .agents)
            navRow("Skills", icon: "sparkles", target: .skills)
            navRow("Memory", icon: "brain", target: .memory)
            navRow("Usage", icon: "chart.bar", target: .usage)
            navRow("Archived chats", icon: "archivebox", target: .archived)
        }
    }

    private func navRow(_ title: String, icon: String, target: Screen) -> some View {
        Button { onOpen(target) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 26)
                Text(title).font(.body)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(screen == target ? Color(.secondarySystemBackground) : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func sectionTitle(_ title: String, key: String, count: Int, running: Bool) -> some View {
        collapseToggle(title, key: key, count: count, running: running)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    /// Tappable section header: title + chevron; when folded it shows the item count and a
    /// pulsing dot if something inside is running, so nothing hides silently.
    private func collapseToggle(_ title: String, key: String, count: Int, running: Bool) -> some View {
        let folded = isCollapsed(key)
        return Button { toggle(key) } label: {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                Spacer(minLength: 0)
                if folded {
                    if running { PulsingDot(size: 7).accessibilityLabel("Working") }
                    if count > 0 {
                        Text("\(count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(folded ? "Collapsed, \(count)" : "Expanded")
        .accessibilityHint(folded ? "Shows this section" : "Hides this section")
    }

    private func chatRow(_ s: SessionSummary, showSource: Bool = false) -> some View {
        Button { onOpen(.chat(.session(s))) } label: {
            HStack(spacing: 8) {
                Text(s.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if app.runningSessionIDs.contains(s.id) {
                    PulsingDot(size: 8).accessibilityLabel("Working")
                }
                if showSource, s.archived ?? false {
                    Image(systemName: "archivebox").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(s.id == currentSessionID ? Color(.secondarySystemBackground) : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .chatDraggable(s.id, workspaceDrag: $draggingWorkspace)
        .contextMenu {
            Button {
                renameText = s.displayTitle
                renaming = s
            } label: { Label("Rename", systemImage: "pencil") }
            Button { Task { await app.setPinned(s, !s.isPinned) } } label: {
                Label(s.isPinned ? "Unpin" : "Pin", systemImage: s.isPinned ? "pin.slash" : "pin")
            }
            Button { Task { await app.setArchived(s, !(s.archived ?? false)) } } label: {
                Label(s.archived ?? false ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            MoveToWorkspaceMenu(sessionID: s.id)
            Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if query.trimmed.isEmpty {
            Text("Search titles and messages of all chats, including automations and archived ones.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        } else if results.isEmpty {
            Text("No chats match “\(query)”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        } else {
            ForEach(results) { chatRow($0, showSource: true) }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(action: onNewChat) {
                Label("Chat", systemImage: "square.and.pencil")
                    .font(.headline)
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.horizontal, 22)
                    .frame(height: 52)
                    .background(Color.primary, in: Capsule())
            }
            .accessibilityLabel("New chat")
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                           startPoint: .top, endPoint: .center)
                .frame(height: 110)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Archived chats

struct ArchivedView: View {
    @Environment(AppModel.self) private var app
    let onOpen: (SessionSummary) -> Void

    private var archived: [SessionSummary] {
        var seen = Set<String>()
        return (app.archivedSessions + app.sessions.filter { $0.archived ?? false })
            .filter { seen.insert($0.id).inserted && ($0.archived ?? false) }
            .sorted { $0.lastActiveDate > $1.lastActiveDate }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(archived) { s in
                    Button { onOpen(s) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.displayTitle).lineLimit(1).foregroundStyle(.primary)
                            Text(s.lastActiveDate, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await app.delete(s) } } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { Task { await app.setArchived(s, false) } } label: {
                            Label("Unarchive", systemImage: "tray.and.arrow.up")
                        }
                        .tint(.gray)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if archived.isEmpty && !app.archivedLoaded {
                    ProgressView()
                } else if archived.isEmpty {
                    ContentUnavailableView("No archived chats", systemImage: "archivebox",
                                           description: Text("Archive a chat from its ⋯ menu to tidy your list."))
                }
            }
            .refreshable { await app.loadArchived() }
            .task { await app.loadArchived() }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
        }
    }
}
