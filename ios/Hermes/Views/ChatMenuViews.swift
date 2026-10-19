import SwiftUI

/// "Find in chat": search the loaded conversation and jump to a match.
struct FindInChatView: View {
    @Binding var query: String
    let transcript: Transcript
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let results = transcript.matches(query)
                ForEach(results, id: \.id) { r in
                    Button { onPick(r.id) } label: {
                        Text(r.snippet).font(.callout).foregroundStyle(.primary).lineLimit(3)
                    }
                }
                if !query.trimmed.isEmpty && results.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find in chat")
            #else
            .searchable(text: $query, prompt: "Find in chat")
            #endif
            .navigationTitle("Find in chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Make a task": turn this chat into a Kanban task on a chosen board.
struct MakeTaskView: View {
    let client: KanbanClient
    let chatTitle: String
    let transcript: Transcript
    let sessionID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var boards: [KanbanBoardInfo] = []
    @AppStorage("board.selected") private var board = ""
    @State private var title = ""
    @State private var details = ""
    @State private var assignee = ""
    @State private var assignees: [String] = []
    @State private var triage = true
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical).lineLimit(1...3)
                    TextField("Details", text: $details, axis: .vertical).lineLimit(3...8)
                }
                Section {
                    Picker("Board", selection: $board) {
                        ForEach(boards) { Text("\($0.icon ?? "") \($0.displayName)").tag($0.slug) }
                    }
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        ForEach(assignees, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Put in Triage", isOn: $triage)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Make a task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }.disabled(title.trimmed.isEmpty || board.isEmpty || busy)
                }
            }
            .task {
                title = String(chatTitle.prefix(100))
                details = Self.details(transcript: transcript, sessionID: sessionID)
                do {
                    boards = try await client.boards()
                    // A chat in a workspace files its task on that workspace's board.
                    if let own = WorkspaceStore.shared.workspace(forSession: sessionID)?.boardSlug,
                       boards.contains(where: { $0.slug == own }) { board = own }
                    if !boards.contains(where: { $0.slug == board }) { board = boards.first?.slug ?? "" }
                } catch { errorMessage = "Couldn't load boards: \(AppModel.friendly(error))" }
            }
            .task(id: board) {
                guard !board.isEmpty else { return }
                assignees = (try? await client.assignees(board: board)) ?? []
                if !assignees.contains(assignee) { assignee = "" }
            }
        }
        .presentationDetents([.large])
    }

    /// Last request + last reply, so the task makes sense on its own.
    static func details(transcript: Transcript, sessionID: String?) -> String {
        var lastUser: String?
        var lastReply: String?
        for item in transcript.items {
            switch item {
            case .user(let m) where !m.text.isEmpty: lastUser = m.text
            case .assistant(_, let t, false): lastReply = t
            default: break
            }
        }
        var parts: [String] = []
        if let u = lastUser { parts.append("Request:\n\(u.prefix(1500))") }
        if let r = lastReply { parts.append("Latest reply:\n\(r.prefix(1500))") }
        if let sessionID { parts.append("From Otto chat \(sessionID)") }
        return parts.joined(separator: "\n\n")
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            try await client.createTask(board: board, title: title.trimmed, body: details.trimmed,
                                        assignee: assignee.isEmpty ? nil : assignee, triage: triage)
            Haptics.success()
            dismiss()
        } catch {
            errorMessage = AppModel.friendly(error)
        }
    }
}
