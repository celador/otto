import SwiftUI

// MARK: - Now line + signal on a running card

/// "Running tests · 2m" ticking live, plus a quiet badge when the card looks slow or stuck.
struct CardNowLine: View {
    let live: CardLive?
    var font: Font = .system(size: 10.5)

    var body: some View {
        if let live {
            let anchor = CardNow.of(live, now: .now)?.since ?? Date(timeIntervalSince1970: live.lastActivityAt ?? live.runStartedAt ?? Date().timeIntervalSince1970)
            TimelineView(LiveTimeSchedule(anchor: anchor)) { ctx in
                let now = CardNow.of(live, now: ctx.date)
                let signal = CardSignal.of(live, now: ctx.date)
                HStack(spacing: 5) {
                    if let now {
                        Image(systemName: Self.symbol(now.phrase, wait: live.now?.wait))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(now.label(now: ctx.date))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let label = signal.label {
                        CardSignalBadge(signal: signal, label: label)
                    }
                }
                .font(font)
                .monospacedDigit()
            }
            .help(Self.help(live))
            .accessibilityElement(children: .combine)
        }
    }

    static func symbol(_ phrase: String, wait: String?) -> String {
        let p = phrase.lowercased()
        if wait == "apple" || p.contains("upload") { return "icloud.and.arrow.up" }
        if p.contains("test") { return "checklist" }
        if p.contains("build") || p.contains("export") || p.contains("releas") { return "hammer" }
        if p.contains("merg") || p.contains("landing") || p.contains("push") || p.contains("commit") { return "arrow.triangle.merge" }
        if p.contains("install") { return "square.and.arrow.down" }
        if p.contains("edit") { return "pencil" }
        if p.contains("reading") { return "doc.text.magnifyingglass" }
        if p.contains("wait") || wait == "wait" || wait == "network" { return "hourglass" }
        if p.contains("screenshot") { return "camera.viewfinder" }
        if p.contains("thinking") || p.contains("starting") { return "ellipsis" }
        return "terminal"
    }

    /// Hover: the exact call and the agent's last words.
    static func help(_ live: CardLive) -> String {
        var lines: [String] = []
        if let s = live.now?.summary { lines.append(s) }
        if let said = live.said?.text { lines.append("“\(said)”") }
        if let trail = CardTrail.text(live.trail) { lines.append(trail) }
        return lines.joined(separator: "\n")
    }
}

struct CardSignalBadge: View {
    let signal: CardSignal
    let label: String

    private var color: Color {
        switch signal {
        case .stopped: .red
        case .quiet: .orange
        default: .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// "Merging ✓ · Running tests ✓ · Building the Mac app …" (last 5 milestones).
struct CardTrailLine: View {
    let trail: [CardLive.TrailStep]
    var font: Font = .system(size: 10)

    var body: some View {
        if !trail.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(trail.enumerated()), id: \.offset) { i, step in
                    if i > 0 { Text("·").foregroundStyle(.tertiary) }
                    HStack(spacing: 2) {
                        Text(step.phrase)
                        Text(CardTrail.mark(step.state))
                            .foregroundStyle(step.state == "done" ? Color.green : step.state == "failed" ? Color.red : Color.secondary)
                    }
                    .lineLimit(1)
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
    }
}

// MARK: - Watch a running card's worker session (read-only)

/// The card's worker session in the same transcript view as a chat, following live, with a
/// "Note to this task" box that posts a card comment (Hermes steers it into the running worker).
struct WatchCardView: View {
    let target: WatchTarget
    /// Mac / iPad pane: "← Back to your chat". nil in a sheet (it has Done).
    var onBack: (() -> Void)? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatModel?
    @State private var store = CardLiveStore.shared
    @State private var note = ""
    @State private var sending = false
    @State private var noteStatus: String?
    @State private var noteFailed = false

    private var live: CardLive? { store.live(target.taskID) }
    /// Still running (as far as the board knows); after it ends the transcript gets one last read.
    private var running: Bool { live != nil && live?.workerAlive != false }

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider().opacity(0.6)
            transcript
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { noteBox }
        #if os(macOS)
        .background(Color(.systemBackground))
        #endif
        .task(id: target.sessionID) {
            guard let client = app.client else { return }
            let m = model ?? ChatModel(client: client, sessionID: target.sessionID)
            model = m
            // Follow the worker: re-read the stored transcript every few seconds (tool calls are stored
            // as they start), then once more after the card stops running.
            while !Task.isCancelled {
                await m.load(remoteRun: running)
                if !running { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .task(id: target.board) {
            // Keep the Now line fresh even when no board panel is on screen (iPhone sheet, Board hidden).
            while !Task.isCancelled {
                await store.load(board: target.board, running: [target.taskID], companion: app.companionClient)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: running) { was, now in
            if was && !now, let model { Task { await model.load() } }
        }
        #if os(iOS)
        .navigationTitle("Watching")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onBack == nil {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #endif
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let onBack {
                    Button(action: onBack) {
                        Label("Back to your chat", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Back to your chat")
                    Divider().frame(height: 14)
                }
                Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Watching").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(target.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if running { PulsingDot(size: 6) } else {
                    Text("Finished").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if running {
                HStack(spacing: 10) {
                    CardNowLine(live: live, font: .system(size: 11.5))
                    CardTrailLine(trail: live?.trail ?? [], font: .system(size: 11))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.06))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var transcript: some View {
        if let model {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let rows = model.rows
                        let dayStarts = model.dayStarts
                        #if os(macOS)
                        ForEach(MacTranscript.group(rows)) { entry in
                            switch entry {
                            case .row(let row): rowView(row, model: model, dayStart: dayStarts[row.id])
                            case .tools(let id, let tools): MacToolGroup(tools: tools).id(id)
                            }
                        }
                        #else
                        ForEach(rows) { row in rowView(row, model: model, dayStart: dayStarts[row.id]) }
                        #endif
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .frame(maxWidth: ChatLayout.readableWidth)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.rows) {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay {
                    if model.rows.isEmpty {
                        if model.isLoading { ProgressView() } else {
                            Text("Nothing in this session yet.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                #if os(macOS)
                .scrollContentBackground(.hidden)
                .font(.system(size: 14))
                .lineSpacing(2.5)
                #endif
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func rowView(_ row: ChatRow, model: ChatModel, dayStart: Date?) -> some View {
        if case .item(let item) = row {
            VStack(spacing: 12) {
                if let dayStart { DaySeparator(date: dayStart) }
                ChatItemView(item: item, date: model.date(for: item.id)) { _, _ in }
            }
            .id(row.id)
        }
    }

    private var noteBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Note to this task", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { Task { await sendNote() } }
                    .disabled(sending)
                Button { Task { await sendNote() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.primary)
                .disabled(sending || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Post this note as a comment on the card")
                .accessibilityLabel("Send note")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(noteStatus ?? (running ? "Posted as a comment on the card. The worker gets it at its next step."
                                         : "Posted as a comment on the card."))
                .font(.system(size: 10.5))
                .foregroundStyle(noteFailed ? Color.orange : Color.secondary)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: ChatLayout.readableWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func sendNote() async {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = app.kanbanClient else { return }
        sending = true
        defer { sending = false }
        do {
            try await client.comment(target.taskID, board: target.board, body: text)
            note = ""
            noteFailed = false
            noteStatus = "Sent. The worker gets it at its next step."
            Haptics.success()
        } catch {
            noteFailed = true
            noteStatus = "Couldn't post the note: \(AppModel.friendly(error))"
        }
    }
}

extension WatchTarget {
    /// Open it: the Mac shows it in the chat pane; elsewhere the caller presents a sheet.
    @MainActor func open() {
        NotificationCenter.default.post(name: .watchCard, object: self)
    }
}
