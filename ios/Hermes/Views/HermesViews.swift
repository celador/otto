import SwiftUI

// MARK: - Shared: which agent (profile) a screen is looking at

/// Profiles list shared by the Agents, Skills and Memory screens.
@MainActor @Observable
final class ProfilesStore {
    static let shared = ProfilesStore()
    var profiles: [HermesProfile] = []
    var active = "default"
    var loaded = false
    /// Selected profile for Skills/Memory (persisted).
    var selected: String = UserDefaults.standard.string(forKey: "companion.profile") ?? "default" {
        didSet { UserDefaults.standard.set(selected, forKey: "companion.profile") }
    }

    func load(_ client: CompanionClient) async throws {
        let r = try await client.profiles()
        profiles = r.profiles
        active = r.active
        loaded = true
        if !profiles.contains(where: { $0.name == selected }) { selected = "default" }
    }

    func title(_ name: String) -> String {
        profiles.first { $0.name == name }?.title ?? (name == "default" ? "Main agent" : name)
    }
}

/// Toolbar menu to switch the agent a screen shows.
struct ProfilePickerMenu: View {
    @Bindable var store: ProfilesStore

    var body: some View {
        Menu {
            Picker("Agent", selection: $store.selected) {
                ForEach(store.profiles) { p in
                    Text(p.title).tag(p.name)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.title(store.selected)).font(.subheadline.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .disabled(store.profiles.count < 2)
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "wifi.exclamationmark")
            .font(.callout).foregroundStyle(.orange)
    }
}

// MARK: - Agents (profiles)

struct AgentsView: View {
    @Environment(AppModel.self) private var app
    @State private var store = ProfilesStore.shared
    @State private var errorMessage: String?
    let onOpenSkills: (String) -> Void
    let onOpenMemory: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                Section {
                    ForEach(store.profiles) { p in
                        NavigationLink(value: p) { AgentRow(profile: p, isActive: p.name == store.active) }
                    }
                } footer: {
                    Text("Each agent is a profile on your agent server, with its own model, skills, memory and chats.")
                }
            }
            .overlay { if !store.loaded && errorMessage == nil { ProgressView() } }
            .refreshable { await load() }
            .navigationTitle("Agents")
            .menuButton()
            .navigationDestination(for: HermesProfile.self) { p in
                AgentDetailView(name: p.name, isActive: p.name == store.active,
                                onOpenSkills: { onOpenSkills(p.name) }, onOpenMemory: { onOpenMemory(p.name) })
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let c = app.companionClient else { return }
        do { try await store.load(c); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }
}

private struct AgentRow: View {
    let profile: HermesProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(name: profile.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.title).font(.body.weight(.medium))
                    if isActive {
                        Text("Default").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                Text([profile.modelShort, profile.skillCount.map { "\($0) skills" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if profile.gatewayRunning == true {
                Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Online")
            }
        }
        .padding(.vertical, 2)
    }
}

struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: Circle())
    }
}

private struct AgentDetailView: View {
    let name: String
    let isActive: Bool
    let onOpenSkills: () -> Void
    let onOpenMemory: () -> Void
    @Environment(AppModel.self) private var app
    @State private var store = ProfilesStore.shared
    @State private var picking = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        if let profile = store.profiles.first(where: { $0.name == name }) { content(profile) }
    }

    private func content(_ profile: HermesProfile) -> some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AgentAvatar(name: profile.title, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.title).font(.title3.bold())
                        if profile.name != profile.title {
                            Text(profile.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                if let d = profile.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { ErrorBanner(message: errorMessage) }
            Section {
                Button { picking = true } label: {
                    HStack {
                        LabeledContent("Model", value: profile.model ?? "—")
                        if saving { ProgressView().padding(.leading, 6) }
                        else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(saving)
                if let p = profile.provider { LabeledContent("Provider", value: p) }
                LabeledContent("Messaging", value: profile.gatewayRunning == true ? "Online" : "Off")
                if isActive { LabeledContent("Default agent", value: "Yes") }
            }
            Section {
                Button(action: onOpenSkills) {
                    Label("Skills\(profile.skillCount.map { " (\($0))" } ?? "")", systemImage: "sparkles")
                }
                Button(action: onOpenMemory) { Label("Memory", systemImage: "brain") }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle(profile.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $picking) {
            ModelPickerView(selection: Binding(
                get: { profile.provider.flatMap { p in profile.model.map { ModelChoice(provider: p, model: $0) } } },
                set: { choice in if let choice { Task { await save(choice, for: profile) } } }),
                allowDefault: false, title: "\(profile.title)'s model")
        }
    }

    private func save(_ choice: ModelChoice, for profile: HermesProfile) async {
        guard let c = app.companionClient, choice.model != profile.model || choice.provider != profile.provider else { return }
        saving = true
        defer { saving = false }
        do {
            try await c.setProfileModel(profile.name, choice: choice)
            try await store.load(c)
            errorMessage = nil
            Haptics.success()
        } catch {
            errorMessage = "Couldn't change the model: \(error.localizedDescription)"
            Haptics.error()
        }
    }
}

// MARK: - Skills

struct SkillsView: View {
    @Environment(AppModel.self) private var app
    @State private var store = ProfilesStore.shared
    @State private var skills: [HermesSkill] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var busy: String?

    enum Filter: String, CaseIterable { case all = "All", on = "On", off = "Off" }

    private var grouped: [(String, [HermesSkill])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = skills.filter { s in
            (filter == .all || (filter == .on) == s.enabled)
                && (q.isEmpty || s.name.lowercased().contains(q) || s.summary.lowercased().contains(q))
        }
        return Dictionary(grouping: list) { ($0.category?.isEmpty == false ? $0.category! : "general") }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                ForEach(grouped, id: \.0) { category, items in
                    Section(SkillsView.categoryTitle(category)) {
                        ForEach(items) { s in
                            NavigationLink(value: s) { SkillRow(skill: s, busy: busy == s.name) }
                                .swipeActions(edge: .trailing) {
                                    Button { Task { await toggle(s) } } label: {
                                        Label(s.enabled ? "Turn off" : "Turn on", systemImage: s.enabled ? "pause.circle" : "play.circle")
                                    }
                                    .tint(s.enabled ? .orange : .green)
                                }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search skills")
            .overlay {
                if skills.isEmpty && loading { ProgressView() }
                else if !skills.isEmpty && grouped.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .refreshable { await load() }
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .toolbar { ToolbarItem(placement: .principal) { ProfilePickerMenu(store: store) } }
            .navigationDestination(for: HermesSkill.self) { s in
                SkillDetailView(skill: skills.first { $0.name == s.name } ?? s, profile: store.selected,
                                busy: busy == s.name) { await toggle($0) }
            }
            .task(id: store.selected) { await load() }
        }
    }

    static func categoryTitle(_ c: String) -> String {
        c.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "/", with: " · ").capitalized
    }

    private func load() async {
        guard let c = app.companionClient else { return }
        loading = true
        defer { loading = false }
        do {
            if !store.loaded { try? await store.load(c) }
            skills = try await c.skills(profile: store.selected)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func toggle(_ s: HermesSkill) async {
        guard let c = app.companionClient, busy == nil else { return }
        busy = s.name
        defer { busy = nil }
        do {
            try await c.setSkill(s.name, enabled: !s.enabled, profile: store.selected)
            if let i = skills.firstIndex(where: { $0.name == s.name }) { skills[i].enabled.toggle() }
            Haptics.success()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct SkillRow: View {
    let skill: HermesSkill
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name).font(.body.weight(.medium)).foregroundStyle(skill.enabled ? .primary : .secondary)
                if !skill.enabled {
                    Text("Off").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
            }
            if !skill.summary.isEmpty {
                Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SkillDetailView: View {
    @Environment(AppModel.self) private var app
    let skill: HermesSkill
    let profile: String
    let busy: Bool
    let onToggle: (HermesSkill) async -> Void
    @State private var content: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(skill.name).font(.title2.bold())
                    if !skill.summary.isEmpty { Text(skill.summary).foregroundStyle(.secondary) }
                    HStack(spacing: 8) {
                        if let c = skill.category { Chip(text: SkillsView.categoryTitle(c)) }
                        if let u = skill.usage, u > 0 { Chip(text: "Used \(u)×") }
                        if let p = skill.provenance { Chip(text: p == "agent" ? "Made by your agent" : p.capitalized) }
                    }
                }
                Toggle(isOn: Binding(get: { skill.enabled }, set: { _ in Task { await onToggle(skill) } })) {
                    Text(skill.enabled ? "On — your agent can use this skill" : "Off — hidden from your agent")
                        .font(.subheadline)
                }
                .disabled(busy)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Divider()
                if let content {
                    MarkdownText(text: SkillDetailView.stripFrontmatter(content))
                } else if let errorMessage {
                    ErrorBanner(message: errorMessage)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let content {
                ShareLink(item: content) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task {
            guard content == nil, let c = app.companionClient else { return }
            do { content = try await c.skillContent(skill.name, profile: profile) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// Drops the YAML header (name/description are shown above).
    nonisolated static func stripFrontmatter(_ s: String) -> String {
        guard s.hasPrefix("---") else { return s }
        let lines = s.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return s }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

enum SkillDetailViewProbe {
    static func strip(_ s: String) -> String { SkillDetailView.stripFrontmatter(s) }
}

// MARK: - Memory

struct MemoryView: View {
    @Environment(AppModel.self) private var app
    @State private var store = ProfilesStore.shared
    @State private var state: MemoryState?
    @State private var target: MemoryTarget = .memory
    /// Notes / About you are Hermes's own memory files; Learned is what Honcho picked up.
    @State private var learned = false
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var editing: Editing?
    @State private var saving = false

    struct Editing: Identifiable {
        let id = UUID()
        let original: String?
        var text: String
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Section", selection: Binding(
                    get: { learned ? "learned" : target.rawValue },
                    set: { v in
                        learned = v == "learned"
                        if let t = MemoryTarget(rawValue: v) { target = t }
                    })) {
                    ForEach(MemoryTarget.allCases) { Text($0.title).tag($0.rawValue) }
                    Text("Learned").tag("learned")
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                if learned {
                    LearnedMemorySection(search: search)
                } else {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let state {
                    Section {
                        ForEach(state.entries(target).filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { entry in
                            Button { editing = Editing(original: entry, text: entry) } label: {
                                Text(MarkdownText.attributed(entry)).font(.callout).foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await remove(entry) } } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button { UIPasteboard.general.string = entry } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button(role: .destructive) { Task { await remove(entry) } } label: { Label("Forget", systemImage: "trash") }
                            }
                        }
                    } header: {
                        UsageMeter(used: state.used(target), limit: state.limit(target))
                    } footer: {
                        Text(target.footer)
                    }
                }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search memory")
            .overlay { if !learned && state == nil && errorMessage == nil { ProgressView() } }
            .refreshable { await load() }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .toolbar {
                ToolbarItem(placement: .principal) { ProfilePickerMenu(store: store) }
                ToolbarItem(placement: .topBarTrailing) {
                    if !learned {
                        Button { editing = Editing(original: nil, text: "") } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add memory")
                    }
                }
            }
            .sheet(item: $editing) { e in
                MemoryEditor(editing: e, target: target, saving: saving,
                             remaining: state.map { $0.limit(target) - $0.used(target) + (e.original?.count ?? 0) } ?? 0) { text in
                    await save(e, text: text)
                }
            }
            .task(id: store.selected) { state = nil; await load() }
            #if DEBUG
            .task { if UserDefaults.standard.string(forKey: "memory.section") == "learned" { learned = true } }
            #endif
        }
    }

    private func load() async {
        guard let c = app.companionClient else { return }
        do {
            if !store.loaded { try? await store.load(c) }
            state = try await c.memory(profile: store.selected)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    /// Returns an error message, or nil when saved.
    private func save(_ e: Editing, text: String) async -> String? {
        guard let c = app.companionClient else { return "Not connected" }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Write something first." }
        saving = true
        defer { saving = false }
        do {
            if let original = e.original {
                guard clean != original else { return nil }
                state = try await c.editMemory(op: "replace", target: target, content: clean, oldText: original, profile: store.selected)
            } else {
                state = try await c.editMemory(op: "add", target: target, content: clean, profile: store.selected)
            }
            Haptics.success()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func remove(_ entry: String) async {
        guard let c = app.companionClient else { return }
        do {
            state = try await c.editMemory(op: "remove", target: target, oldText: entry, profile: store.selected)
            Haptics.tap()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct UsageMeter: View {
    let used: Int
    let limit: Int

    var body: some View {
        let fraction = limit > 0 ? min(Double(used) / Double(limit), 1) : 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(Int(fraction * 100))% full").font(.caption.weight(.semibold))
                Spacer()
                Text("\(used.formatted()) / \(limit.formatted()) characters").font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            ProgressView(value: fraction).tint(fraction > 0.9 ? .orange : .secondary)
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }
}

private struct MemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let editing: MemoryView.Editing
    let target: MemoryTarget
    let saving: Bool
    let remaining: Int
    let onSave: (String) async -> String?
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    if let error { Text(error).foregroundStyle(.red) }
                    Spacer()
                    Text("\(text.count) / \(remaining)").monospacedDigit()
                        .foregroundStyle(text.count > remaining ? .red : .secondary)
                }
                .font(.caption)
            }
            .padding()
            .navigationTitle(editing.original == nil ? "New \(target == .memory ? "note" : "fact about you")" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") {
                            Task {
                                if let e = await onSave(text) { error = e } else { dismiss() }
                            }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear { text = editing.text; focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Usage & status

struct UsageView: View {
    @Environment(AppModel.self) private var app
    @State private var usage: UsageResponse?
    @State private var status: HermesStatus?
    @State private var days = 30
    @State private var errorMessage: String?
    @State private var limits = LimitsStore.shared

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                LimitsSection(snapshot: limits.snapshot, loading: limits.loading, failed: limits.failed)
                if let status { statusSection(status) }
                Section {
                    Picker("Period", selection: $days) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let usage { usageSections(usage) }
            }
            .overlay { if usage == nil && errorMessage == nil { ProgressView() } }
            .refreshable {
                async let l: Void = loadLimits(refresh: true)
                async let u: Void = load()
                _ = await (l, u)
            }
            .task { await loadLimits(refresh: false) }
            .navigationTitle("Usage")
            .menuButton()
            .task(id: days) { await load() }
        }
    }

    @ViewBuilder private func statusSection(_ s: HermesStatus) -> some View {
        Section("Agent server") {
            LabeledContent("Version") {
                Text([s.version, s.canUpdate == true ? "update available" : nil].compactMap { $0 }.joined(separator: " · "))
            }
            HStack {
                Text("Gateway")
                Spacer()
                StatusDot(ok: s.gatewayRunning == true)
                Text(s.gatewayRunning == true ? "Running" : (s.gatewayState ?? "Stopped").capitalized).foregroundStyle(.secondary)
            }
            ForEach(s.platforms.keys.sorted().filter { $0 != "api_server" }, id: \.self) { name in
                let p = s.platforms[name]!
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(UsageView.platformName(name))
                        Spacer()
                        StatusDot(ok: p.state == "connected" && p.needsAttention != true)
                        Text((p.state ?? "unknown").capitalized).foregroundStyle(.secondary)
                    }
                    if let e = p.errorMessage, !e.isEmpty {
                        Text(e).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder private func usageSections(_ u: UsageResponse) -> some View {
        Section {
            HStack(spacing: 0) {
                Stat(value: Self.money(u.totals?.cost ?? 0), label: "Spend")
                Stat(value: "\(u.totals?.totalSessions ?? 0)", label: "Chats")
                Stat(value: Self.compact(u.totals?.totalApiCalls ?? 0), label: "Model calls")
            }
            .padding(.vertical, 4)
            SpendChart(days: u.daily)
                .frame(height: 120)
                .padding(.vertical, 6)
        } footer: {
            Text("Estimated from token prices. Cache reads are counted at the cached rate.")
        }
        Section("By model") {
            ForEach(u.models.sorted { $0.cost > $1.cost }) { m in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.model ?? "unknown").lineLimit(1)
                        Text("\(m.sessions ?? 0) chats · \(Self.compact(m.tokens)) tokens")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Self.money(m.cost)).monospacedDigit()
                }
            }
        }
    }

    private func loadLimits(refresh: Bool) async {
        guard let c = app.companionClient else { return }
        await limits.load(c, refresh: refresh)
    }

    private func load() async {
        guard let c = app.companionClient else { return }
        do {
            async let st = c.status()
            async let us = c.usage(days: days)
            (status, usage) = try await (st, us)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    static func platformName(_ key: String) -> String {
        switch key {
        case "whatsapp": "WhatsApp"
        case "telegram": "Telegram"
        case "imessage": "iMessage"
        default: key.capitalized
        }
    }

    static func money(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(v >= 100 ? 0 : 2)))
    }

    static func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}

private struct StatusDot: View {
    let ok: Bool
    var body: some View { Circle().fill(ok ? .green : .orange).frame(width: 7, height: 7) }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Daily spend bars (no Charts dependency needed for this).
private struct SpendChart: View {
    let days: [UsageResponse.Day]

    var body: some View {
        let sorted = days.sorted { $0.day < $1.day }
        let peak = max(sorted.map(\.cost).max() ?? 0, 0.01)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: sorted.count > 40 ? 1 : 3) {
                ForEach(sorted) { d in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(d.cost > 0 ? 0.75 : 0.12))
                        .frame(height: max(2, geo.size.height * d.cost / peak))
                        .accessibilityLabel("\(d.day): \(UsageView.money(d.cost))")
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .overlay(alignment: .topLeading) {
            Text("Peak \(UsageView.money(peak)) / day").font(.caption2).foregroundStyle(.secondary)
        }
    }
}


// MARK: - Messaging access (who can talk to your bots)

struct MessagingAccessView: View {
    @Environment(AppModel.self) private var app
    @State private var store = ProfilesStore.shared
    @State private var state: PairingState?
    @State private var status: HermesStatus?
    @State private var errorMessage: String?
    @State private var busy: String?
    @State private var revoking: PairingState.Approved?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                if let status, !status.platforms.isEmpty {
                    Section("Connected") {
                        ForEach(status.platforms.keys.sorted().filter { $0 != "api_server" }, id: \.self) { name in
                            let p = status.platforms[name]!
                            HStack {
                                Image(systemName: MessagingAccessView.icon(name)).frame(width: 24)
                                Text(UsageView.platformName(name))
                                Spacer()
                                Circle().fill(p.state == "connected" && p.needsAttention != true ? Color.green : .orange)
                                    .frame(width: 7, height: 7)
                                Text((p.state ?? "unknown").capitalized).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let state {
                    Section {
                        if state.pending.isEmpty {
                            Text("No one is waiting.").foregroundStyle(.secondary)
                        }
                        ForEach(state.pending) { p in
                            HStack(spacing: 12) {
                                AgentAvatar(name: p.userName ?? "?", size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.userName?.isEmpty == false ? p.userName! : "Unknown").font(.body.weight(.medium))
                                    Text("\(UsageView.platformName(p.platform)) · \(MessagingAccessView.age(p.ageMinutes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busy == p.id {
                                    ProgressView()
                                } else {
                                    Button { Task { await approve(p) } } label: {
                                        Text("Approve").foregroundStyle(Color(.systemBackground))
                                    }
                                    .buttonStyle(.borderedProminent).tint(.primary).controlSize(.small)
                                        .disabled(p.requestId.isEmpty)
                                }
                            }
                        }
                    } header: {
                        Text("Waiting for approval")
                    } footer: {
                        Text("When someone new messages your bot, your agent asks before talking to them. Approve them here.")
                    }
                    Section("Allowed") {
                        if state.approved.isEmpty {
                            Text("Nobody yet.").foregroundStyle(.secondary)
                        }
                        ForEach(state.approved) { a in
                            HStack(spacing: 12) {
                                AgentAvatar(name: a.userName ?? "?", size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.userName?.isEmpty == false ? a.userName! : a.userId).font(.body)
                                    HStack(spacing: 4) {
                                        Text(UsageView.platformName(a.platform))
                                        if let t = a.approvedAt {
                                            Text("· since \(Date(timeIntervalSince1970: t), format: .dateTime.month().day().year())")
                                        }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if busy == a.id { ProgressView() }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { revoking = a } label: { Label("Remove", systemImage: "person.badge.minus") }
                            }
                        }
                    }
                }
            }
            .overlay { if state == nil && errorMessage == nil { ProgressView() } }
            .refreshable { await load() }
            .navigationTitle("Messaging")
            .navigationBarTitleDisplayMode(.inline)
            .menuButton()
            .toolbar { ToolbarItem(placement: .principal) { ProfilePickerMenu(store: store) } }
            .confirmationDialog("Remove \(revoking?.userName ?? "this person")?",
                                isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                                titleVisibility: .visible) {
                Button("Remove access", role: .destructive) {
                    if let a = revoking { Task { await revoke(a) } }
                    revoking = nil
                }
            } message: {
                Text("They'll need to be approved again before your agent replies to them.")
            }
            .task(id: store.selected) { await load() }
        }
    }

    static func icon(_ platform: String) -> String {
        switch platform {
        case "telegram": "paperplane"
        case "whatsapp": "phone.bubble"
        case "imessage": "message"
        case "slack": "number"
        case "discord": "gamecontroller"
        default: "bubble.left.and.bubble.right"
        }
    }

    static func age(_ minutes: Int?) -> String {
        guard let m = minutes else { return "just now" }
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        return "\(m / 60) h ago"
    }

    private func load() async {
        guard let c = app.companionClient else { return }
        do {
            if !store.loaded { try? await store.load(c) }
            async let p = c.pairing(profile: store.selected)
            async let s = c.status()
            state = try await p
            status = try? await s
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func approve(_ p: PairingState.Pending) async {
        guard let c = app.companionClient else { return }
        busy = p.id
        defer { busy = nil }
        do {
            try await c.approve(p, profile: store.selected)
            Haptics.success()
            await load()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ a: PairingState.Approved) async {
        guard let c = app.companionClient else { return }
        busy = a.id
        defer { busy = nil }
        do {
            try await c.revoke(a, profile: store.selected)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}
