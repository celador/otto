import SwiftUI

// MARK: - Event detail

/// One record in full: intent, diff, read/write sets, squiggles, the negotiation it belongs
/// to, its task's candidates and evidence, provenance, and the human actions that apply.
struct WeftEventDetailView: View {
    let id: WeftEventID
    @State private var store = WeftStore.shared
    @State private var loading = true
    @Environment(WeftActionRouter.self) private var actions
    @Environment(\.weftOpen) private var open

    private var event: WeftEvent? { store.log.event(id) }

    var body: some View {
        Group {
            if let e = event {
                content(e)
            } else if loading {
                ProgressView()
            } else {
                ContentUnavailableView("Event #\(id.seq) isn't available", systemImage: "questionmark.circle",
                                       description: Text("It may be older than what Weft keeps, or the connection is offline."))
            }
        }
        .navigationTitle("#\(id.seq)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) {
            await store.loadDetail(id)
            loading = false
        }
    }

    private func content(_ e: WeftEvent) -> some View {
        List {
            Section { header(e) }
            if !availableActions(e).isEmpty {
                Section { actionBar(e) }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            // An edit is about its diff: show it first (the dashboard strip opens edits here).
            if e.kind == "edit" { diffSection(e) }
            if let intent = e.intent, !intent.isEmpty {
                Section("Intent") { Text(intent).font(.body) }
            }
            if !e.diagnostics.isEmpty {
                Section("Diagnostics") {
                    ForEach(Array(e.diagnostics.enumerated()), id: \.offset) { _, d in
                        WeftDiagnosticCallout(diagnostic: d, repo: e.repo)
                    }
                }
            }
            kindSection(e)
            if e.kind != "edit" { diffSection(e) }
            if !e.writes.isEmpty {
                Section("Writes") {
                    ForEach(e.writes, id: \.self) { w in
                        symbolRow(w.key, trailing: WeftFormat.writeKindLabel(w.kind), strong: w.kind == "signature" || w.kind == "deleted")
                    }
                }
            }
            if !e.reads.isEmpty {
                Section("Reads") {
                    ForEach(e.reads, id: \.self) { symbolRow($0, trailing: nil, strong: false) }
                }
            }
            let thread = store.log.thread(for: e)
            if thread.count > 1 || (e.group == .negotiate && !thread.isEmpty) {
                Section("Negotiation") {
                    ForEach(thread) { t in negotiationRow(t, current: t.id == e.id) }
                }
            }
            if let task = e.task { taskSection(e, task: task) }
            provenance(e)
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.loadDetail(id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    WeftRowMenu(event: e, router: actions, store: store)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Actions")
            }
        }
    }

    // MARK: Header

    @ViewBuilder private func diffSection(_ e: WeftEvent) -> some View {
        if e.mayHaveDiff {
            Section {
                if let diff = e.diff {
                    WeftDiffView(diff: diff)
                        .listRowInsets(EdgeInsets())
                } else {
                    HStack { ProgressView(); Text("Loading diff…").foregroundStyle(.secondary) }
                }
            } header: {
                let s = e.diff.map(WeftLineStats.from(diff:))
                HStack(spacing: 6) {
                    Text("Diff")
                    if let s {
                        Text("+\(s.added)").foregroundStyle(.green)
                        Text("−\(s.removed)").foregroundStyle(.red)
                    }
                }
            } footer: {
                if !e.files.isEmpty { Text(e.files.joined(separator: ", ")).font(.caption.monospaced()) }
            }
        }
    }

    private func header(_ e: WeftEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                WeftAvatar(actor: e.actor, agent: e.who, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(e.who).font(.headline)
                        if let h = e.harness { Text(h).font(.caption).foregroundStyle(.secondary) }
                        else if e.actor.type == "system", e.agent != nil { Text("via \(e.actor.id)").font(.caption).foregroundStyle(.secondary) }
                        if let agent = e.agent, store.log.isPaused(agent: agent, repo: e.repo) {
                            Text("PAUSED").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                        }
                    }
                    Text("\(e.repo) · #\(e.seq) · \(e.date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                WeftKindBadge(event: e)
            }
            Text(WeftSummary.withActor(e)).font(.body.weight(.medium))
            if e.isRejected {
                Label(e.mode == "check" ? "Weft stopped this edit before it was made." : "Weft rejected this submission.",
                      systemImage: "hand.raised.fill")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private enum Act: Hashable { case message, pause, resume, approve, undo }

    private func availableActions(_ e: WeftEvent) -> [Act] {
        var out: [Act] = []
        if let agent = e.agent {
            out.append(.message)
            out.append(store.log.isPaused(agent: agent, repo: e.repo) ? .resume : .pause)
        }
        if let change = e.change, e.kind != "revert", e.kind != "land",
           !(store.log.candidates(task: e.task ?? "", repo: e.repo).first { $0.change == change }?.approved ?? false) {
            out.append(.approve)
        }
        if e.kind == "land", store.log.revert(of: e) == nil { out.append(.undo) }
        return out
    }

    private func actionBar(_ e: WeftEvent) -> some View {
        HStack(spacing: 8) {
            ForEach(availableActions(e), id: \.self) { a in
                Button { run(a, e) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon(a)).font(.system(size: 17, weight: .medium))
                        Text(title(a)).font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(a == .undo ? Color.red : Color.primary)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func run(_ a: Act, _ e: WeftEvent) {
        switch a {
        case .message: if let agent = e.agent { actions.message(repo: e.repo, agent: agent) }
        case .pause: if let agent = e.agent { actions.pause(repo: e.repo, agent: agent) }
        case .resume: if let agent = e.agent { actions.resume(repo: e.repo, agent: agent) }
        case .approve: if let c = e.change { actions.approve(repo: e.repo, change: c, task: e.task) }
        case .undo: actions.undo(e)
        }
    }

    private func icon(_ a: Act) -> String {
        switch a {
        case .message: "bubble.left"
        case .pause: "pause.circle"
        case .resume: "play.circle"
        case .approve: "checkmark.seal"
        case .undo: "arrow.uturn.backward"
        }
    }

    private func title(_ a: Act) -> String {
        switch a {
        case .message: "Message"
        case .pause: "Pause"
        case .resume: "Resume"
        case .approve: "Approve"
        case .undo: "Undo"
        }
    }

    // MARK: Kind-specific

    @ViewBuilder private func kindSection(_ e: WeftEvent) -> some View {
        let p = e.payload
        switch e.kind {
        case "land":
            Section("Landing") {
                if let sha = p?["sha"]?.string { LabeledContent("Commit", value: sha).font(.callout.monospaced()) }
                if let ref = p?["trunk_ref"]?.string { LabeledContent("Trunk", value: ref).font(.callout.monospaced()) }
                if let op = p?["op_id"]?.string { LabeledContent("Operation", value: op).font(.callout.monospaced()) }
                if let r = store.log.revert(of: e) {
                    Button { open?(r.id) } label: {
                        Label("Reverted in #\(r.seq): \(r.payload?["reason"]?.string ?? r.summary)", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(.red)
                    }
                }
            }
        case "revert":
            Section("Revert") {
                if let target = p?["reverts_seq"]?.int {
                    Button { open?(WeftEventID(repo: e.repo, seq: target)) } label: {
                        LabeledContent("Undoes", value: "landing #\(target)")
                    }
                    .foregroundStyle(.primary)
                }
                if let reason = p?["reason"]?.string { LabeledContent("Reason", value: reason) }
                if let by = p?["requested_by"]?["id"]?.string { LabeledContent("Requested by", value: by) }
                if let sha = p?["sha"]?.string { LabeledContent("Commit", value: sha).font(.callout.monospaced()) }
            }
        case "checkpoint":
            Section("Checkpoint") {
                if let sha = p?["sha"]?.string { LabeledContent("Commit", value: sha).font(.callout.monospaced()) }
                if let ref = p?["ref"]?.string { LabeledContent("Branch", value: ref).font(.callout.monospaced()) }
            }
        case "message":
            Section("Message") {
                if let to = p?["to"]?["agent"]?.string ?? p?["to"]?["change"]?.string { LabeledContent("To", value: to) }
                if let intent = p?["intent"]?.string { LabeledContent("Kind", value: intent) }
                if let text = p?["text"]?.string { Text(text) }
            }
        case "control":
            Section("Human action") {
                if let a = p?["action"]?.string { LabeledContent("Action", value: a) }
                if let t = p?["target"]?["agent"]?.string ?? p?["target"]?["change"]?.string { LabeledContent("Target", value: t) }
                if let seq = p?["target"]?["seq"]?.int {
                    Button { open?(WeftEventID(repo: e.repo, seq: seq)) } label: { LabeledContent("Target", value: "#\(seq)") }
                        .foregroundStyle(.primary)
                }
                if let r = p?["reason"]?.string { LabeledContent("Reason", value: r) }
            }
        case "claim", "release":
            if let p {
                Section(e.kind == "claim" ? "Claim" : "Release") {
                    if let firm = p["firm"]?.bool { LabeledContent("Strength", value: firm ? "firm" : "soft") }
                    if let src = p["source"]?.string { LabeledContent("Source", value: src) }
                    if let ttl = p["ttl_ms"]?.int { LabeledContent("Expires after", value: "\(ttl / 60_000) min") }
                    if let reason = p["reason"]?.string { LabeledContent("Reason", value: reason) }
                }
            }
        default:
            EmptyView()
        }
    }

    private func negotiationRow(_ t: WeftEvent, current: Bool) -> some View {
        Button { if !current { open?(t.id) } } label: {
            HStack(alignment: .top, spacing: 10) {
                WeftAvatar(actor: t.actor, agent: t.who, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(t.who).font(.subheadline.weight(.semibold))
                        WeftKindBadge(event: t)
                        if let k = t.payload?["terms"]?["kind"]?.string {
                            Text(k).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("#\(t.seq)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let text = t.payload?["terms"]?["text"]?.string ?? t.payload?["reason"]?.string {
                        Text(text).font(.callout)
                    }
                    if let keys = t.payload?["keys"]?.array?.compactMap(\.string), !keys.isEmpty {
                        Text(keys.map(WeftSymbol.display).joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .opacity(current ? 1 : 0.9)
        }
        .buttonStyle(.plain)
        .listRowBackground(current ? Color.primary.opacity(0.05) : Color(.secondarySystemGroupedBackground))
    }

    @ViewBuilder private func taskSection(_ e: WeftEvent, task: String) -> some View {
        let candidates = store.log.candidates(task: task, repo: e.repo)
        Section {
            LabeledContent("Task", value: store.log.taskTitle(task) ?? task)
            if let change = e.change { LabeledContent("Change", value: change).font(.callout.monospaced()) }
            ForEach(candidates) { c in
                Button { open?(c.latest) } label: {
                    HStack(spacing: 8) {
                        WeftAvatar(actor: WeftActor(type: "agent", id: c.agent, harness: c.harness), agent: c.agent, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.agent).font(.subheadline.weight(c.change == e.change ? .semibold : .regular))
                            Text(c.change).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.reverted { tag("reverted", .red) }
                        else if c.landedSeq != nil { tag("landed", .green) }
                        if c.approved { tag("approved", .primary) }
                        if let t = c.evidence?.tests, let total = t.total {
                            tag("\(t.passed ?? 0)/\(total) tests", (t.failed ?? 0) > 0 ? .red : .secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(candidates.count > 1 ? "Task · \(candidates.count) candidates" : "Task")
        }
        if let ev = candidates.first(where: { $0.change == e.change })?.evidence ?? e.evidence {
            evidenceSection(ev)
        }
    }

    @ViewBuilder private func evidenceSection(_ ev: WeftEvidence) -> some View {
        Section("Evidence") {
            if let s = ev.previewURL, let url = URL(string: s) {
                Link(destination: url) {
                    Label(url.host() ?? s, systemImage: "safari")
                }
            }
            if let t = ev.tests, let total = t.total {
                LabeledContent("Tests", value: "\(t.passed ?? 0) passed · \(t.failed ?? 0) failed · \(total)")
            }
            if let r = ev.review {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Review", value: r.verdict ?? "—")
                    if let s = r.summary { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let cost = ev.costUSD { LabeledContent("Cost", value: cost.formatted(.currency(code: "USD"))) }
            if let shots = ev.screenshots, !shots.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(shots, id: \.self) { s in
                            if let url = URL(string: s) {
                                Link(destination: url) {
                                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color(.tertiarySystemFill) }
                                        .frame(width: 120, height: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder private func provenance(_ e: WeftEvent) -> some View {
        Section("Provenance") {
            if let tool = e.tool {
                LabeledContent("Tool", value: [tool.name, tool.harnessEvent].compactMap { $0 }.joined(separator: " · "))
            }
            if let base = e.baseSeq {
                Button { open?(WeftEventID(repo: e.repo, seq: base)) } label: { LabeledContent("Based on", value: "#\(base)") }
                    .foregroundStyle(.primary)
                    .disabled(base == 0)
            }
            if let mode = e.mode { LabeledContent("Mode", value: mode == "check" ? "pre-edit check" : "commit") }
            if let s = e.session { LabeledContent("Session", value: s).font(.callout.monospaced()) }
            if let t = e.transcript {
                LabeledContent("Transcript", value: t.uri + (t.offset.map { " @\($0)" } ?? ""))
                    .font(.caption.monospaced())
            }
        }
    }

    private func symbolRow(_ key: String, trailing: String?, strong: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(WeftSymbol.display(key)).font(.callout.monospaced().weight(strong ? .semibold : .regular))
                Text(WeftSymbol.file(key)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing { tag(trailing, strong ? .orange : .secondary) }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Row / detail menu

/// Long-press menu on a feed row and the detail screen's ⋯ menu.
struct WeftRowMenu: View {
    let event: WeftEvent
    let router: WeftActionRouter
    let store: WeftStore

    var body: some View {
        if let agent = event.agent {
            Button { router.message(repo: event.repo, agent: agent) } label: { Label("Message \(agent)", systemImage: "bubble.left") }
            if store.log.isPaused(agent: agent, repo: event.repo) {
                Button { router.resume(repo: event.repo, agent: agent) } label: { Label("Resume \(agent)", systemImage: "play.circle") }
            } else {
                Button { router.pause(repo: event.repo, agent: agent) } label: { Label("Pause \(agent)", systemImage: "pause.circle") }
            }
        }
        if let change = event.change, event.kind != "revert", event.kind != "land" {
            Button { router.approve(repo: event.repo, change: change, task: event.task) } label: {
                Label("Approve candidate", systemImage: "checkmark.seal")
            }
        }
        if event.kind == "land", store.log.revert(of: event) == nil {
            Divider()
            Button(role: .destructive) { router.undo(event) } label: { Label("Undo landing…", systemImage: "arrow.uturn.backward") }
        }
        Divider()
        Button { UIPasteboard.general.string = WeftSummary.withActor(event) } label: { Label("Copy summary", systemImage: "doc.on.doc") }
    }
}

// MARK: - Human actions (spec §9.6)

/// Pending human action awaiting a sheet / confirmation, shared by the feed and detail.
@MainActor
@Observable
final class WeftActionRouter {
    struct MessageDraft: Identifiable { var repo: String; var agent: String; var id: String { repo + agent } }
    struct ApproveDraft: Identifiable { var repo: String; var change: String; var task: String?; var id: String { change } }
    struct AgentTarget: Identifiable { var repo: String; var agent: String; var id: String { repo + agent } }

    var messageDraft: MessageDraft?
    var approveDraft: ApproveDraft?
    var undoTarget: WeftEvent?
    var pauseTarget: AgentTarget?
    var errorMessage: String?
    var confirmation: String?

    func message(repo: String, agent: String) { messageDraft = MessageDraft(repo: repo, agent: agent) }
    func approve(repo: String, change: String, task: String?) { approveDraft = ApproveDraft(repo: repo, change: change, task: task) }
    func undo(_ land: WeftEvent) { undoTarget = land }
    func pause(repo: String, agent: String) { pauseTarget = AgentTarget(repo: repo, agent: agent) }
    func resume(repo: String, agent: String) { run(.resume(agent: agent), repo: repo, done: "Resumed \(agent)") }

    func run(_ action: WeftAction, repo: String, done: String) {
        Task {
            do {
                try await WeftStore.shared.perform(action, repo: repo)
                Haptics.success()
                confirmation = done
                try? await Task.sleep(for: .seconds(2))
                if confirmation == done { confirmation = nil }
            } catch {
                errorMessage = WeftStore.describe(error)
            }
        }
    }
}

extension View {
    func weftActions(_ router: WeftActionRouter, store: WeftStore) -> some View {
        modifier(WeftActionsHost(router: router))
    }
}

private struct WeftActionsHost: ViewModifier {
    @Bindable var router: WeftActionRouter
    @State private var undoReason = ""
    @State private var pauseReason = ""

    func body(content: Content) -> some View {
        content
            .environment(router)
            .sheet(item: $router.messageDraft) { d in
                WeftMessageSheet(draft: d) { text, intent in
                    router.run(.message(agent: d.agent, text: text, intent: intent), repo: d.repo, done: "Sent to \(d.agent)")
                }
            }
            .sheet(item: $router.approveDraft) { d in
                WeftApproveSheet(draft: d) { note in
                    router.run(.approve(change: d.change, task: d.task, note: note), repo: d.repo, done: "Approved \(d.change)")
                }
            }
            .alert("Undo this landing?", isPresented: Binding(get: { router.undoTarget != nil }, set: { if !$0 { router.undoTarget = nil } })) {
                TextField("Reason", text: $undoReason)
                Button("Undo landing", role: .destructive) {
                    if let land = router.undoTarget {
                        let reason = undoReason.trimmingCharacters(in: .whitespaces)
                        router.run(.undo(seq: land.seq, reason: reason.isEmpty ? "undone from Hermes iOS" : reason),
                                   repo: land.repo, done: "Revert requested")
                    }
                    undoReason = ""
                    router.undoTarget = nil
                }
                Button("Cancel", role: .cancel) { undoReason = ""; router.undoTarget = nil }
            } message: {
                if let land = router.undoTarget {
                    Text("Weft lands a revert of #\(land.seq) on trunk. Agents whose work depends on it get a squiggle.")
                }
            }
            .alert("Pause \(router.pauseTarget?.agent ?? "agent")?", isPresented: Binding(get: { router.pauseTarget != nil }, set: { if !$0 { router.pauseTarget = nil } })) {
                TextField("Reason (optional)", text: $pauseReason)
                Button("Pause") {
                    if let t = router.pauseTarget {
                        router.run(.pause(agent: t.agent, reason: pauseReason), repo: t.repo, done: "Paused \(t.agent)")
                    }
                    pauseReason = ""
                    router.pauseTarget = nil
                }
                Button("Cancel", role: .cancel) { pauseReason = ""; router.pauseTarget = nil }
            } message: {
                Text("Its edits, claims and pushes are refused until you resume it. It can still finish talking.")
            }
            .alert("Couldn't do that", isPresented: Binding(get: { router.errorMessage != nil }, set: { if !$0 { router.errorMessage = nil } })) {
                Button("OK", role: .cancel) { router.errorMessage = nil }
            } message: {
                Text(router.errorMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                if let c = router.confirmation {
                    Label(c, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.primary, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: router.confirmation)
    }
}

/// Steer or negotiate with an agent without touching its code.
struct WeftMessageSheet: View {
    let draft: WeftActionRouter.MessageDraft
    let send: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var intent = "steer"
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $intent) {
                        Text("Steer").tag("steer")
                        Text("Negotiate").tag("negotiate")
                        Text("Info").tag("info")
                    }
                    .pickerStyle(.segmented)
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($focused)
                } footer: {
                    Text("Delivered to \(draft.agent)'s inbox on its next tool call, and logged in the change log as yours.")
                }
            }
            .navigationTitle("Message \(draft.agent)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send(text.trimmingCharacters(in: .whitespacesAndNewlines), intent)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var placeholder: String {
        switch intent {
        case "negotiate": "Propose terms, e.g. keep the old signature as an overload"
        case "info": "Something it should know"
        default: "Tell it what to do differently"
        }
    }
}

struct WeftApproveSheet: View {
    let draft: WeftActionRouter.ApproveDraft
    let approve: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Candidate", value: draft.change).font(.callout.monospaced())
                    if let t = draft.task { LabeledContent("Task", value: WeftStore.shared.log.taskTitle(t) ?? t) }
                    TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text("Approving lets the landing queue merge this candidate. The other candidates for the task stay open.")
                }
            }
            .navigationTitle("Approve candidate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") { approve(note); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Filters

struct WeftFilterSheet: View {
    @Binding var filter: WeftFilter
    let log: WeftLog
    let repos: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $filter.showSessionEvents) {
                        Label("Show session events", systemImage: "person.2.badge.gearshape")
                    }
                    .tint(.green)
                } footer: {
                    Text("Agents joining and leaving, claims and releases. Hidden by default so the edits, checkpoints and landings stand out.")
                }
                Section {
                    Toggle(isOn: $filter.onlyConflicts) {
                        Label("Only conflicts", systemImage: "exclamationmark.triangle")
                    }
                    .tint(.green)   // the app's monochrome accent hides the knob in dark mode
                } footer: {
                    Text("Blocked edits and anything with a squiggle.")
                }
                Section("Kind") {
                    ForEach(WeftKindGroup.filterable, id: \.self) { k in
                        toggleRow(k.label.capitalized, on: filter.kinds.contains(k)) { filter.kinds.formSymmetricDifference([k]) }
                    }
                }
                if repos.count > 1 {
                    Section("Repo") {
                        ForEach(repos, id: \.self) { r in
                            toggleRow(r, on: filter.repos.contains(r)) { filter.repos.formSymmetricDifference([r]) }
                        }
                    }
                }
                if !log.agents.isEmpty {
                    Section("Agent") {
                        ForEach(log.agents, id: \.self) { a in
                            toggleRow(a, on: filter.agents.contains(a)) { filter.agents.formSymmetricDifference([a]) }
                        }
                    }
                }
                if !log.tasks.isEmpty {
                    Section("Task") {
                        ForEach(log.tasks, id: \.self) { t in
                            toggleRow(log.taskTitle(t).map { "\($0) (\(t))" } ?? t, on: filter.tasks.contains(t)) {
                                filter.tasks.formSymmetricDifference([t])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { filter = WeftFilter() }.disabled(filter.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func toggleRow(_ title: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Connection settings

struct WeftSettingsView: View {
    @State private var store = WeftStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var url = WeftStore.shared.config?.baseURL.absoluteString ?? WeftSettingsView.defaultURL
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showAdvanced = false

    nonisolated static let defaultURL = "https://weft-gateway-preview.elier.ai"

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                if store.isConfigured, !store.repoNames.isEmpty {
                    Section {
                        ForEach(store.repoNames, id: \.self) { r in
                            LabeledContent(r) {
                                let last = store.log.lastActivity[r].map { Date(timeIntervalSinceReferenceDate: $0) }
                                Text("#\(store.log.resumePoint(r))" + (last.map { " · \(WeftFormat.age($0))" } ?? ""))
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        Text("Repos with changes")
                    } footer: {
                        Text("Most recently active first. Repos with no changes yet aren't listed.")
                    }
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advancedFields }
                } footer: {
                    if showAdvanced {
                        Text("Override the automatic connection with another gateway or token. An observer token only reads; a human token also approves, undoes, pauses and messages agents. It stays in this device's Keychain.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Weft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if let c = store.config { url = c.baseURL.absoluteString } }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 460)
        #endif
    }

    @ViewBuilder private var connectionSection: some View {
        Section {
            if let c = store.config {
                LabeledContent("Gateway", value: c.baseURL.host() ?? c.baseURL.absoluteString)
                LabeledContent("Access", value: Self.accessLabel(c.scope))
                LabeledContent("Set up", value: c.isAuto ? "Automatically, by your Hermes host" : "By hand (Advanced)")
                if !c.isAuto {
                    Button("Use Automatic Connection") { Task { await store.useAutomatic() } }
                }
            } else {
                switch store.autoStatus {
                case .failed(let f):
                    Label(f.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { Task { await store.autoConfigure(renew: true) } }
                default:
                    HStack { ProgressView().controlSize(.small); Text("Connecting through your Hermes host…") }
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            if store.config?.isAuto != false {
                Text("Otto gets the Weft address and token from your Hermes host. Nothing to enter.")
            }
        }
    }

    @ViewBuilder private var advancedFields: some View {
        TextField("Address", text: $url, prompt: Text(Self.defaultURL))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        SecureField("Token", text: $token, prompt: Text(store.isConfigured ? "Unchanged" : "Token"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        if let error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        HStack {
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Save Override") { Task { await save() } }
                .disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty || (!store.isConfigured && token.isEmpty))
        }
    }

    nonisolated static func accessLabel(_ scope: String?) -> String {
        switch scope {
        case "human": "Approve, undo, pause, message"
        case "observe": "Read-only"
        default: "Token from Advanced"
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let t = token.isEmpty ? (store.config?.token ?? "") : token
            try await store.connect(url: url, token: t)
            error = nil
            dismiss()
        } catch {
            self.error = WeftStore.describe(error)
        }
    }
}
