import SwiftUI

// MARK: - Navigation into an event (from rows, squiggles, threads, candidates)

struct WeftOpenAction {
    let run: @MainActor (WeftEventID) -> Void
    @MainActor func callAsFunction(_ id: WeftEventID) { run(id) }
}

extension EnvironmentValues {
    @Entry var weftOpen: WeftOpenAction? = nil
}

// MARK: - Changes: Weft's combined change log

/// The human's supervision surface for agents that change code unwatched (Weft design
/// principle 9, "the editor disappears"): every intent, edit, squiggle, negotiation,
/// landing and revert across repos, newest first, live.
struct ChangesView: View {
    @State private var store = WeftStore.shared
    @State private var actions = WeftActionRouter()
    @State private var path: [WeftEventID] = []
    @State private var filter = WeftFilterStore.load()
    @State private var showFilters = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    private var rows: [WeftEvent] { store.log.filtered(filter) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !filter.isEmpty { filterChips }
                if let error = store.errorMessage {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { e in
                    WeftEventRow(event: e, showRepo: store.repoNames.count > 1,
                                 taskTitle: e.task.flatMap { store.log.taskTitle($0) },
                                 isFresh: store.fresh.contains(e.id))
                        .contentShape(Rectangle())
                        .onTapGesture { path.append(e.id) }
                        .contextMenu { WeftRowMenu(event: e, router: actions, store: store) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let agent = e.agent {
                                Button { actions.message(repo: e.repo, agent: agent) } label: {
                                    Label("Message", systemImage: "bubble.left")
                                }
                                .tint(.gray)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                        .listRowBackground(store.fresh.contains(e.id) ? Color.primary.opacity(0.06) : Color(.systemBackground))
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
                if !rows.isEmpty, store.reachedStart.count < store.repoNames.count {
                    Button {
                        Task { await store.loadOlder(repos: filter.repos) }
                    } label: {
                        HStack {
                            Spacer()
                            if store.loadingOlder { ProgressView() } else { Text("Load older changes").font(.footnote) }
                            Spacer()
                        }
                    }
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .animation(.snappy(duration: 0.35), value: rows.map(\.id))
            .overlay { emptyState }
            .refreshable { await store.reload() }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { titleView }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filters")
                    Menu {
                        Button { Task { await store.reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        Button { showSettings = true } label: { Label("Weft connection", systemImage: "link") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                }
            }
            .menuButton()
            .navigationDestination(for: WeftEventID.self) { id in
                WeftEventDetailView(id: id)
            }
        }
        .environment(\.weftOpen, WeftOpenAction { path.append($0) })
        .weftActions(actions, store: store)
        .sheet(isPresented: $showFilters) {
            WeftFilterSheet(filter: $filter, log: store.log, repos: store.repoNames)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) { WeftSettingsView() }
        .onChange(of: filter) { _, f in WeftFilterStore.save(f) }
        .onAppear {
            store.hold()
            debugLaunch()
        }
        .task { await store.autoConfigure() }
        .onDisappear { store.unhold() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.detach()
            case .active: store.resume()
            default: break
            }
        }
    }

    private var titleView: some View {
        // Re-evaluated every few seconds so "Live" turns grey when polls stop succeeding.
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            let status = WeftHeaderStatus(store: store, now: ctx.date)
            VStack(spacing: 1) {
                Text("Changes").font(.headline)
                HStack(spacing: 4) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.text).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !store.isConfigured, case .failed(let failure) = store.autoStatus {
            ContentUnavailableView {
                Label("Weft didn't connect", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text(failure.message)
            } actions: {
                Button("Try Again") { Task { await store.autoConfigure(renew: true) } }
                Button("Connect…") { showSettings = true }
            }
        } else if !store.isConfigured {
            ContentUnavailableView {
                Label("Connecting to Weft…", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("See every change your agents make (intents, edits, conflicts, negotiations, landings and reverts) as it happens.")
            } actions: {
                ProgressView()
            }
        } else if rows.isEmpty, !store.isLoading {
            if filter.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("When an agent starts work, its intent and edits show up here."))
            } else {
                ContentUnavailableView {
                    Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear filters") { filter = WeftFilter() }
                }
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if filter.showSessionEvents { chip("Session events") { filter.showSessionEvents = false } }
                if filter.onlyConflicts { chip("Only conflicts") { filter.onlyConflicts = false } }
                ForEach(filter.repos.sorted(), id: \.self) { r in chip(r) { filter.repos.remove(r) } }
                ForEach(filter.agents.sorted(), id: \.self) { a in chip(a) { filter.agents.remove(a) } }
                ForEach(filter.tasks.sorted(), id: \.self) { t in chip(store.log.taskTitle(t) ?? t) { filter.tasks.remove(t) } }
                ForEach(filter.kinds.sorted { $0.rawValue < $1.rawValue }, id: \.self) { k in chip(k.label) { filter.kinds.remove(k) } }
            }
        }
        .scrollIndicators(.hidden)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { remove() } }) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.footnote)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func debugLaunch() {
        #if DEBUG
        let d = UserDefaults.standard
        if d.bool(forKey: "weft.resetFilters") { filter = WeftFilter() }
        if d.bool(forKey: "weft.showFilters") { showFilters = true }
        if d.bool(forKey: "weft.onlyConflicts") { filter.onlyConflicts = true }
        // `-weft.debugAction "pause|resume|message|approve|undo:<repo>:<target>[:text]"` runs a human
        // action through the real client, to verify it end to end on the simulator.
        if let raw = d.string(forKey: "weft.debugAction") {
            let p = raw.split(separator: ":", maxSplits: 3).map(String.init)
            if p.count >= 3 {
                let action: WeftAction? = switch p[0] {
                case "pause": .pause(agent: p[2], reason: p.count > 3 ? p[3] : nil)
                case "resume": .resume(agent: p[2])
                case "message": .message(agent: p[2], text: p.count > 3 ? p[3] : "hello", intent: "steer")
                case "approve": .approve(change: p[2], task: nil, note: p.count > 3 ? p[3] : nil)
                case "undo": Int(p[2]).map { .undo(seq: $0, reason: p.count > 3 ? p[3] : "debug") }
                default: nil
                }
                if let action {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        actions.run(action, repo: p[1], done: "Debug: \(p[0]) sent")
                    }
                }
            }
        }
        if let raw = d.string(forKey: "weft.openEvent"), path.isEmpty {
            let parts = raw.split(separator: ":")
            if parts.count == 2, let seq = Int(parts[1]) {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    path = [WeftEventID(repo: String(parts[0]), seq: seq)]
                }
            }
        }
        #endif
    }
}

/// The Changes header line: green "Live · N repos" while the last feed poll succeeded within
/// ~15 s, where N counts repos with activity in the last 7 days (not every repo on the gateway).
struct WeftHeaderStatus {
    enum Tone: Equatable { case live, connecting, offline }
    let text: String
    let tone: Tone
    var color: Color { tone == .live ? .green : tone == .connecting ? .orange : .secondary }

    @MainActor init(store: WeftStore, now: Date) {
        self.init(configured: store.isConfigured, live: store.isLive(now: now), loading: store.isLoading || store.isPolling,
                  everSucceeded: store.lastPollOK != nil, active: store.activeRepos(now: now), hasSaved: !store.log.combined.isEmpty)
    }

    init(configured: Bool, live: Bool, loading: Bool, everSucceeded: Bool, active: [String], hasSaved: Bool) {
        guard configured else { text = "Not connected"; tone = .offline; return }
        let scope = active.count == 1 ? active[0] : active.isEmpty ? nil : "\(active.count) repos"
        if live { text = scope.map { "Live · \($0)" } ?? "Live"; tone = .live; return }
        if loading && !everSucceeded { text = scope.map { "Connecting · \($0)" } ?? "Connecting"; tone = .connecting; return }
        text = hasSaved ? "Offline · saved changes" : "Offline"
        tone = .offline
    }
}

enum WeftFilterStore {
    static func load() -> WeftFilter {
        guard let d = UserDefaults.standard.data(forKey: "weft.filter"),
              let f = try? JSONDecoder().decode(WeftFilter.self, from: d) else { return WeftFilter() }
        return f
    }
    static func save(_ f: WeftFilter) {
        UserDefaults.standard.set(try? JSONEncoder().encode(f), forKey: "weft.filter")
    }
}

// MARK: - Row

struct WeftEventRow: View {
    let event: WeftEvent
    var showRepo = false
    var taskTitle: String?
    var isFresh = false
    @Environment(\.weftOpen) private var open

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            WeftAvatar(actor: event.actor, agent: event.who)
            VStack(alignment: .leading, spacing: 5) {
                header
                Text(WeftSummary.render(event))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                if !event.symbols.isEmpty || event.group != .other {
                    HStack(alignment: .center, spacing: 6) {
                        symbolLine
                        Spacer(minLength: 4)
                        if showRepo {
                            Text(event.repo).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        WeftKindBadge(event: event)
                    }
                }
                ForEach(Array(event.diagnostics.enumerated()), id: \.offset) { _, d in
                    WeftDiagnosticCallout(diagnostic: d, repo: event.repo, compact: true)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(event.who).font(.subheadline.weight(.semibold)).lineLimit(1)
                .layoutPriority(1)
            if let t = taskTitle ?? event.task {
                Text("· \(t)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(WeftFormat.age(event.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder private var symbolLine: some View {
        // Whole-file keys (`README.md#*`) get no chip: the summary already names the file.
        let keys = (event.writes.map(\.key) + event.reads.filter { r in !event.writes.contains { $0.key == r } })
            .filter { !WeftSymbol.isWholeFile($0) }
        if keys.isEmpty {
            if let file = event.files.first {
                let more = event.files.count > 1 ? "  +\(event.files.count - 1)" : ""
                Text(file + more).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } else {
            HStack(spacing: 6) {
                ForEach(keys.prefix(2), id: \.self) { k in
                    let isWrite = event.writes.contains { $0.key == k }
                    Label(WeftSymbol.name(k), systemImage: isWrite ? "pencil" : "eye")
                        .labelStyle(WeftSymbolLabelStyle())
                        .foregroundStyle(isWrite ? .primary : .secondary)
                }
                if keys.count > 2 {
                    Text("+\(keys.count - 2)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
    }
}

struct WeftSymbolLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title.font(.caption.monospaced())
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Harness icon in a circle; humans and system actors get their own glyphs.
struct WeftAvatar: View {
    let actor: WeftActor
    let agent: String
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(Color(.secondarySystemBackground))
            Circle().strokeBorder(WeftFormat.agentColor(agent).opacity(actor.type == "human" ? 0 : 0.9), lineWidth: 1.5)
            if actor.type == "agent", actor.harness == "hermes" {
                OttoMark(size: size * 0.55)
            } else {
                Image(systemName: WeftFormat.icon(actor: actor))
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(actor.harness.map { "\(agent), \($0)" } ?? agent))
    }
}

struct WeftKindBadge: View {
    let event: WeftEvent

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }

    private var label: String {
        if event.isRejected { return event.mode == "check" ? "blocked" : "rejected" }
        switch event.group {
        case .negotiate: return event.kind.replacingOccurrences(of: "negotiate.", with: "")
        case .control: return event.payload?["action"]?.string ?? "human"
        case .claim, .presence, .other: return event.kind
        default: return event.group.label
        }
    }

    private var tint: Color? {
        if event.isRejected { return .red }
        switch event.group {
        case .land: return .green
        case .revert: return .red
        case .negotiate: return .purple
        default: return nil
        }
    }

    private var foreground: Color { tint ?? .secondary }
    private var background: Color { (tint ?? .primary).opacity(tint == nil ? 0.07 : 0.13) }
}

// MARK: - Squiggles

/// A wavy underline, like an editor's error squiggle.
struct Squiggle: Shape {
    var wavelength: CGFloat = 4
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let mid = rect.midY, amp = rect.height / 2
        p.move(to: CGPoint(x: rect.minX, y: mid))
        var x = rect.minX
        var up = true
        while x < rect.maxX {
            let next = min(x + wavelength, rect.maxX)
            p.addQuadCurve(to: CGPoint(x: next, y: mid), control: CGPoint(x: (x + next) / 2, y: up ? mid - amp * 2 : mid + amp * 2))
            up.toggle()
            x = next
        }
        return p
    }
}

/// A diagnostic shown the way an editor would: the symbol squiggled in amber (warning) or
/// red (error), the message, and "caused by <agent> · event #N" linking to the cause.
struct WeftDiagnosticCallout: View {
    let diagnostic: WeftDiagnostic
    let repo: String
    var compact = false
    @Environment(\.weftOpen) private var open

    private var color: Color { WeftFormat.severityColor(diagnostic.severity) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: WeftFormat.severityIcon(diagnostic.severity))
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(WeftSymbol.name(diagnostic.symbol))
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.bottom, 3)
                        .overlay(alignment: .bottom) {
                            Squiggle().stroke(color, lineWidth: 1.3).frame(height: 3)
                        }
                    Text(WeftFormat.codeLabel(diagnostic.code))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                }
                Text(diagnostic.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : nil)
                if !compact, let s = diagnostic.suggestion {
                    Text(s).font(.caption).foregroundStyle(.primary)
                }
                Button {
                    open?(WeftEventID(repo: repo, seq: diagnostic.causedBySeq))
                } label: {
                    HStack(spacing: 3) {
                        Text("caused by \(diagnostic.causedByAgent) · event #\(diagnostic.causedBySeq)")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Opens the event that caused this")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(color).frame(width: 3)
        }
    }
}

// MARK: - Formatting

enum WeftFormat {
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86_400 { return "\(s / 3600)h" }
        if s < 7 * 86_400 { return "\(s / 86_400)d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The summary without the actor's name repeated at the start (the row already shows it),
    /// with whole-file keys ("*") shown as the file. See `WeftSummary`.
    static func summary(_ e: WeftEvent) -> String { WeftSummary.render(e) }

    static func icon(actor: WeftActor) -> String {
        switch actor.type {
        case "human": return "person.fill"
        case "system":
            if actor.id.contains("revert") { return "arrow.uturn.backward" }
            if actor.id.contains("land") { return "arrow.triangle.merge" }
            return "gearshape.2"
        default: break
        }
        switch actor.harness ?? "" {
        case "claude-code", "claude": return "asterisk"
        case "codex": return "terminal"
        case "gemini", "gemini-cli": return "sparkles"
        case "cursor": return "cursorarrow"
        case "copilot": return "airplane"
        case "watcher": return "eye"
        default: return "cpu"
        }
    }

    /// A stable per-agent hue for the avatar ring, so a combined log stays easy to scan.
    static func agentColor(_ agent: String) -> Color {
        let palette: [Color] = [.orange, .blue, .teal, .purple, .pink, .indigo, .mint, .brown]
        var h: UInt32 = 2166136261
        for b in agent.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    static func severityColor(_ s: String) -> Color {
        switch s {
        case "error": return .red
        case "warning": return Color(red: 0.93, green: 0.6, blue: 0.0)
        default: return .blue
        }
    }

    static func severityIcon(_ s: String) -> String {
        switch s {
        case "error": return "xmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    static func codeLabel(_ code: String) -> String {
        switch code {
        case "stale_overwrite": "overwrites newer code"
        case "stale_assumption": "contract changed under you"
        case "stale_read": "reads changed code"
        case "claim_wait": "waiting on a claim"
        case "claim_die": "yielded to senior change"
        case "claim_wounded": "area taken by senior change"
        case "claim_contended": "contended"
        case "claim_predicted_overlap": "predicted overlap"
        case "contract_changed": "contract changed"
        case "trunk_advanced": "trunk moved"
        case "agent_paused": "agent paused"
        default: code.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func writeKindLabel(_ k: String) -> String {
        switch k {
        case "signature": "signature"
        case "body": "body"
        case "new": "new"
        case "deleted": "deleted"
        default: k
        }
    }
}
