import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Workspace dashboard: chat | (live board / live usage)
//
// "I can talk to you, see you create new tickets that are delegated for background work, I can see
// my usage change… all at the same time." The right column holds the workspace's board (polled every
// 5 s, new cards glow) over a compact usage panel (polled every 12 s, and at once when a run finishes
// or a card moves). Sections toggle (⇧⌘B / ⇧⌘U / ⇧⌘E); the whole column collapses with ⌥⌘0, the
// sidebar.right toolbar button, or by dragging its edge past the minimum. Widths and splits are remembered.

enum DashboardPrefs {
    static let showBoard = "dashboard.showBoard"
    static let showUsage = "dashboard.showUsage"
    static let sideWidth = "dashboard.sideWidth"
    /// Old board/usage split (read once to migrate into `sections`).
    static let boardFraction = "dashboard.boardFraction"
    static let showWeft = "dashboard.showWeft"
    /// The whole right column expanded (⌥⌘0). Independent of the section toggles above.
    static let showPanel = "dashboard.showPanel"
    /// Sizes + folds of the right column's sections (JSON `DashboardSections`).
    static let sections = "dashboard.sections"
}

/// Board → usage: "a card moved, refresh the numbers".
@MainActor
@Observable
final class DashboardSignals {
    static let shared = DashboardSignals()
    private(set) var boardTick = 0
    func boardChanged() { boardTick &+= 1 }
}

struct WorkspaceDashboard<Chat: View>: View {
    let workspaceID: String
    let currentSessionID: String?
    @ViewBuilder let chat: () -> Chat
    @AppStorage(DashboardPrefs.showBoard) private var showBoard = true
    @AppStorage(DashboardPrefs.showUsage) private var showUsage = true
    @AppStorage(DashboardPrefs.showWeft) private var showWeft = true
    @AppStorage(DashboardPrefs.showPanel) private var showPanel = true
    @AppStorage(DashboardPrefs.sideWidth) private var sideWidth = DashboardLayout.defaultSide
    @State private var dragStartWidth: Double?

    private var panel: DashboardPanel {
        DashboardPanel(showPanel: showPanel, board: showBoard, usage: showUsage, weft: showWeft)
    }

    var body: some View {
        GeometryReader { geo in
            let side = DashboardLayout.sideWidth(sideWidth, total: geo.size.width)
            HStack(spacing: 0) {
                chat()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if panel.columnVisible {
                    SplitHandle(axis: .vertical)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                let start = dragStartWidth ?? side
                                dragStartWidth = start
                                switch DashboardLayout.sideDrag(start - v.translation.width, total: geo.size.width) {
                                case .width(let w):
                                    sideWidth = w
                                case .collapse:
                                    // Dragged past the edge: collapse, and keep the width it had for the next expand.
                                    sideWidth = start
                                    dragStartWidth = nil
                                    withAnimation(.snappy(duration: 0.22)) { showPanel = false }
                                }
                            }
                            .onEnded { _ in dragStartWidth = nil })
                    DashboardSideColumn(workspaceID: workspaceID, currentSessionID: currentSessionID,
                                        showBoard: showBoard, showUsage: showUsage, showWeft: showWeft)
                        .frame(width: side)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: showBoard)
            .animation(.snappy(duration: 0.22), value: showUsage)
            .animation(.snappy(duration: 0.22), value: showWeft)
            .animation(.snappy(duration: 0.22), value: showPanel)
        }
    }
}

/// Fold control a section's header shows (set by the dashboard column; nil elsewhere, e.g. the Weft sheet on iPhone).
struct DashboardFold {
    let folded: Bool
    let toggle: () -> Void
}

private struct DashboardFoldKey: EnvironmentKey {
    // nil, never mutated: only read on the main actor by the dashboard's headers.
    nonisolated(unsafe) static let defaultValue: DashboardFold? = nil
}

extension EnvironmentValues {
    var dashboardFold: DashboardFold? {
        get { self[DashboardFoldKey.self] }
        set { self[DashboardFoldKey.self] = newValue }
    }
}

extension View {
    /// Header row of a dashboard section: tap anywhere on it (not on its buttons) to fold / unfold.
    func dashboardFoldHeader() -> some View { modifier(DashboardFoldHeader()) }
}

private struct DashboardFoldHeader: ViewModifier {
    @Environment(\.dashboardFold) private var fold

    func body(content: Content) -> some View {
        if let fold {
            content
                .contentShape(Rectangle())
                .onTapGesture { fold.toggle() }
                .accessibilityAction(named: fold.folded ? "Expand" : "Fold") { fold.toggle() }
        } else {
            content
        }
    }
}

/// Chevron at the leading edge of a section header (only inside the dashboard column).
struct DashboardFoldChevron: View {
    @Environment(\.dashboardFold) private var fold

    var body: some View {
        if let fold {
            Button { fold.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(fold.folded ? -90 : 0))
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help(fold.folded ? "Expand" : "Fold to the header")
            .accessibilityLabel(fold.folded ? "Expand section" : "Fold section")
        }
    }
}

/// The dashboard's right column: the visible sections (board, usage, Weft) top to bottom with a
/// divider between each adjacent pair. Dragging a divider resizes just the two sections it touches;
/// double-clicking it splits them evenly; tapping a header folds that section to its header row.
/// Sizes and folds live in one key (`dashboard.sections`) as weights, so hiding a section keeps
/// the others' proportions and showing it again brings back its old size.
struct DashboardSideColumn: View {
    let workspaceID: String
    let currentSessionID: String?
    let showBoard: Bool
    let showUsage: Bool
    let showWeft: Bool
    @AppStorage(DashboardPrefs.sections) private var sectionsRaw = ""
    /// While a divider is dragged: the live sizes (written to the key when the drag ends).
    @State private var live: DashboardSections?
    @State private var dragStart: (a: DashboardSection, b: DashboardSection, ha: Double, hb: Double, sizes: DashboardSections)?

    private var visible: [DashboardSection] { DashboardLayout.visible(board: showBoard, usage: showUsage, weft: showWeft) }

    private var stored: DashboardSections {
        let old = UserDefaults.standard.object(forKey: DashboardPrefs.boardFraction) as? Double
        return DashboardSections.load(raw: sectionsRaw, oldBoardFraction: old)
    }

    var body: some View {
        GeometryReader { geo in
            let sizes = live ?? stored
            let visible = visible
            let heights = DashboardLayout.heights(sizes, visible: visible, column: geo.size.height)
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element) { i, s in
                    if i > 0 { divider(above: visible[i - 1], below: s, sizes: sizes, heights: heights) }
                    section(s)
                        .environment(\.dashboardFold, DashboardFold(folded: sizes.isFolded(s)) { toggleFold(s) })
                        .frame(height: max(heights[s] ?? 0, 0), alignment: .top)
                        .clipped()
                }
                Spacer(minLength: 0)
            }
            .animation(live == nil ? .snappy(duration: 0.22) : nil, value: sizes)
        }
        .background(Color(.secondarySystemBackground).opacity(0.5))
    }

    @ViewBuilder private func section(_ s: DashboardSection) -> some View {
        switch s {
        case .board: WorkspaceBoardPanel(workspaceID: workspaceID)
        case .usage: WorkspaceUsagePanel(sessionID: currentSessionID)
        // Weft strip: claims, conflicts, landings, installs for this workspace's repo.
        case .weft: WeftStripPanel(workspaceID: workspaceID)
        }
    }

    private func divider(above: DashboardSection, below: DashboardSection, sizes: DashboardSections,
                         heights: [DashboardSection: Double]) -> some View {
        let pair = DashboardLayout.pair(above: above, below: below, visible: visible, sizes: sizes)
        return SplitHandle(axis: .horizontal, active: pair != nil)
            .onTapGesture(count: 2) {
                guard let (a, b) = pair else { return }
                save(DashboardLayout.evenSplit(sizes, a: a, b: b))
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    guard let (a, b) = pair else { return }
                    let start = dragStart ?? (a, b, heights[a] ?? 0, heights[b] ?? 0, sizes)
                    dragStart = start
                    live = DashboardLayout.drag(start.sizes, a: start.a, b: start.b, startA: start.ha, startB: start.hb,
                                                delta: v.translation.height)
                }
                .onEnded { _ in
                    if let live { save(live) }
                    live = nil
                    dragStart = nil
                })
    }

    private func toggleFold(_ s: DashboardSection) {
        withAnimation(.snappy(duration: 0.22)) { save(stored.togglingFold(s)) }
    }

    private func save(_ sizes: DashboardSections) { sectionsRaw = sizes.raw }
}

/// A 1 pt divider with a wider invisible grab area (resize cursor on the Mac). The cursor comes
/// from `pointerStyle`, which AppKit resets itself when the pointer leaves or a drag ends, so it
/// can't get stuck the way a hover-driven NSCursor push/pop could (unbalanced when a drag left the
/// handle, or the view went away while hovered).
struct SplitHandle: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    var active = true

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.10))
                .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
        }
        .frame(width: axis == .vertical ? DashboardLayout.handle : nil, height: axis == .horizontal ? DashboardLayout.handle : nil)
        .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
        .contentShape(Rectangle())
        #if os(macOS)
        .pointerStyle(active ? (axis == .vertical ? .columnResize : .rowResize) : nil)
        #endif
        .accessibilityHidden(true)
    }
}

// MARK: - Live board panel

struct WorkspaceBoardPanel: View {
    let workspaceID: String
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WorkspaceStore.shared
    @State private var path: [KanbanTask] = []
    @State private var previous: BoardSnapshot?
    @State private var highlights = NewCardHighlights()
    @State private var showDone = false
    @State private var creatingTask = false
    @State private var creatingBoard = false
    @State private var error: String?
    @State private var tick = Date()
    @State private var live = CardLiveStore.shared
    /// iOS/iPad: a running card's live session opens as a sheet (the Mac opens it in the chat pane).
    @State private var watching: WatchTarget?
    @State private var hoveredCard: String?

    private var workspace: Workspace? { store.workspace(id: workspaceID) }
    private var slug: String? { workspace?.boardSlug.flatMap { $0.isEmpty ? nil : $0 } }
    private var board: KanbanBoard? { slug.flatMap { store.boards[$0] } }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                content
            }
            .navigationDestination(for: KanbanTask.self) { task in
                if let client = app.kanbanClient, let slug {
                    TaskDetailView(client: client, board: slug, taskID: task.id, initial: task) {
                        Task { await load() }
                    }
                }
            }
        }
        .sheet(isPresented: $creatingTask) {
            if let client = app.kanbanClient, let slug {
                NewTaskView(client: client, board: slug) { Task { await load() } }
            }
        }
        #if os(iOS)
        .sheet(item: $watching) { t in
            NavigationStack { WatchCardView(target: t) }
        }
        #endif
        .task(id: slug) {
            previous = nil
            // Live: every 5 s while the window is in front.
            while !Task.isCancelled {
                if scenePhase != .background || DebugFlags.forceActive { await load() }
                try? await Task.sleep(for: .seconds(UsageRefreshPolicy.boardInterval))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            DashboardFoldChevron()
            Image(systemName: "rectangle.split.3x1").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(slug ?? "Board").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if let board {
                let open = board.columns.filter { !["done", "archived"].contains($0.name) }.reduce(0) { $0 + $1.tasks.count }
                Text("\(open) open").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText(value: Double(open)))
                    .animation(.snappy, value: open)
            }
            Spacer(minLength: 0)
            if slug != nil {
                Button { creatingTask = true } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New card on \(slug ?? "this board")")
                .accessibilityLabel("New card")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .dashboardFoldHeader()
    }

    @ViewBuilder private var content: some View {
        if let slug {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                    if let error, board == nil {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .padding(10)
                    }
                    if let board {
                        let columns = Self.visibleColumns(board, showDone: showDone)
                        if columns.isEmpty {
                            Text("Nothing open on \(slug). Cards the agent creates show up here.")
                                .font(.caption).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(columns) { column in
                            columnHeader(column)
                            ForEach(column.tasks) { task in card(task) }
                        }
                        if let done = board.columns.first(where: { $0.name == "done" }), !done.tasks.isEmpty {
                            Button(showDone ? "Hide done" : "Show \(done.tasks.count) done") {
                                withAnimation(.snappy) { showDone.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    } else if error == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                    }
                }
                .padding(.vertical, 6)
            }
        } else if let w = workspace {
            VStack(alignment: .leading, spacing: 8) {
                Text("No board yet").font(.headline)
                Text("Give \(w.name) its own kanban board for cards and agent work.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await createBoard(w) } } label: {
                    Label("Create board “\(WorkspaceLook.slug(w.name))”", systemImage: "rectangle.split.3x1")
                }
                .disabled(creatingBoard)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Spacer()
        }
    }

    private func columnHeader(_ column: KanbanColumn) -> some View {
        Label("\(KanbanStatus.label(column.name)) · \(column.tasks.count)", systemImage: KanbanStatus.symbol(column.name))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// A running card with a known worker session opens it live; anything else opens the card.
    private func open(_ task: KanbanTask) {
        if let slug, let t = live.watchTarget(task, board: slug) {
            #if os(macOS)
            t.open()
            #else
            watching = t
            #endif
        } else {
            path.append(task)
        }
    }

    private func card(_ task: KanbanTask) -> some View {
        let isNew = highlights.isNew(task.id, at: tick)
        let cardLive = task.status == "running" ? live.live(task.id) : nil
        return Button { open(task) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if task.status == "running" { PulsingDot(size: 6) }
                    Text(task.title).font(.system(size: 12.5)).lineLimit(2).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if isNew {
                        Text("NEW").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                }
                HStack(spacing: 6) {
                    if let a = task.assignee, !a.isEmpty { Text(a) }
                    if let t = CardTime.of(task) { LiveCardTime(time: t) }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let cardLive {
                    CardNowLine(live: cardLive)
                    // Steps so far, on hover (Mac) / always on iPad's wider cards would be noise.
                    if hoveredCard == task.id { CardTrailLine(trail: cardLive.trail).transition(.opacity) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isNew ? Theme.accent.opacity(0.16) : Color(.systemBackground),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isNew ? Theme.accent.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .animation(.easeOut(duration: 0.6), value: isNew)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                if inside { hoveredCard = task.id } else if hoveredCard == task.id { hoveredCard = nil }
            }
        }
        .help(cardLive?.sessionId != nil ? "Click to watch it work" : "")
        .contextMenu {
            if let slug, let t = live.watchTarget(task, board: slug) {
                Button {
                    #if os(macOS)
                    t.open()
                    #else
                    watching = t
                    #endif
                } label: { Label("Watch live", systemImage: "eye") }
                Button { path.append(task) } label: { Label("Card details", systemImage: "info.circle") }
                Divider()
            }
            ForEach(KanbanStatus.movable.filter { $0 != task.status && $0 != "blocked" }, id: \.self) { s in
                Button { Task { await update(task, ["status": s]) } } label: {
                    Label("Move to \(KanbanStatus.label(s))", systemImage: KanbanStatus.symbol(s))
                }
            }
            Divider()
            Button { Task { await update(task, ["status": "archived"]) } } label: { Label("Archive", systemImage: "archivebox") }
        }
    }

    #if DEBUG
    @MainActor private static var debugWatched = false
    #endif

    static func visibleColumns(_ board: KanbanBoard, showDone: Bool) -> [KanbanColumn] {
        let byName = Dictionary(board.columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let names = KanbanStatus.order + board.columns.map(\.name).filter { !KanbanStatus.order.contains($0) }
        return names.compactMap { byName[$0] }
            .filter { !$0.tasks.isEmpty && ($0.name != "done" || showDone) && $0.name != "archived" }
    }

    private func load() async {
        guard let client = app.kanbanClient, let slug else { return }
        do {
            let b = try await client.board(slug)
            store.noteBoard(b, slug: slug)
            let running = b.columns.flatMap(\.tasks).filter { $0.status == "running" }.map(\.id)
            Task {
                await live.load(board: slug, running: running, companion: app.companionClient)
                #if DEBUG
                // Unattended screenshots: -hermes.watchCard <task id|running> opens that card's live session once.
                if let want = UserDefaults.standard.string(forKey: "hermes.watchCard"), !Self.debugWatched,
                   let task = b.columns.flatMap(\.tasks).first(where: { want == "running" ? $0.status == "running" : $0.id == want }),
                   let t = live.watchTarget(task, board: slug) {
                    Self.debugWatched = true
                    try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "hermes.watchCardDelay")))
                    #if os(macOS)
                    t.open()
                    #else
                    watching = t
                    #endif
                }
                #endif
            }
            let snap = BoardSnapshot(b)
            // The first answer after opening is the baseline (nothing flashes on open).
            let base = previous
            let fresh = BoardSnapshot.newCards(previous: base, current: snap)
            if BoardSnapshot.changed(previous: base, current: snap) { DashboardSignals.shared.boardChanged() }
            tick = .now
            highlights.prune(at: tick)
            if !fresh.isEmpty { withAnimation(.snappy) { highlights.mark(fresh, at: tick) } }
            previous = snap
            error = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if store.boards[slug] == nil { self.error = "Couldn't load the board: \(AppModel.friendly(error))" }
        }
        // Let highlights fade between polls.
        tick = .now
    }

    private func update(_ task: KanbanTask, _ fields: [String: String]) async {
        guard let client = app.kanbanClient, let slug else { return }
        do { try await client.updateTask(task.id, board: slug, fields: fields) } catch {
            self.error = "Couldn't update: \(AppModel.friendly(error))"
        }
        await load()
    }

    private func createBoard(_ w: Workspace) async {
        guard let c = app.companionClient else { return }
        creatingBoard = true
        defer { creatingBoard = false }
        do {
            store.noteChanged(try await c.updateWorkspace(w.id, fields: ["board_slug": WorkspaceLook.slug(w.name), "create_board": true]))
            await load()
        } catch {
            self.error = "Couldn't create the board: \(AppModel.friendly(error))"
        }
    }
}

// MARK: - Live usage panel (compact UsageView)

/// Remembered across panel rebuilds (switching chats rebuilds the dashboard), so numbers don't blank.
@MainActor
@Observable
final class DashboardUsageStore {
    static let shared = DashboardUsageStore()
    private(set) var usage: UsageResponse?
    private(set) var lastLoad: Date?
    /// A request is out: the next poll waits for it (the dashboard's analytics can take 45 s when
    /// busy, and stacked polls from every pane would only make that worse).
    private(set) var loading = false
    private var lastLimits: Date?
    var error: String?

    /// Asked again while a request was out (a run finished, a card moved): load once more after it.
    private var again = false

    func load(_ app: AppModel, limits force: Bool = false) async {
        guard let c = app.companionClient else { return }
        guard !loading else { again = true; return }
        loading = true
        defer { loading = false }
        repeat {
            again = false
            do {
                usage = try await c.usage(days: 14)
                error = nil
                lastLoad = .now
            } catch {
                // A pane that went away cancelled it: try again on the next look, not in 12 s.
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                lastLoad = .now
                if usage == nil { self.error = "Couldn't load usage." }
            }
            // Limits come from CodexBar via the relay (cached there ~60 s): no need to ask more often.
            if force || UsageRefreshPolicy.due(last: lastLimits, interval: 60) {
                lastLimits = .now
                await LimitsStore.shared.load(c)
            }
        } while again
    }
}

struct WorkspaceUsagePanel: View {
    let sessionID: String?
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = DashboardUsageStore.shared
    @State private var limits = LimitsStore.shared
    @State private var signals = DashboardSignals.shared

    private var today: UsageResponse.Day? { store.usage.flatMap { UsageRefreshPolicy.today($0.daily) } }
    private var sessionCost: Double? { sessionID.flatMap { id in app.sessions.first { $0.id == id }?.cost } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DashboardFoldChevron()
                Image(systemName: "chart.bar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Usage").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if store.loading && store.usage == nil {
                    ProgressView().controlSize(.mini)
                } else if let at = store.lastLoad {
                    Text(at, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .dashboardFoldHeader()
            Divider().opacity(0.5)
            // Numbers + sparkline stay put; the limit bars scroll if the pane is short.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    TickingStat(value: today?.cost ?? 0, label: "Today", format: UsageView.money, loaded: store.usage != nil)
                    TickingStat(value: Double(UsageRefreshPolicy.tokens(today)), label: "Tokens today",
                                format: { UsageView.compact(Int($0)) }, loaded: store.usage != nil)
                    if let cost = sessionCost {
                        TickingStat(value: cost, label: "This chat", format: UsageView.money)
                    }
                }
                if let days = store.usage?.daily, days.count > 1 {
                    Sparkline(values: days.sorted { $0.day < $1.day }.map(\.cost))
                        .frame(height: 30)
                        .overlay(alignment: .topTrailing) {
                            Text("14 days · \(UsageView.money(store.usage?.totals?.cost ?? 0))")
                                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let snapshot = limits.snapshot, !snapshot.providers.isEmpty {
                        ForEach(snapshot.orderedProviders.prefix(2)) { p in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(p.name).font(.system(size: 11, weight: .semibold))
                                ForEach(p.windows.prefix(2)) { w in LimitWindowRow(window: w, showPace: false, compact: true) }
                            }
                        }
                    }
                    if let e = store.error { Text(e).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.top)
        }
        .task {
            // Every ~12 s while visible (the shared store skips if another panel just loaded).
            while !Task.isCancelled {
                if scenePhase != .background, UsageRefreshPolicy.due(last: store.lastLoad, interval: UsageRefreshPolicy.interval - 1) {
                    await store.load(app)
                }
                try? await Task.sleep(for: .seconds(UsageRefreshPolicy.interval))
            }
        }
        .onChange(of: app.runningSessionIDs) { old, new in
            if UsageRefreshPolicy.runFinished(previous: old, current: new) { Task { await store.load(app) } }
        }
        .onChange(of: signals.boardTick) { Task { await store.load(app) } }
    }
}

/// A number that rolls to its new value.
private struct TickingStat: View {
    let value: Double
    let label: String
    let format: (Double) -> String
    var loaded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(loaded ? format(value) : "–")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText(value: value))
                .animation(.snappy(duration: 0.4), value: value)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tiny daily-spend line.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 0, 0.01)
            let step = values.count > 1 ? geo.size.width / Double(values.count - 1) : 0
            let points = values.enumerated().map { i, v in
                CGPoint(x: Double(i) * step, y: geo.size.height * (1 - v / peak) * 0.85 + geo.size.height * 0.1)
            }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for pt in points { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(Theme.accent.opacity(0.12))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .animation(.snappy, value: values)
        }
        .accessibilityLabel("Daily spend, last \(values.count) days")
    }
}
