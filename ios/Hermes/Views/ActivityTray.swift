import SwiftUI

// MARK: - Subagents / Background tray (the Hermes desktop's status stack above the composer)
//
// Data: relay GET /hermes/activity?session=<stored chat id> → dashboard JSON-RPC
// (delegation.status filtered to this chat, process.list for its live runtime). Controls:
// subagent tail/steer/stop and process tail/kill (relay/slash_bridge.py).

struct ChatActivity: Decodable, Equatable, Sendable {
    var live: Bool = false
    var subagents: [Subagent] = []
    var processes: [BackgroundProcess] = []
    /// Whether the chat has a turn running anywhere (desktop, Telegram, cron, another device), from
    /// the agent's heartbeat in the session DB (relay/run_state.py). Missing on older relays.
    var run: RemoteRun?

    struct RemoteRun: Decodable, Equatable, Sendable {
        var running: Bool = false
        /// thinking | tool | subagents | compressing | working
        var kind: String?
        var tool: String?
        var preview: String?
        var startedAt: Double?
        var waiting: Bool?
        var canStop: Bool?

        var label: String {
            if waiting == true { return "Waiting for your approval" }
            switch kind {
            case "tool": return tool.map { ToolInfo.liveLabel(name: $0, preview: preview) } ?? "Using tools"
            case "subagents": return "Subagents are working"
            case "compressing": return "Compressing the conversation"
            case "thinking": return "Thinking…"
            default: return "Working…"
            }
        }
    }

    struct Subagent: Decodable, Equatable, Identifiable, Sendable {
        var id: String
        var goal: String?
        var status: String?
        var elapsedS: Int?
        var currentTool: String?
        var toolCount: Int?
        var model: String?
    }

    struct BackgroundProcess: Decodable, Equatable, Identifiable, Sendable {
        var id: String
        var command: String?
        var status: String?
        var uptimeSeconds: Int?
    }

    var isEmpty: Bool { subagents.isEmpty && processes.isEmpty }
}

struct ActivityTail: Decodable, Sendable {
    var text: String?
    var available: Bool?
    var status: String?
}

extension CompanionClient {
    func activity(sessionID: String) async throws -> ChatActivity {
        let data = try await rawRequest("GET", "/hermes/activity", query: ["session": sessionID])
        return try HermesClient.decoder.decode(ChatActivity.self, from: data)
    }

    func activityTail(sessionID: String, kind: ActivityKind, id: String) async throws -> ActivityTail {
        let data = try await rawRequest("GET", "/hermes/activity/\(kind.rawValue)/\(id.pathEscaped)/tail",
                                        query: ["session": sessionID])
        return try HermesClient.decoder.decode(ActivityTail.self, from: data)
    }

    /// Stops a turn the desktop/dashboard is running (POST /hermes/activity/stop).
    func stopRemoteRun(sessionID: String) async throws {
        _ = try await rawRequest("POST", "/hermes/activity/stop", query: ["session": sessionID], body: Data("{}".utf8))
    }

    /// Chats with a turn running anywhere, for the sidebar's dots (GET /hermes/running).
    func runningSessions() async throws -> Set<String> {
        struct Reply: Decodable { struct Row: Decodable { var id: String }; var sessions: [Row] }
        let data = try await rawRequest("GET", "/hermes/running")
        return Set(try HermesClient.decoder.decode(Reply.self, from: data).sessions.map(\.id))
    }

    func activityAction(sessionID: String, kind: ActivityKind, id: String, action: String, message: String? = nil) async throws {
        let body = message.map { try? JSONSerialization.data(withJSONObject: ["message": $0]) } ?? nil
        _ = try await rawRequest("POST", "/hermes/activity/\(kind.rawValue)/\(id.pathEscaped)/\(action)",
                                 query: ["session": sessionID], body: body ?? Data("{}".utf8))
    }
}

enum ActivityKind: String, Sendable { case subagent, process }

/// One chat's tray + run state. Polls only while the chat is on screen: every 2 s while a turn
/// runs (here or anywhere else) or the tray lists something, every 6 s while idle (the relay
/// answers an idle chat from one SQLite read, without touching the dashboard).
@MainActor
@Observable
final class ActivityStore {
    private(set) var activity = ChatActivity()
    private(set) var fetchedAt = Date()
    var lastError: String?

    func refresh(_ client: CompanionClient, sessionID: String) async {
        do {
            let a = try await client.activity(sessionID: sessionID)
            if a != activity { activity = a }
            fetchedAt = .now
            lastError = nil
        } catch {
            lastError = AppModel.friendly(error)
        }
    }

    /// The poll loop; cancelled with the view's task.
    func poll(_ client: CompanionClient, sessionID: String, isRunning: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled {
            await refresh(client, sessionID: sessionID)
            let busy = !activity.isEmpty || isRunning() || remoteRunning
            try? await Task.sleep(for: .seconds(busy ? 2 : 6))
        }
    }

    var remoteRunning: Bool { activity.run?.running == true }

    func clear() { activity = ChatActivity() }

    func elapsed(_ s: ChatActivity.Subagent, at now: Date) -> Int? {
        s.elapsedS.map { $0 + max(0, Int(now.timeIntervalSince(fetchedAt))) }
    }
}

struct ActivityTray: View {
    let sessionID: String?
    let isRunning: Bool
    let store: ActivityStore
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tray.subagentsCollapsed") private var subagentsCollapsed = false
    @AppStorage("tray.processesCollapsed") private var processesCollapsed = false
    @State private var tail: TailTarget?
    @State private var steering: ChatActivity.Subagent?
    @State private var steerText = ""
    @State private var stopping: ChatActivity.Subagent?
    @State private var killing: ChatActivity.BackgroundProcess?
    @State private var actionError: String?

    /// A Mac window behind another app is `.inactive` but still on screen, so only `.background` stops polling.
    private var visible: Bool { scenePhase != .background }
    private var pollKey: String { "\(sessionID ?? "")|\(isRunning)|\(visible)" }

    var body: some View {
        // A ZStack (not Group) so the view, and its polling task, exists even while the tray is empty.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if !store.activity.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.activity.subagents.isEmpty { subagentsSection }
                    if !store.activity.processes.isEmpty { processesSection }
                }
                .padding(.vertical, 4)
                .background(Color(.systemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(TrayStyle.border, lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.snappy(duration: 0.2), value: store.activity.isEmpty)
        .task(id: pollKey) {
            guard let sessionID, visible, let client = app.companionClient else { return }
            await store.poll(client, sessionID: sessionID, isRunning: { isRunning })
        }
        .onChange(of: sessionID) { store.clear() }
        .sheet(item: $tail) { t in
            ActivityTailView(target: t, sessionID: sessionID ?? "")
        }
        .alert("Steer subagent", isPresented: Binding(get: { steering != nil }, set: { if !$0 { steering = nil } })) {
            TextField("Message", text: $steerText)
            Button("Send") {
                let s = steering, text = steerText
                steerText = ""
                if let s { act(.subagent, s.id, "steer", message: text) }
            }
            Button("Cancel", role: .cancel) { steerText = "" }
        } message: {
            Text("It's added to what the subagent is doing; the step it's on finishes first.")
        }
        .confirmationDialog("Stop this subagent?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible) {
            Button("Stop", role: .destructive) { if let s = stopping { act(.subagent, s.id, "stop") } }
        } message: { Text(stopping?.goal ?? "") }
        .confirmationDialog("Kill this process?", isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
                            titleVisibility: .visible) {
            Button("Kill", role: .destructive) { if let p = killing { act(.process, p.id, "kill") } }
        } message: { Text(killing?.command ?? "") }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private func act(_ kind: ActivityKind, _ id: String, _ action: String, message: String? = nil) {
        guard let sessionID, let client = app.companionClient else { return }
        Task {
            do {
                try await client.activityAction(sessionID: sessionID, kind: kind, id: id, action: action, message: message)
                await store.refresh(client, sessionID: sessionID)
            } catch {
                actionError = AppModel.friendly(error)
            }
        }
    }

    // MARK: Sections

    private var subagentsSection: some View {
        let n = store.activity.subagents.count
        return VStack(alignment: .leading, spacing: 0) {
            header(collapsed: $subagentsCollapsed, icon: "point.3.filled.connected.trianglepath.dotted",
                   title: "\(n) Subagent\(n == 1 ? "" : "s")")
            if !subagentsCollapsed {
                ForEach(store.activity.subagents) { s in subagentRow(s) }
            }
        }
    }

    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(collapsed: $processesCollapsed, icon: "terminal", title: "\(store.activity.processes.count) Background")
            if !processesCollapsed {
                ForEach(store.activity.processes) { p in processRow(p) }
            }
        }
    }

    private func header(collapsed: Binding<Bool>, icon: String, title: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { collapsed.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed.wrappedValue ? -90 : 0))
                    .frame(width: 12)
                Image(systemName: icon).font(.system(size: 11))
                Text(title)
                Spacer(minLength: 0)
            }
            .font(TrayStyle.headerFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: TrayStyle.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(collapsed.wrappedValue ? "collapsed" : "expanded")")
    }

    private func subagentRow(_ s: ChatActivity.Subagent) -> some View {
        Button { tail = TailTarget(kind: .subagent, id: s.id, title: s.goal ?? "Subagent") } label: {
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.mini).frame(width: 12, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.goal ?? "Subagent")
                        .font(TrayStyle.rowFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let line = toolLine(s) {
                        Text(line).font(TrayStyle.detailFont).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.clock(store.elapsed(s, at: ctx.date)))
                        .font(TrayStyle.detailFont.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Menu {
                    Button { tail = TailTarget(kind: .subagent, id: s.id, title: s.goal ?? "Subagent") } label: {
                        Label("Show Progress", systemImage: "text.alignleft")
                    }
                    Button { steering = s } label: { Label("Steer…", systemImage: "arrow.turn.down.right") }
                    Button(role: .destructive) { stopping = s } label: { Label("Stop", systemImage: "stop.circle") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Subagent actions")
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { steering = s } label: { Label("Steer…", systemImage: "arrow.turn.down.right") }
            Button(role: .destructive) { stopping = s } label: { Label("Stop", systemImage: "stop.circle") }
        }
    }

    private func processRow(_ p: ChatActivity.BackgroundProcess) -> some View {
        HStack(spacing: 8) {
            Button { killing = p } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kill process")
            Button { tail = TailTarget(kind: .process, id: p.id, title: p.command ?? "Process") } label: {
                HStack {
                    Text(p.command ?? p.id)
                        .font(TrayStyle.commandFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(minHeight: 24)
    }

    private func toolLine(_ s: ChatActivity.Subagent) -> String? {
        guard let tool = s.currentTool, !tool.isEmpty else { return nil }
        let name = ToolInfo.info(tool).title
        if let n = s.toolCount, n > 1 { return "\(name) · \(n) tool calls" }
        return name
    }

    static func clock(_ seconds: Int?) -> String {
        guard let s = seconds else { return "" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - Run status line ("Thinking… / Running a command: git status / Writing…", elapsed, Stop)

/// What the chat is doing, pinned above the composer for as long as the chat has a turn running,
/// whoever started it.
struct ChatRunStatus: Equatable {
    var label: String
    var startedAt: Date?
    var canStop: Bool

    /// Otto's own run first (it has the live event stream), else the server's view of the session.
    @MainActor static func of(_ model: ChatModel, _ store: ActivityStore) -> ChatRunStatus? {
        if model.isRunning {
            let label: String
            if model.transcript.pendingApproval != nil { label = "Waiting for your approval" }
            else if let s = model.liveStatus { label = s }
            else if case .assistant(_, let text, true) = model.items.last, !text.isEmpty { label = "Writing…" }
            else if store.activity.subagents.isEmpty == false { label = "Subagents are working" }
            else { label = "Thinking…" }
            return ChatRunStatus(label: label, startedAt: model.runStartedAt, canStop: true)
        }
        guard let run = store.activity.run, run.running else { return nil }
        return ChatRunStatus(label: run.label, startedAt: run.startedAt.map { Date(timeIntervalSince1970: $0) },
                         canStop: run.canStop == true)
    }
}

struct RunStatusLine: View {
    let status: ChatRunStatus
    let stop: () -> Void

    /// 0:07, 12:40, 1:02:03
    static func elapsed(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text(status.label)
                .font(TrayStyle.rowFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: status.label)
            Spacer(minLength: 6)
            if let start = status.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.elapsed(max(0, Int(ctx.date.timeIntervalSince(start)))))
                        .font(TrayStyle.detailFont.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if status.canStop {
                Button(action: stop) {
                    HStack(spacing: 3) {
                        Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold))
                        Text("Stop")
                    }
                    .font(TrayStyle.detailFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .overlay(Capsule().strokeBorder(TrayStyle.border, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TrayStyle.headerHeight + 4)
        .background(Color(.systemBackground).opacity(0.96), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(TrayStyle.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The small orange "working" dot (also used on sidebar rows).
struct PulsingDot: View {
    var size: CGFloat = 7
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.working)
            .frame(width: size, height: size)
            .opacity(on ? 1 : 0.35)
            .scaleEffect(on ? 1 : 0.8)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

struct TailTarget: Identifiable, Hashable {
    let kind: ActivityKind
    let id: String
    let title: String
}

/// The live tail of a subagent's transcript or a process's output, refreshed while open.
struct ActivityTailView: View {
    let target: TailTarget
    let sessionID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var note: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? (note ?? "Loading…") : text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("end")
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .navigationTitle(target.kind == .subagent ? "Subagent" : "Background process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(target.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 460)
        #endif
        .task {
            guard let client = app.companionClient else { return }
            while !Task.isCancelled {
                do {
                    let t = try await client.activityTail(sessionID: sessionID, kind: target.kind, id: target.id)
                    let new = t.text ?? ""
                    if new != text { text = new }
                    note = (t.available == false && new.isEmpty) ? "No output yet." : nil
                } catch {
                    note = AppModel.friendly(error)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

enum TrayStyle {
    #if os(macOS)
    static let headerFont = Font.system(size: 12)
    static let rowFont = Font.system(size: 13)
    static let detailFont = Font.system(size: 11)
    static let commandFont = Font.system(size: 12, design: .monospaced)
    static let headerHeight: CGFloat = 24
    static var border: Color { MacPalette.border }
    #else
    static let headerFont = Font.footnote
    static let rowFont = Font.subheadline
    static let detailFont = Font.caption
    static let commandFont = Font.system(.caption, design: .monospaced)
    static let headerHeight: CGFloat = 30
    static var border: Color { Color(.separator).opacity(0.5) }
    #endif
}
