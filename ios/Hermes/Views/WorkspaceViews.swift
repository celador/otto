import SwiftUI

// MARK: - Workspace screen: header, New chat, Chats | Board

struct WorkspaceView: View {
    let workspaceID: String
    let currentSessionID: String?
    let onOpenChat: (SessionSummary) -> Void
    let onNewChat: (String) -> Void
    @Environment(AppModel.self) private var app
    @State private var store = WorkspaceStore.shared
    @AppStorage("workspace.segment") private var segment = "chats"
    @State private var errorMessage: String?
    @State private var editing = false
    @State private var confirmArchive = false
    // Board (drawn from the store's last copy, refreshed behind)
    @State private var boardError: String?
    @State private var showDone = false
    @State private var creatingTask = false
    @State private var creatingBoard = false
    @State private var path: [KanbanTask] = []
    @State private var confirmDelete: KanbanTask?

    private var workspace: Workspace? { store.workspace(id: workspaceID) }
    #if os(macOS)
    private static let buttonWidth: CGFloat? = nil
    private static let buttonText = Color.white            // on the desktop orange
    #else
    private static let buttonWidth: CGFloat? = .infinity
    private static let buttonText = Color(.systemBackground) // the iOS accent is black / white
    #endif
    private var boardSlug: String? { workspace?.boardSlug.flatMap { $0.isEmpty ? nil : $0 } }
    /// Drawn on the first frame from the store (cache or what the app already knows): no spinner.
    private var sessions: [WorkspaceSession] { store.sessions(for: workspaceID) }
    private var board: KanbanBoard? { boardSlug.flatMap { store.boards[$0] } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let w = workspace {
                    Section { header(w) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    Section {
                        Picker("Show", selection: $segment) {
                            Text("Chats").tag("chats")
                            Text("Board").tag("board")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    if let errorMessage {
                        Section { Label(errorMessage, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    }
                    if segment == "board" { boardSections(w) } else { chatSection(w) }
                } else {
                    ContentUnavailableView("Workspace not found", systemImage: "folder",
                                           description: Text("It may have been archived in Hermes."))
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await reload() }
            .navigationTitle(workspace?.name ?? "Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .toolbar {
                if segment == "board", boardSlug != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { creatingTask = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New card")
                            .help("New card on this board")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = true } label: { Label("Edit workspace…", systemImage: "pencil") }
                        Button(role: .destructive) { confirmArchive = true } label: {
                            Label("Archive workspace", systemImage: "archivebox")
                        }
                    } label: { Image(systemName: "ellipsis") }
                    #if os(macOS)
                    .menuIndicator(.hidden)
                    #endif
                    .accessibilityLabel("Workspace options")
                }
            }
            .navigationDestination(for: KanbanTask.self) { task in
                if let client = app.kanbanClient, let slug = boardSlug {
                    TaskDetailView(client: client, board: slug, taskID: task.id, initial: task) {
                        Task { await loadBoard() }
                    }
                }
            }
            .sheet(isPresented: $editing) {
                if let w = workspace { WorkspaceEditor(existing: w) { _ in Task { await reload() } } }
            }
            .sheet(isPresented: $creatingTask) {
                if let client = app.kanbanClient, let slug = boardSlug {
                    NewTaskView(client: client, board: slug) { Task { await loadBoard() } }
                }
            }
            .confirmationDialog("Archive \(workspace?.name ?? "this workspace")?", isPresented: $confirmArchive,
                                titleVisibility: .visible) {
                Button("Archive", role: .destructive) { Task { await archive() } }
            } message: {
                Text("Its chats and board stay; they just move to Other chats. You can restore it from the Hermes app.")
            }
            .confirmationDialog("Delete this card?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible, presenting: confirmDelete) { task in
                Button("Delete \"\(task.title.prefix(40))\"", role: .destructive) { Task { await deleteTask(task) } }
                Button("Archive instead") { Task { await updateTask(task, ["status": "archived"]) } }
            } message: { _ in
                Text("This permanently removes the card, its comments and its history.")
            }
            .task(id: workspaceID) {
                #if DEBUG
                NSLog("WSFIRST %@ rows=%d cached=%d", workspaceID, sessions.count, store.hasCachedSessions(workspaceID) ? 1 : 0)
                #endif
                errorMessage = nil; boardError = nil
                await reload()
            }
            .onChange(of: segment) { if segment == "board", board == nil { Task { await loadBoard() } } }
        }
    }

    // MARK: Header

    private func header(_ w: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                WorkspaceIcon(workspace: w, size: 44, filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(w.name).font(.title2.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 10) {
                        if let folder = w.shortFolder {
                            Label(folder, systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if let slug = boardSlug {
                            Label(slug, systemImage: "rectangle.split.3x1").lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
            }
            Button { onNewChat(w.id) } label: {
                Label("New chat in \(w.name)", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: Self.buttonWidth)
                    .frame(height: 38)
                    .foregroundStyle(Self.buttonText)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(w.folder == nil)
            .keyboardShortcut("n", modifiers: [.command, .option])
            .help("Starts in \(w.shortFolder ?? "the workspace folder") (⌥⌘N)")
        }
        .padding(.vertical, 4)
    }

    // MARK: Chats

    @ViewBuilder private func chatSection(_ w: Workspace) -> some View {
        Section {
            let rows = sessions
            if rows.isEmpty, store.isKnownEmpty(workspaceID) {
                Text("No chats here yet. Start one above, or move a chat in from its menu.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows) { s in
                WorkspaceChatRow(session: s, selected: s.id == currentSessionID, running: app.runningSessionIDs.contains(s.id)) {
                    onOpenChat(app.sessions.first(where: { $0.id == s.id }) ?? s.summary)
                }
                .contextMenu { MoveToWorkspaceMenu(sessionID: s.id) }
            }
        } header: {
            let count = sessions.count
            if count > 0 { Text("\(count) chat\(count == 1 ? "" : "s")") }
        }
    }

    // MARK: Board (the existing Board pieces, scoped to this workspace's board)

    @ViewBuilder private func boardSections(_ w: Workspace) -> some View {
        if let slug = boardSlug {
            if let boardError {
                Section { Label(boardError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            }
            if let board {
                let columns = visibleColumns(board)
                if columns.isEmpty {
                    Section {
                        Text("Nothing open on \(slug). Add a card with +.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(columns) { column in
                    Section {
                        ForEach(column.tasks) { task in
                            NavigationLink(value: task) { TaskRow(task: task) }
                                .swipeActions(edge: .leading) {
                                    if task.status != "done" {
                                        Button { Task { await updateTask(task, ["status": "done"]) } } label: {
                                            Label("Done", systemImage: "checkmark")
                                        }
                                        .tint(.green)
                                    }
                                }
                                .contextMenu {
                                    ForEach(KanbanStatus.movable.filter { $0 != task.status && $0 != "blocked" }, id: \.self) { s in
                                        Button { Task { await updateTask(task, ["status": s]) } } label: {
                                            Label("Move to \(KanbanStatus.label(s))", systemImage: KanbanStatus.symbol(s))
                                        }
                                    }
                                    Divider()
                                    Button { Task { await updateTask(task, ["status": "archived"]) } } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    Button(role: .destructive) { confirmDelete = task } label: { Label("Delete…", systemImage: "trash") }
                                }
                        }
                    } header: {
                        Label("\(KanbanStatus.label(column.name)) · \(column.tasks.count)", systemImage: KanbanStatus.symbol(column.name))
                    }
                }
                if let done = board.columns.first(where: { $0.name == "done" }), !done.tasks.isEmpty {
                    Section {
                        Button(showDone ? "Hide done" : "Show \(done.tasks.count) done") { withAnimation { showDone.toggle() } }
                            .font(.footnote)
                    }
                }
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No board yet").font(.headline)
                    Text("Give \(w.name) its own kanban board for cards and agent work.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        Task { await createBoard(w) }
                    } label: {
                        Label("Create board “\(WorkspaceLook.slug(w.name))”", systemImage: "rectangle.split.3x1")
                    }
                    .buttonStyle(.bordered)
                    .disabled(creatingBoard)
                    Button("Use an existing board…") { editing = true }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func visibleColumns(_ board: KanbanBoard) -> [KanbanColumn] {
        let byName = Dictionary(board.columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let names = KanbanStatus.order + board.columns.map(\.name).filter { !KanbanStatus.order.contains($0) }
        return names.compactMap { byName[$0] }
            .filter { !$0.tasks.isEmpty && ($0.name != "done" || showDone) && $0.name != "archived" }
    }

    // MARK: Loading / actions

    /// Everything refreshes side by side, behind rows that are already on screen.
    private func reload() async {
        async let list: Void = store.load(app.companionClient, force: true, kanban: app.kanbanClient)
        async let chats: Void = loadSessions()
        async let cards: Void = loadBoard()
        _ = await (list, chats, cards)
    }

    private func loadSessions() async {
        guard let c = app.companionClient else { return }
        let id = workspaceID
        do {
            try await store.refreshSessions(id, client: c)
            errorMessage = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            // Cached rows stay up; only say something when there's nothing to show.
            if !store.hasCachedSessions(id), sessions.isEmpty {
                errorMessage = (error as? CompanionError)?.errorDescription ?? "Couldn't load chats: \(AppModel.friendly(error))"
            }
        }
    }

    private func loadBoard() async {
        guard let client = app.kanbanClient, let slug = boardSlug else { return }
        do {
            store.noteBoard(try await client.board(slug), slug: slug)
            boardError = nil
        } catch {
            if store.boards[slug] == nil { boardError = "Couldn't load the board: \(AppModel.friendly(error))" }
        }
    }

    private func updateTask(_ task: KanbanTask, _ fields: [String: String]) async {
        guard let client = app.kanbanClient, let slug = boardSlug else { return }
        do {
            try await client.updateTask(task.id, board: slug, fields: fields)
            Haptics.success()
        } catch {
            Haptics.error()
            boardError = "Couldn't update: \(AppModel.friendly(error))"
        }
        await loadBoard()
    }

    private func deleteTask(_ task: KanbanTask) async {
        guard let client = app.kanbanClient, let slug = boardSlug else { return }
        do {
            try await client.deleteTask(task.id, board: slug)
            path.removeAll { $0.id == task.id }
        } catch {
            boardError = "Couldn't delete: \(AppModel.friendly(error))"
        }
        await loadBoard()
    }

    private func createBoard(_ w: Workspace) async {
        guard let c = app.companionClient else { return }
        creatingBoard = true
        defer { creatingBoard = false }
        do {
            let updated = try await c.updateWorkspace(w.id, fields: ["board_slug": WorkspaceLook.slug(w.name), "create_board": true])
            store.noteChanged(updated)
            await loadBoard()
        } catch {
            boardError = "Couldn't create the board: \(AppModel.friendly(error))"
        }
    }

    private func archive() async {
        guard let c = app.companionClient else { return }
        do {
            try await c.archiveWorkspace(workspaceID)
            await store.load(c, force: true)
            NotificationCenter.default.post(name: ChatNav.closeChat, object: nil)
        } catch {
            errorMessage = "Couldn't archive: \(AppModel.friendly(error))"
        }
    }
}

/// One chat in a workspace list: dot (pulsing while it runs), title, age.
struct WorkspaceChatRow: View {
    let session: WorkspaceSession
    let selected: Bool
    var running = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if running {
                    PulsingDot(size: 7)
                } else {
                    Circle().fill(SessionDot.color(for: session.id)).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.summary.displayTitle).lineLimit(1).foregroundStyle(.primary)
                    if let p = session.preview, !p.isEmpty, p != session.title {
                        Text(HistoryCleaner.userText(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(RelativeShort.string(session.summary.lastActiveDate))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : nil)
    }
}

// MARK: - Move a chat between workspaces (context menus, chat ⋯ menu, composer chip)

struct MoveToWorkspaceMenu: View {
    let sessionID: String
    var onMoved: () -> Void = {}
    @State private var store = WorkspaceStore.shared

    var body: some View {
        let current = store.workspace(forSession: sessionID)
        Menu {
            ForEach(store.active) { w in
                Button {
                    Task { await store.move(sessionID, to: w.id); onMoved() }
                } label: {
                    Label(w.name, systemImage: w.id == current?.id ? "checkmark" : (WorkspaceLook.symbol(w.icon) ?? "folder"))
                }
                .disabled(w.id == current?.id || w.folder == nil)
            }
            if current != nil {
                Divider()
                Button { Task { await store.move(sessionID, to: nil); onMoved() } } label: {
                    Label("Remove from \(current?.name ?? "workspace")", systemImage: "tray.and.arrow.up")
                }
            }
        } label: {
            Label("Move to workspace…", systemImage: "folder.badge.plus")
        }
        .disabled(store.active.isEmpty)
    }
}

/// Above the composer: which workspace this chat is in (a menu to move it).
struct WorkspaceChip: View {
    let sessionID: String?
    let pendingWorkspaceID: String?
    var onPick: (String?) -> Void = { _ in }
    @State private var store = WorkspaceStore.shared

    private var workspace: Workspace? { store.workspace(forSession: sessionID) ?? store.workspace(id: pendingWorkspaceID) }

    var body: some View {
        if let w = workspace {
            Menu {
                ForEach(store.active) { other in
                    Button { pick(other.id) } label: {
                        Label(other.name, systemImage: other.id == w.id ? "checkmark" : (WorkspaceLook.symbol(other.icon) ?? "folder"))
                    }
                    .disabled(other.id == w.id || other.folder == nil)
                }
                Divider()
                Button { pick(nil) } label: { Label("Remove from \(w.name)", systemImage: "tray.and.arrow.up") }
            } label: {
                HStack(spacing: 5) {
                    WorkspaceIcon(workspace: w, size: 12)
                    Text(w.name).lineLimit(1)
                    if let f = w.shortFolder {
                        Text(f).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(w.tint.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .menuIndicator(.hidden)
            .fixedSize()
            #endif
            .help("This chat works in \(w.shortFolder ?? w.name). Click to move it.")
            .accessibilityLabel("Workspace: \(w.name)")
        }
    }

    private func pick(_ id: String?) {
        if let sessionID {
            Task { await store.move(sessionID, to: id) }
        }
        onPick(id)
    }
}

// MARK: - Create / edit

struct WorkspaceEditor: View {
    var existing: Workspace? = nil
    let onSaved: (Workspace) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WorkspaceDraft()
    @State private var folders: [WorkspaceFolderChoice] = []
    @State private var boards: [KanbanBoardInfo] = []
    @State private var boardMode = "new"      // new | existing | none
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false
    @State private var customIcon = ""

    private var isNew: Bool { existing == nil }
    private var newBoardSlug: String { WorkspaceLook.slug(draft.name) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        WorkspaceIcon(workspace: preview, size: 36, filled: true)
                        TextField("Name", text: $draft.name)
                            .font(.title3)
                            .textInputAutocapitalization(.words)
                    }
                }
                Section("Look") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                        ForEach(WorkspaceLook.icons, id: \.codicon) { item in
                            Button { draft.icon = item.codicon; customIcon = "" } label: {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 15))
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(draft.icon == item.codicon ? Color.white : Color.primary)
                                    .background(draft.icon == item.codicon ? (WorkspaceLook.color(draft.color) ?? Theme.accent) : Color(.secondarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.codicon)
                        }
                    }
                    .padding(.vertical, 4)
                    HStack(spacing: 8) {
                        ForEach(WorkspaceLook.swatches, id: \.self) { sw in
                            Button { draft.color = sw } label: {
                                Circle()
                                    .fill(WorkspaceLook.color(sw) ?? .gray)
                                    .frame(width: 20, height: 20)
                                    .overlay { if draft.color == sw { Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3) } }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("Or an emoji / SF Symbol name", text: $customIcon)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: customIcon) { _, v in if !v.trimmed.isEmpty { draft.icon = v.trimmed } }
                }
                Section {
                    if !folders.isEmpty {
                        Picker("Repo", selection: $draft.path) {
                            if !folders.contains(where: { $0.path == draft.path }) {
                                Text(draft.path.isEmpty ? "Choose…" : "Custom path").tag(draft.path)
                            }
                            ForEach(folders) { f in
                                Text(f.label.map { "\($0)  ·  \(WorkspaceLook.tildePath(f.path))" } ?? f.path).tag(f.path)
                            }
                        }
                    }
                    TextField("Path", text: $draft.path, prompt: Text("~/code/app"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1)
                } header: {
                    Text("Folder")
                } footer: {
                    Text("New chats here start in this folder on your Mac, and Hermes files chats from it under this project.")
                }
                Section {
                    Picker("Board", selection: $boardMode) {
                        Text(isNew || existing?.boardSlug == nil ? "New board “\(newBoardSlug)”" : "New board").tag("new")
                        Text("Existing board").tag("existing")
                        Text("No board").tag("none")
                    }
                    if boardMode == "existing" {
                        Picker("Which", selection: $draft.boardSlug) {
                            Text("Choose…").tag("")
                            ForEach(boards) { b in Text("\(b.icon ?? "") \(b.displayName)".trimmed).tag(b.slug) }
                        }
                    }
                } header: {
                    Text("Board")
                } footer: {
                    Text(boardMode == "new" ? "A kanban board with the same name is created in Hermes." :
                         boardMode == "existing" ? "Cards stay on that board; this workspace just shows it." : "You can add one later.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New workspace" : "Edit workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { Task { await save() } }
                        .disabled(!canSave || busy)
                }
            }
            .task { await loadChoices() }
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
        .presentationDetents([.large])
    }

    private var canSave: Bool {
        !draft.name.trimmed.isEmpty && !draft.path.trimmed.isEmpty && (boardMode != "existing" || !draft.boardSlug.isEmpty)
    }

    private var preview: Workspace {
        Workspace(id: "preview", slug: nil, name: draft.name, icon: draft.icon, color: draft.color)
    }

    private func loadChoices() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        if let w = existing {
            draft.name = w.name
            draft.icon = w.icon ?? "folder-library"
            if WorkspaceLook.icons.first(where: { $0.codicon == draft.icon }) == nil { customIcon = draft.icon }
            draft.color = w.color ?? WorkspaceLook.swatches[1]
            draft.path = w.folder ?? ""
            draft.boardSlug = w.boardSlug ?? ""
            boardMode = (w.boardSlug ?? "").isEmpty ? "none" : "existing"
        } else {
            draft.color = WorkspaceLook.swatches[(WorkspaceStore.shared.all.count + 1) % 12]
        }
        async let f = try? app.companionClient?.workspaceFolders()
        async let b = try? app.kanbanClient?.boards()
        let (fl, bl) = await (f, b)
        folders = fl ?? []
        boards = (bl ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func save() async {
        guard let c = app.companionClient else { return }
        busy = true
        defer { busy = false }
        var d = draft
        switch boardMode {
        case "new":
            d.boardSlug = boards.contains(where: { $0.slug == newBoardSlug }) || existing?.boardSlug == nil
                ? newBoardSlug : (existing?.boardSlug ?? newBoardSlug)
            d.createBoard = true
        case "none": d.boardSlug = ""
        default: d.createBoard = false
        }
        do {
            let saved: Workspace
            if let w = existing {
                var fields = d.json
                fields.removeValue(forKey: "path")
                if d.path.trimmed != (w.folder ?? "") { fields["path"] = d.path.trimmed }
                saved = try await c.updateWorkspace(w.id, fields: fields)
            } else {
                saved = try await c.createWorkspace(d)
            }
            WorkspaceStore.shared.noteChanged(saved)
            await WorkspaceStore.shared.load(c, force: true)
            Haptics.success()
            onSaved(saved)
            dismiss()
        } catch {
            Haptics.error()
            errorMessage = (error as? CompanionError)?.errorDescription ?? AppModel.friendly(error)
        }
    }
}
