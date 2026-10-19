import SwiftUI

/// Automations: every agent's scheduled jobs, with run history, run now,
/// pause/resume, edit, delete and new-from-template. Uses the companion relay
/// (all profiles); falls back to the gateway's job list if the relay is down.
struct AutomationsView: View {
    @Environment(AppModel.self) private var app
    @State private var store = ProfilesStore.shared
    @State private var jobs: [CronJob] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var busyID: String?
    @State private var toast: String?
    @State private var viaRelay = true
    @State private var showTemplates = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let errorMessage {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .font(.callout).foregroundStyle(.orange)
                }
                ForEach(groups, id: \.0) { owner, items in
                    Section {
                        ForEach(items) { job in
                            NavigationLink(value: job) { JobRow(job: job, busy: busyID == job.id) }
                                .swipeActions(edge: .trailing) {
                                    Button { Task { await act(job, .run) } } label: { Label("Run now", systemImage: "play.fill") }
                                        .tint(Color(.systemGray))
                                    Button { Task { await act(job, job.isPaused ? .resume : .pause) } } label: {
                                        Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play.circle" : "pause.circle")
                                    }
                                    .tint(job.isPaused ? .green : .orange)
                                }
                        }
                    } header: {
                        if groups.count > 1 { Text(store.title(owner)) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if jobs.isEmpty && !loading && errorMessage == nil {
                    ContentUnavailableView {
                        Label("No automations", systemImage: "clock.arrow.2.circlepath")
                    } description: {
                        Text("Start from a template, or ask Otto to schedule something.")
                    } actions: {
                        Button("Browse templates") { showTemplates = true }.buttonStyle(.bordered)
                    }
                } else if jobs.isEmpty && loading {
                    ProgressView()
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .refreshable { await load() }
            .navigationTitle("Automations")
            .menuButton()
            .toolbar {
                if viaRelay {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showTemplates = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New automation")
                    }
                }
            }
            .navigationDestination(for: CronJob.self) { job in
                JobDetailView(job: jobs.first { $0.id == job.id } ?? job, busy: busyID == job.id,
                              canManage: viaRelay,
                              onAction: { action in Task { await act(job, action) } },
                              onChanged: { Task { await load() } },
                              onDeleted: {
                                  jobs.removeAll { $0.id == job.id }
                                  if !path.isEmpty { path.removeLast() }
                                  show("Deleted")
                              })
            }
            .sheet(isPresented: $showTemplates) {
                TemplatesSheet { created in
                    show("Created \(created.displayName)")
                    Task { await load() }
                }
            }
            .task { await load() }
        }
    }

    /// Grouped by agent, the default agent first.
    private var groups: [(String, [CronJob])] {
        Dictionary(grouping: jobs) { $0.profile ?? "default" }
            .map { ($0.key, $0.value.sorted(by: Self.order)) }
            .sorted { ($0.0 == "default" ? "" : $0.0) < ($1.0 == "default" ? "" : $1.0) }
    }

    private static func order(_ a: CronJob, _ b: CronJob) -> Bool {
        if a.isPaused != b.isPaused { return !a.isPaused }
        return (a.nextRun ?? .distantFuture) < (b.nextRun ?? .distantFuture)
    }

    enum Action { case run, pause, resume }

    private func load() async {
        loading = true
        defer { loading = false }
        if let c = app.companionClient {
            do {
                if !store.loaded { try? await store.load(c) }
                jobs = try await c.automations()
                viaRelay = true
                errorMessage = nil
                return
            } catch {
                viaRelay = false
            }
        }
        guard let client = app.client else { return }
        do {
            jobs = try await client.jobs()
            errorMessage = nil
        } catch {
            errorMessage = AppModel.friendly(error)
        }
    }

    private func act(_ job: CronJob, _ action: Action) async {
        busyID = job.id
        defer { busyID = nil }
        do {
            if viaRelay, let c = app.companionClient {
                try await c.act(action == .run ? "run" : action == .pause ? "pause" : "resume", job: job)
            } else if let client = app.client {
                switch action {
                case .run: try await client.runJob(id: job.id)
                case .pause: try await client.pauseJob(id: job.id)
                case .resume: try await client.resumeJob(id: job.id)
                }
            }
            Haptics.success()
            show(action == .run ? "Started \(job.displayName)" : action == .pause ? "Paused" : "Resumed")
            await load()
        } catch {
            Haptics.error()
            errorMessage = AppModel.friendly(error)
        }
    }

    private func show(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

struct JobRow: View {
    let job: CronJob
    var busy = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.isPaused ? "pause.circle" : job.lastFailed ? "exclamationmark.circle" : "clock")
                .foregroundStyle(job.isPaused ? Color.secondary : job.lastFailed ? Color.red : Color.accentColor)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if let s = job.scheduleDisplay { Text(ScheduleText.friendly(s)) }
                    if job.isPaused {
                        Text("· Paused")
                    } else if let next = job.nextRun {
                        Text("· next \(next, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail: status, history, instructions, manage

struct JobDetailView: View {
    @Environment(AppModel.self) private var app
    let job: CronJob
    let busy: Bool
    var canManage = false
    let onAction: (AutomationsView.Action) -> Void
    var onChanged: () -> Void = {}
    var onDeleted: () -> Void = {}

    @State private var runs: [JobRun]?
    @State private var runsError: String?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var actionError: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Schedule", value: job.scheduleDisplay.map(ScheduleText.friendly) ?? "—")
                if let next = job.nextRun, !job.isPaused {
                    LabeledContent("Next run") { Text(next, format: .dateTime.weekday().month().day().hour().minute()) }
                }
                if let last = job.lastRun {
                    LabeledContent("Last run") {
                        HStack(spacing: 4) {
                            Text(last, format: .relative(presentation: .named))
                            if let s = job.lastStatus {
                                Image(systemName: job.lastFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(job.lastFailed ? .red : .green)
                                    .accessibilityLabel(s)
                            }
                        }
                    }
                }
                if let d = job.deliver { LabeledContent("Sends to", value: Delivery.label(d)) }
                if let p = job.profile, p != "default" { LabeledContent("Agent", value: ProfilesStore.shared.title(p)) }
                if let m = job.model, !m.isEmpty { LabeledContent("Model", value: m) }
                if job.isPaused, let r = job.pausedReason, !r.isEmpty { LabeledContent("Paused because", value: r) }
            }
            if let err = job.lastError, !err.isEmpty, job.lastFailed {
                Section("Last error") { Text(err).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let err = job.lastDeliveryError, !err.isEmpty {
                Section("Delivery problem") { Text(err).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Section {
                Button { onAction(.run) } label: { Label("Run now", systemImage: "play.fill") }
                Button { onAction(job.isPaused ? .resume : .pause) } label: {
                    Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play.circle" : "pause.circle")
                }
            }
            .disabled(busy)
            if canManage { historySection }
            if let prompt = job.prompt, !prompt.isEmpty {
                Section(job.noAgent == true ? "Description" : "Instructions") {
                    CollapsibleText(text: prompt, collapsedLines: 8)
                }
            }
            if let skills = job.skills, !skills.isEmpty {
                Section("Skills") { Text(skills.joined(separator: ", ")).font(.callout) }
            }
            if let script = job.script, !script.isEmpty {
                Section("Script") { Text(script).font(.caption.monospaced()) }
            }
            if let actionError {
                Section { Text(actionError).foregroundStyle(.red).font(.callout) }
            }
            if canManage {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete automation", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(job.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canManage, job.noAgent != true {
                Button("Edit") { editing = true }
            }
        }
        .navigationDestination(for: JobRun.self) { run in
            RunDetailView(job: job, run: run)
        }
        .sheet(isPresented: $editing) {
            JobEditor(job: job) { onChanged() }
        }
        .confirmationDialog("Delete \(job.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("It stops running and is removed from your agent server.")
        }
        .refreshable { await loadRuns() }
        .task(id: job.lastRunAt) { if canManage { await loadRuns() } }
    }

    @ViewBuilder private var historySection: some View {
        Section("History") {
            if let runs {
                if runs.isEmpty {
                    Text("Hasn't run yet.").foregroundStyle(.secondary)
                }
                ForEach(runs.prefix(15)) { run in
                    NavigationLink(value: run) { RunRow(run: run) }
                }
            } else if let runsError {
                Text(runsError).font(.callout).foregroundStyle(.orange)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    private func loadRuns() async {
        guard let c = app.companionClient else { return }
        do { runs = try await c.runs(job: job); runsError = nil }
        catch { runsError = AppModel.friendly(error) }
    }

    private func delete() async {
        guard let c = app.companionClient else { return }
        do {
            try await c.deleteJob(job)
            Haptics.success()
            onDeleted()
        } catch {
            Haptics.error()
            actionError = AppModel.friendly(error)
        }
    }
}

private struct RunRow: View {
    let run: JobRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.isActive == true ? "circle.dotted" : run.failed ? "xmark.circle.fill"
                  : run.silent ? "moon.zzz" : "checkmark.circle.fill")
                .foregroundStyle(run.isActive == true ? Color.secondary : run.failed ? .red : run.silent ? .secondary : .green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                if let d = run.started {
                    Text(d, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .font(.subheadline)
                }
                let s = run.summary
                if !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let d = run.duration, d >= 1 {
                Text(Duration.seconds(d), format: .units(allowed: [.minutes, .seconds], width: .narrow, maximumUnitCount: 1))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// What a run produced: the agent's reply (agent runs) or the saved output (scripts).
private struct RunDetailView: View {
    @Environment(AppModel.self) private var app
    let job: CronJob
    let run: JobRun
    @State private var text: String?
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if let d = run.started {
                        Text(d, format: .dateTime.weekday(.wide).month().day().hour().minute())
                    }
                    if let m = run.model { Text("· \(m)") }
                }
                .font(.footnote).foregroundStyle(.secondary)
                if let text {
                    if text.isEmpty {
                        Text(note ?? "No output.").foregroundStyle(.secondary)
                    } else if run.isScriptOutput, !text.hasPrefix("Status:") {
                        Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    } else {
                        MarkdownText(text: text)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(job.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let text, !text.isEmpty { ShareLink(item: text) { Image(systemName: "square.and.arrow.up") } }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            if run.isScriptOutput {
                guard let c = app.companionClient else { return }
                let out = try await c.runOutput(job: job, run: run)
                text = out.text
                note = out.note
            } else if let client = app.client {
                let messages = try await client.messages(sessionID: run.id)
                let reply = messages.last { $0.role == "assistant" && !($0.content ?? "").isEmpty }?.content ?? ""
                text = reply.trimmingCharacters(in: .whitespacesAndNewlines) == "[SILENT]" ? "" : reply
                if text?.isEmpty == true { note = "Nothing to report this time." }
            }
        } catch {
            text = ""
            note = AppModel.friendly(error)
        }
    }
}

// MARK: - Edit

private struct JobEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let job: CronJob
    let onSaved: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = ""
    @State private var deliver = ""
    @State private var targets: [DeliveryTarget] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name) }
                Section {
                    TextField("e.g. 0 8 * * 1-5 or every 2h", text: $schedule)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(SchedulePreset.all, id: \.1) { label, value in
                                Button(label) { schedule = value }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                } header: { Text("Schedule") } footer: {
                    Text(ScheduleText.friendly(schedule) == schedule ? "Cron (minute hour day month weekday) or \"every 30m\"." : ScheduleText.friendly(schedule))
                }
                Section("Send results to") {
                    Picker("Send to", selection: $deliver) {
                        ForEach(deliveryOptions, id: \.self) { Text(Delivery.label($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                Section("Instructions") {
                    TextEditor(text: $prompt).frame(minHeight: 180)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } } }
                }
            }
            .task {
                name = job.name ?? ""
                prompt = job.prompt ?? ""
                schedule = job.scheduleDisplay ?? ""
                deliver = job.deliver ?? "local"
                targets = (try? await app.companionClient?.deliveryTargets(profile: job.profile ?? "default")) ?? []
            }
        }
    }

    private var deliveryOptions: [String] {
        var ids = ["origin"] + targets.map(\.id)
        if !ids.contains(deliver) { ids.append(deliver) }
        return ids.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private func save() async {
        guard let c = app.companionClient else { return }
        var fields: [String: String] = [:]
        let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed(name) != (job.name ?? "") { fields["name"] = trimmed(name) }
        if trimmed(prompt) != trimmed(job.prompt ?? "") { fields["prompt"] = trimmed(prompt) }
        if trimmed(schedule) != (job.scheduleDisplay ?? "") { fields["schedule"] = trimmed(schedule) }
        if deliver != (job.deliver ?? "") { fields["deliver"] = deliver }
        guard !fields.isEmpty else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            try await c.updateJob(job, fields: fields)
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            Haptics.error()
            self.error = AppModel.friendly(error)
        }
    }
}

enum SchedulePreset {
    static let all: [(String, String)] = [
        ("Daily 8:00", "0 8 * * *"), ("Weekdays 9:00", "0 9 * * 1-5"), ("Mondays 9:00", "0 9 * * 1"),
        ("Every hour", "every 1h"), ("Every 30 min", "every 30m"),
    ]
}

// MARK: - New from template

private struct TemplatesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var store = ProfilesStore.shared
    @State private var blueprints: [Blueprint] = []
    @State private var error: String?
    let onCreated: (CronJob) -> Void

    private var grouped: [(String, [Blueprint])] {
        let order = ["daily", "weekly", "email", "general"]
        return Dictionary(grouping: blueprints) { $0.category ?? "general" }
            .map { ($0.key, $0.value) }
            .sorted { (order.firstIndex(of: $0.0) ?? 9) < (order.firstIndex(of: $1.0) ?? 9) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.orange) }
                ForEach(grouped, id: \.0) { category, items in
                    Section(category == "general" ? "More" : category.capitalized) {
                        ForEach(items) { b in
                            NavigationLink(value: b) {
                                HStack(spacing: 12) {
                                    Image(systemName: b.icon).font(.title3).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(b.title).font(.body.weight(.medium))
                                        if let d = b.description {
                                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .overlay { if blueprints.isEmpty && error == nil { ProgressView() } }
            .navigationTitle("New automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if store.profiles.count > 1 {
                    ToolbarItem(placement: .principal) { ProfilePickerMenu(store: store) }
                }
            }
            .navigationDestination(for: Blueprint.self) { b in
                BlueprintForm(blueprint: b, profile: store.selected) { job in
                    onCreated(job)
                    dismiss()
                }
            }
            .task(id: store.selected) {
                guard let c = app.companionClient else { return }
                do { blueprints = try await c.blueprints(profile: store.selected); error = nil }
                catch { self.error = AppModel.friendly(error) }
            }
        }
    }
}

private struct BlueprintForm: View {
    @Environment(AppModel.self) private var app
    let blueprint: Blueprint
    let profile: String
    let onCreated: (CronJob) -> Void
    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            if let d = blueprint.description {
                Section { Text(d).font(.callout).foregroundStyle(.secondary) }
            }
            ForEach(blueprint.fields, id: \.name) { f in
                Section {
                    field(f)
                } header: {
                    Text(f.label)
                } footer: {
                    if let h = f.help, !h.isEmpty, f.type != "time", f.name != "deliver" { Text(h) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        Spacer()
                        if saving { ProgressView() } else { Text("Create automation").bold() }
                        Spacer()
                    }
                }
                .disabled(saving)
            } footer: {
                if profile != "default" { Text("Runs as \(ProfilesStore.shared.title(profile)).") }
            }
        }
        .navigationTitle(blueprint.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard values.isEmpty else { return }
            for f in blueprint.fields {
                var v = f.default?.text ?? f.options?.first?.text ?? ""
                if f.name == "deliver", v == "origin" { v = "telegram" }  // phone has no chat "origin"
                values[f.name] = v
            }
        }
    }

    @ViewBuilder private func field(_ f: Blueprint.Field) -> some View {
        let binding = Binding(get: { values[f.name] ?? "" }, set: { values[f.name] = $0 })
        switch f.type {
        case "time":
            DatePicker("Time", selection: Binding(
                get: { BlueprintForm.date(from: values[f.name] ?? "08:00") },
                set: { values[f.name] = BlueprintForm.hhmm($0) }), displayedComponents: .hourAndMinute)
        case "enum", "weekdays":
            let options = (f.options ?? []).map(\.text)
            let picker = Picker(f.label, selection: binding) {
                ForEach(options, id: \.self) { o in
                    Text(f.name == "deliver" ? Delivery.label(o) : BlueprintForm.optionLabel(o, field: f.name)).tag(o)
                }
            }
            .labelsHidden()
            if options.count <= 3 { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
        default:
            TextField(f.label, text: binding, axis: .vertical).lineLimit(1...5)
        }
    }

    static func optionLabel(_ o: String, field: String) -> String {
        switch o {
        case "everyday": return "Every day"
        case "weekdays": return "Weekdays"
        case "weekends": return "Weekends"
        default: break
        }
        if field.hasSuffix("_min") { return "\(o) min" }
        if field.hasSuffix("_h") || field.hasSuffix("_hours") { return "\(o) h" }
        if field.hasSuffix("_hour") { return "\(o):00" }
        return o.replacingOccurrences(of: "-", with: " ").capitalized
    }

    static func date(from hhmm: String) -> Date {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 8, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0)
    }

    private func create() async {
        guard let c = app.companionClient else { return }
        saving = true
        defer { saving = false }
        do {
            let job = try await c.createFromBlueprint(blueprint.key, values: values, profile: profile)
            Haptics.success()
            onCreated(job)
        } catch {
            Haptics.error()
            self.error = AppModel.friendly(error)
        }
    }
}

/// Cron expressions → something readable. Falls back to the raw text.
enum ScheduleText {
    static func friendly(_ s: String) -> String {
        if s.hasPrefix("every ") {
            let rest = s.dropFirst(6)
            if rest.hasSuffix("m"), let n = Int(rest.dropLast()) { return n % 60 == 0 ? "Every \(n / 60)h" : "Every \(n) min" }
            if rest.hasSuffix("h"), let n = Int(rest.dropLast()) { return n == 1 ? "Every hour" : "Every \(n) hours" }
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        let parts = s.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return s }
        let (min, hour, dom, mon, dow) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        if hour == "*", min.hasPrefix("*/"), dom == "*", dow == "*", let n = Int(min.dropFirst(2)) { return "Every \(n) min" }
        guard let h = Int(hour), let m = Int(min), mon == "*" else { return s }
        let time = String(format: "%02d:%02d", h, m)
        if dom == "*" && dow == "*" { return "Daily at \(time)" }
        if dom == "*", let d = Int(dow), (0...7).contains(d) {
            let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
            return "\(names[d]) at \(time)"
        }
        if dom == "*" && dow == "1-5" { return "Weekdays at \(time)" }
        if dom == "*" && (dow == "0,6" || dow == "6,0") { return "Weekends at \(time)" }
        if dow == "*", let d = Int(dom) { return "Monthly on day \(d) at \(time)" }
        return s
    }
}
