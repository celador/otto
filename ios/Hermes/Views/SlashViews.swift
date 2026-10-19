import SwiftUI

/// A slash command and what it returned, inline in the chat (monospaced, like Telegram's bot replies).
struct SlashEntryView: View {
    let entry: SlashEntry
    var onOpen: (String) -> Void = { _ in }
    var onRemove: (() -> Void)? = nil
    var onClearAll: (() -> Void)? = nil
    @State private var expanded = false

    private static let collapsedLines = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                Text(entry.command)
                    .font(.footnote.monospaced().weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if entry.running { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(.secondary)
            if let output = shownOutput, !output.isEmpty {
                if Self.isTabular(output) {
                    // Boxes and aligned columns (/help, /insights, /sessions) keep their shape and scroll sideways.
                    ScrollView(.horizontal, showsIndicators: false) {
                        outputText(output).fixedSize(horizontal: true, vertical: true)
                    }
                } else {
                    outputText(output).fixedSize(horizontal: false, vertical: true)
                }
                if isLong {
                    Button(expanded ? "Show less" : "Show more") { withAnimation { expanded.toggle() } }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            } else if entry.running {
                Text("Running on your Mac…").font(.footnote).foregroundStyle(.secondary)
            }
            if let id = entry.openSessionID {
                Button { onOpen(id) } label: {
                    Label("Open chat", systemImage: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if let output = entry.output {
                Button { UIPasteboard.general.string = output } label: { Label("Copy output", systemImage: "doc.on.doc") }
            }
            Button { UIPasteboard.general.string = entry.command } label: { Label("Copy command", systemImage: "terminal") }
            if let onRemove {
                Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
            }
            if let onClearAll {
                Button(role: .destructive, action: onClearAll) { Label("Remove all command results", systemImage: "trash.slash") }
            }
        }
    }

    private func outputText(_ output: String) -> some View {
        Text(output)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(entry.isError ? Color.red : Color.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Box drawing or column-aligned text: wrapping would scramble it.
    nonisolated static func isTabular(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: { (0x2500...0x257F).contains($0.value) || (0x2580...0x259F).contains($0.value) }) {
            return true
        }
        let lines = text.split(separator: "\n")
        let aligned = lines.filter { $0.contains("   ") && $0.trimmingCharacters(in: .whitespaces).contains("  ") }
        let boxed = lines.filter { $0.hasPrefix("+--") || $0.hasPrefix("|") }
        return boxed.count >= 2 || aligned.count >= 3
    }

    private var lines: [Substring] { (entry.output ?? "").split(separator: "\n", omittingEmptySubsequences: false) }
    private var isLong: Bool { lines.count > Self.collapsedLines + 2 }
    private var shownOutput: String? {
        guard let output = entry.output?.trimmingCharacters(in: .newlines) else { return nil }
        if expanded || !isLong { return output }
        return lines.prefix(Self.collapsedLines).joined(separator: "\n")
    }
}

/// Telegram-style command menu above the composer while typing "/…".
struct SlashSuggestionList: View {
    let commands: [SlashCommand]
    let onPick: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { cmd in
                    Button { onPick(cmd) } label: { SlashCommandRow(command: cmd) }
                        .buttonStyle(.plain)
                    if cmd.id != commands.last?.id { Divider().padding(.leading, 14) }
                }
            }
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: min(CGFloat(commands.count) * 54, 250))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityLabel("Commands")
    }
}

struct SlashCommandRow: View {
    let command: SlashCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("/" + command.name)
                    .font(.callout.monospaced().weight(.medium))
                    .foregroundStyle(.primary)
                if command.takesArgs {
                    Text(command.args)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if command.isSkill {
                    Text("skill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(command.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Every command, grouped like Telegram's /help: built-ins by category, then skills.
struct SlashCommandsSheet: View {
    let commands: [SlashCommand]
    @State var filter: String
    let onPick: (SlashCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    init(commands: [SlashCommand], filter: String, onPick: @escaping (SlashCommand) -> Void) {
        self.commands = commands
        _filter = State(initialValue: filter)
        self.onPick = onPick
    }

    private var shown: [SlashCommand] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !q.isEmpty else { return commands }
        return commands.filter { $0.name.contains(q) || $0.description.lowercased().contains(q) }
    }

    private var sections: [(String, [SlashCommand])] {
        var order: [String] = []
        var groups: [String: [SlashCommand]] = [:]
        for c in shown {
            let key = c.isSkill ? "Skills" : c.category
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(c)
        }
        return order.sorted { ($0 == "Skills" ? 1 : 0) < ($1 == "Skills" ? 1 : 0) }.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { title, cmds in
                    Section(title) {
                        ForEach(cmds) { cmd in
                            Button { onPick(cmd) } label: { SlashCommandRow(command: cmd) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Search commands")
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
