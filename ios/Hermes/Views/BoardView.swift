import SwiftUI

/// Board tab: pick a board, see its tasks grouped by column, open a task.
struct BoardView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("board.selected") private var selectedSlug = ""
    @State private var boards: [KanbanBoardInfo] = []
    @State private var board: KanbanBoard?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var showDone = false
    @State private var creating = false
    @State private var path: [KanbanTask] = []
    @State private var confirmDelete: KanbanTask?
    @State private var live = CardLiveStore.shared
    @State private var watching: WatchTarget?

    private var client: KanbanClient? { app.kanbanClient }

    /// Running cards with a known worker session open it live (Mac: chat pane, iOS: sheet).
    private func watch(_ t: WatchTarget) {
        #if os(macOS)
        t.open()
        #else
        watching = t
        #endif
    }
    private var current: KanbanBoardInfo? { boards.first { $0.slug == selectedSlug } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    } footer: {
                        Text("The board is served by the Kanban relay on your Mac (port \(KanbanClient.defaultPort)). Tailscale must be on.")
                    }
                }
                if let board {
                    ForEach(visibleColumns(board)) { column in
                        Section {
                            ForEach(column.tasks) { task in
                                Group {
                                    if let t = live.watchTarget(task, board: selectedSlug) {
                                        Button { watch(t) } label: { TaskRow(task: task, live: live.live(task.id)) }
                                            .buttonStyle(.plain)
                                    } else {
                                        NavigationLink(value: task) { TaskRow(task: task, live: live.live(task.id)) }
                                    }
                                }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) { confirmDelete = task } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        if task.status != "archived" {
                                            Button { Task { await quickUpdate(task, ["status": "archived"]) } } label: {
                                                Label("Archive", systemImage: "archivebox")
                                            }
                                            .tint(.gray)
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        if task.status != "done" {
                                            Button { Task { await quickUpdate(task, ["status": "done"]) } } label: {
                                                Label("Done", systemImage: "checkmark")
                                            }
                                            .tint(.green)
                                        }
                                    }
                                    .contextMenu {
                                        if let t = live.watchTarget(task, board: selectedSlug) {
                                            Button { watch(t) } label: { Label("Watch live", systemImage: "eye") }
                                            Button { path.append(task) } label: { Label("Card details", systemImage: "info.circle") }
                                            Divider()
                                        }
                                        ForEach(KanbanStatus.movable.filter { $0 != task.status && $0 != "blocked" }, id: \.self) { s in
                                            Button { Task { await quickUpdate(task, ["status": s]) } } label: {
                                                Label("Move to \(KanbanStatus.label(s))", systemImage: KanbanStatus.symbol(s))
                                            }
                                        }
                                        Divider()
                                        Button { Task { await quickUpdate(task, ["status": "archived"]) } } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                        Button(role: .destructive) { confirmDelete = task } label: {
                                            Label("Delete…", systemImage: "trash")
                                        }
                                    }
                            }
                        } header: {
                            Label("\(KanbanStatus.label(column.name)) · \(column.tasks.count)",
                                  systemImage: KanbanStatus.symbol(column.name))
                        }
                    }
                    if let done = board.columns.first(where: { $0.name == "done" }), !done.tasks.isEmpty {
                        Section {
                            Button(showDone ? "Hide done" : "Show \(done.tasks.count) done") {
                                withAnimation { showDone.toggle() }
                            }
                            .font(.footnote)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if let board, visibleColumns(board).isEmpty, errorMessage == nil {
                    ContentUnavailableView("Nothing open", systemImage: "checkmark.circle",
                                           description: Text("Every task on this board is done."))
                } else if board == nil, loading {
                    ProgressView()
                }
            }
            .refreshable { await load() }
            .navigationTitle(current.map { "\($0.icon ?? "") \($0.displayName)".trimmingCharacters(in: .whitespaces) } ?? "Board")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Board", selection: $selectedSlug) {
                            ForEach(boards) { b in
                                Text("\(b.icon ?? "") \(b.displayName)  \(b.openCount)").tag(b.slug)
                            }
                        }
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .accessibilityLabel("Boards")
                    .disabled(boards.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New task")
                        .disabled(client == nil || selectedSlug.isEmpty)
                }
            }
            .navigationDestination(for: KanbanTask.self) { task in
                if let client {
                    TaskDetailView(client: client, board: selectedSlug, taskID: task.id, initial: task) {
                        Task { await loadBoard() }
                    }
                }
            }
            #if os(iOS)
            .sheet(item: $watching) { t in
                NavigationStack { WatchCardView(target: t) }
            }
            #endif
            .task(id: selectedSlug) {
                // Running cards' Now lines tick from the relay every 5 s while the board is open.
                while !Task.isCancelled {
                    if let board {
                        let running = board.columns.flatMap(\.tasks).filter { $0.status == "running" }.map(\.id)
                        await live.load(board: selectedSlug, running: running, companion: app.companionClient)
                    }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .confirmationDialog("Delete this task?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                titleVisibility: .visible, presenting: confirmDelete) { task in
                Button("Delete \"\(task.title.prefix(40))\"", role: .destructive) { Task { await delete(task) } }
                Button("Archive instead") { Task { await quickUpdate(task, ["status": "archived"]) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently removes the task, its comments and its history. Archiving hides it but keeps it.")
            }
            .sheet(isPresented: $creating) {
                if let client {
                    NewTaskView(client: client, board: selectedSlug) { Task { await loadBoard() } }
                }
            }
            .task {
                await load()
                #if DEBUG
                if let id = UserDefaults.standard.string(forKey: "hermes.openTask"), path.isEmpty,
                   let t = board?.columns.flatMap(\.tasks).first(where: { $0.id == id }) {
                    path = [t]
                }
                #endif
            }
            .onChange(of: selectedSlug) { Task { await loadBoard() } }
        }
    }

    private func visibleColumns(_ board: KanbanBoard) -> [KanbanColumn] {
        let byName = Dictionary(board.columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let names = KanbanStatus.order + board.columns.map(\.name).filter { !KanbanStatus.order.contains($0) }
        return names.compactMap { byName[$0] }
            .filter { !$0.tasks.isEmpty && ($0.name != "done" || showDone) }
    }

    private func load() async {
        guard let client else { errorMessage = "Not connected."; return }
        loading = true
        defer { loading = false }
        do {
            boards = try await client.boards()
                .sorted { ($0.openCount > 0 ? 0 : 1, $0.displayName) < ($1.openCount > 0 ? 0 : 1, $1.displayName) }
            if current == nil { selectedSlug = boards.first(where: { $0.openCount > 0 })?.slug ?? boards.first?.slug ?? "" }
            errorMessage = nil
            await loadBoard()
        } catch {
            errorMessage = "Couldn't load boards: \(AppModel.friendly(error))"
        }
    }

    private func quickUpdate(_ task: KanbanTask, _ fields: [String: String]) async {
        guard let client else { return }
        do {
            try await client.updateTask(task.id, board: selectedSlug, fields: fields)
            Haptics.success()
        } catch {
            Haptics.error()
            errorMessage = "Couldn't update: \(AppModel.friendly(error))"
        }
        await loadBoard()
    }

    private func delete(_ task: KanbanTask) async {
        guard let client else { return }
        do {
            try await client.deleteTask(task.id, board: selectedSlug)
            Haptics.success()
            path.removeAll { $0.id == task.id }
        } catch {
            Haptics.error()
            errorMessage = "Couldn't delete: \(AppModel.friendly(error))"
        }
        await loadBoard()
    }

    private func loadBoard() async {
        guard let client, !selectedSlug.isEmpty else { return }
        do {
            board = try await client.board(selectedSlug)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the board: \(AppModel.friendly(error))"
        }
    }
}

struct TaskRow: View {
    let task: KanbanTask
    var live: CardLive? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.subheadline)
                .lineLimit(3)
            HStack(spacing: 8) {
                if let a = task.assignee, !a.isEmpty {
                    Label(a, systemImage: "person").labelStyle(.titleAndIcon)
                }
                if let c = task.commentCount, c > 0 {
                    Label("\(c)", systemImage: "text.bubble")
                }
                if let t = CardTime.of(task) {
                    LiveCardTime(time: t)
                }
                Spacer(minLength: 0)
                if let p = task.priority, p > 0 {
                    Text("P\(p)").font(.caption2.bold()).foregroundStyle(p >= 7 ? .red : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if task.status == "running", let live {
                CardNowLine(live: live, font: .caption)
                CardTrailLine(trail: live.trail, font: .caption2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TaskDetailView: View {
    let client: KanbanClient
    let board: String
    let taskID: String
    let initial: KanbanTask
    let onChange: () -> Void

    @State private var detail: KanbanTaskDetail?
    @State private var comment = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var blockReason = ""
    @State private var askingBlock = false
    @State private var assignees: [String] = []
    @State private var editing = false
    @State private var confirmingDelete = false
    @FocusState private var commentFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var watching: WatchTarget?

    private var task: KanbanTask { detail?.task ?? initial }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title).font(.headline)
                    HStack(spacing: 10) {
                        Label(KanbanStatus.label(task.status), systemImage: KanbanStatus.symbol(task.status))
                        if let a = task.assignee, !a.isEmpty { Label(a, systemImage: "person") }
                        if let p = task.priority, p > 0 { Text("P\(p)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if task.status == "running", let live = CardLiveStore.shared.live(task.id) {
                        CardNowLine(live: live, font: .caption)
                        CardTrailLine(trail: live.trail, font: .caption2)
                    }
                }
                .padding(.vertical, 2)
                if let t = CardLiveStore.shared.watchTarget(task, board: board) {
                    Button {
                        #if os(macOS)
                        t.open()
                        #else
                        watching = t
                        #endif
                    } label: { Label("Watch it work", systemImage: "eye") }
                }
            }
            Section("Move to") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(KanbanStatus.movable.filter { $0 != task.status }, id: \.self) { status in
                            Button {
                                if status == "blocked" { askingBlock = true } else { Task { await move(to: status) } }
                            } label: {
                                Label(KanbanStatus.label(status), systemImage: KanbanStatus.symbol(status))
                                    .font(.footnote)
                            }
                            .buttonStyle(.bordered)
                            .tint(status == "done" ? .green : status == "blocked" ? .orange : .accentColor)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if !assignees.isEmpty {
                    Picker("Assignee", selection: Binding(
                        get: { task.assignee ?? "" },
                        set: { new in Task { await update(["assignee": new], haptic: false) } })) {
                        Text("Unassigned").tag("")
                        ForEach(assignees, id: \.self) { Text($0).tag($0) }
                    }
                    .font(.subheadline)
                }
            }
            .disabled(busy)
            if let body = task.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                Section("Details") { CollapsibleText(text: body) }
            }
            if let s = task.latestSummary ?? task.result, !s.isEmpty {
                Section("Latest result") { CollapsibleText(text: s) }
            }
            if let err = task.lastFailureError, !err.isEmpty {
                Section("Last failure") { Text(err).font(.caption.monospaced()).foregroundStyle(.red) }
            }
            Section("Comments") {
                ForEach(detail?.comments ?? []) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.author ?? "—").font(.caption.bold())
                            Spacer()
                            LiveRelativeTime(date: c.date).font(.caption2).foregroundStyle(.secondary)
                        }
                        MarkdownText(text: c.body).font(.callout)
                    }
                    .padding(.vertical, 2)
                }
                HStack(alignment: .bottom) {
                    TextField("Add a comment…", text: $comment, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($commentFocused)
                    Button {
                        Task { await addComment() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(comment.trimmed.isEmpty || busy)
                    .accessibilityLabel("Post comment")
                }
            }
            if let events = detail?.events, !events.isEmpty {
                Section("History") {
                    ForEach(events.suffix(12).reversed()) { e in
                        HStack {
                            Text(e.kind.replacingOccurrences(of: "_", with: " ")).font(.caption)
                            Spacer()
                            Text(e.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(taskID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                    if task.status == "running" {
                        Button { Task { await stopWorker() } } label: { Label("Stop worker", systemImage: "stop.circle") }
                    }
                    if task.status == "archived" {
                        Button { Task { await move(to: "todo") } } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                    } else {
                        Button { Task { await move(to: "archived") } } label: { Label("Archive", systemImage: "archivebox") }
                    }
                    Button {
                        UIPasteboard.general.string = taskID
                        Haptics.tap()
                    } label: { Label("Copy ID", systemImage: "doc.on.doc") }
                    Divider()
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete…", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Task actions")
                .disabled(busy)
            }
        }
        #if os(iOS)
        .sheet(item: $watching) { t in
            NavigationStack { WatchCardView(target: t) }
        }
        #endif
        .sheet(isPresented: $editing) {
            EditTaskView(client: client, board: board, task: task) {
                Task { await load(); onChange() }
            }
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteTask() } }
            Button("Archive instead") { Task { await move(to: "archived") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the task, its comments and its history. Archiving hides it but keeps it.")
        }
        .refreshable { await load() }
        .task {
            await load()
            assignees = (try? await client.assignees(board: board)) ?? []
        }
        .alert("Block this task?", isPresented: $askingBlock) {
            TextField("Reason (optional)", text: $blockReason)
            Button("Block") {
                let reason = blockReason
                blockReason = ""
                Task { await update(reason.trimmed.isEmpty ? ["status": "blocked"] : ["status": "blocked", "block_reason": reason]) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't update", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func load() async {
        do { detail = try await client.task(taskID, board: board) } catch { errorMessage = AppModel.friendly(error) }
    }

    private func move(to status: String) async {
        await update(["status": status])
    }

    private func update(_ fields: [String: String], haptic: Bool = true) async {
        busy = true
        defer { busy = false }
        do {
            try await client.updateTask(taskID, board: board, fields: fields)
            if haptic { Haptics.success() }
            await load()
            onChange()
        } catch {
            Haptics.error()
            errorMessage = AppModel.friendly(error)
        }
    }

    private func deleteTask() async {
        busy = true
        defer { busy = false }
        do {
            try await client.deleteTask(taskID, board: board)
            Haptics.success()
            onChange()
            dismiss()
        } catch {
            Haptics.error()
            errorMessage = AppModel.friendly(error)
        }
    }

    private func stopWorker() async {
        busy = true
        defer { busy = false }
        do {
            try await client.reclaimTask(taskID, board: board)
            Haptics.success()
            await load()
            onChange()
        } catch {
            Haptics.error()
            errorMessage = AppModel.friendly(error)
        }
    }

    private func addComment() async {
        let text = comment.trimmed
        guard !text.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.comment(taskID, board: board, body: text)
            comment = ""
            commentFocused = false
            Haptics.send()
            await load()
            onChange()
        } catch {
            errorMessage = AppModel.friendly(error)
        }
    }
}

/// Long markdown shown as a few lines with "Show more", so actions stay above the fold.
struct CollapsibleText: View {
    let text: String
    var collapsedLines = 6
    @State private var expanded = false

    private var isLong: Bool { text.count > 360 || text.components(separatedBy: "\n").count > collapsedLines }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expanded || !isLong {
                MarkdownText(text: text).font(.callout)
            } else {
                Text(SpeechText.clean(text))
                    .font(.callout)
                    .lineLimit(collapsedLines)
            }
            if isLong {
                Button(expanded ? "Show less" : "Show more") { withAnimation(.snappy) { expanded.toggle() } }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
    }
}

struct NewTaskView: View {
    let client: KanbanClient
    let board: String
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var assignee = ""
    @State private var triage = true
    @State private var assignees: [String] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var warning: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical).lineLimit(1...3)
                    TextField("Details (optional)", text: $details, axis: .vertical).lineLimit(3...10)
                }
                Section {
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(assignees, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Put in Triage", isOn: $triage)
                } footer: {
                    Text(triage ? "Triage tasks wait for you to review them." : "Assigned tasks start when a worker picks them up.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(title.trimmed.isEmpty || busy)
                }
            }
            .task { assignees = (try? await client.assignees(board: board)) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            try await client.createTask(board: board, title: title.trimmed, body: details.trimmed,
                                        assignee: assignee.isEmpty ? nil : assignee, triage: triage)
            Haptics.success()
            onCreated()
            dismiss()
        } catch {
            errorMessage = AppModel.friendly(error)
        }
    }
}

struct EditTaskView: View {
    let client: KanbanClient
    let board: String
    let task: KanbanTask
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var priority = 0
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical).lineLimit(1...3)
                    TextField("Details", text: $details, axis: .vertical).lineLimit(4...14)
                }
                Section {
                    Stepper(value: $priority, in: 0...10) {
                        HStack {
                            Text("Priority")
                            Spacer()
                            Text(priority == 0 ? "None" : "P\(priority)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } footer: {
                    Text("Higher numbers are picked up first.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmed.isEmpty || busy)
                }
            }
            .onAppear {
                title = task.title
                details = task.body ?? ""
                priority = task.priority ?? 0
            }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await client.editTask(task.id, board: board, title: title.trimmed, body: details, priority: priority)
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            errorMessage = AppModel.friendly(error)
        }
    }
}
