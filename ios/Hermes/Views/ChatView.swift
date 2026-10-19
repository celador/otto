import PhotosUI
import SwiftUI

struct ChatView: View {
    @State var model: ChatModel
    let title: String
    var launch: LaunchAction? = nil
    @Environment(AppModel.self) private var app
    @State private var dictation = Dictation()
    @State private var showVoice = false
    /// This chat's claim on the headphone double press (idle: opens voice mode here).
    @State private var headphoneClaim = UUID()
    @State private var speaker = Speaker.shared
    @State private var draft = ""
    /// The last sent text, to catch it being written back into the box.
    @State private var lastSent: (text: String, at: Date)?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachments: [Data] = []
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showModelPicker = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var inputFocused = false
    @State private var confirmDelete = false
    @State private var finding = false
    @State private var findQuery = ""
    @State private var makingTask = false
    @State private var actionError: String?
    @State private var scrollTarget: String?
    @State private var showCommands = false
    @State private var commandsFilter = ""
    @State private var confirmSlash: String?
    /// Subagents/Background tray + whether this chat runs anywhere (shared by the status line).
    @State private var activity = ActivityStore()
    #if os(macOS)
    @State private var showFileImporter = false
    @State private var modelPopover = false
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// Fast Mode exists for this chat's model (Claude Opus 4.8/5/5.5, some OpenAI/xAI models).
    private var fastAvailable: Bool { app.modelOptions?.supportsFast(model.modelChoice) ?? false }

    private func emptyChatHeader<Actions: View>(@ViewBuilder actions: () -> Actions) -> some View {
        ContentUnavailableView {
            VStack(spacing: 10) {
                OttoMark(size: 64)
                Text("Ask Otto anything")
            }
        } description: {
            Text("It runs on your computer, with all its tools, memory and skills.")
        } actions: {
            actions()
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.isStale {
                        Label("Showing saved copy", systemImage: "icloud.slash")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    let dayStarts = model.dayStarts
                    #if os(macOS)
                    ForEach(MacTranscript.group(model.rows)) { entry in
                        switch entry {
                        case .row(let row): rowView(row, dayStart: dayStarts[row.id])
                        case .tools(let id, let tools): MacToolGroup(tools: tools).id(id)
                        }
                    }
                    #else
                    ForEach(model.rows) { row in rowView(row, dayStart: dayStarts[row.id]) }
                    #endif
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "hermes.showThinking") { TypingIndicator() }
                    #endif
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .frame(maxWidth: ChatLayout.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .overlay {
                if model.rows.isEmpty && !model.isLoading {
                    #if os(macOS)
                    // The starters sit below ContentUnavailableView, not in its `actions:` slot: that slot is
                    // capped at the description's narrow width, which wrapped the pills even in a wide column.
                    VStack(spacing: 0) {
                        emptyChatHeader { EmptyView() }
                            .fixedSize(horizontal: false, vertical: true)
                        StarterPrompts { prompt in
                            Haptics.send()
                            Task { await model.send(prompt) }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, -12) // match the actions slot's gap under the description
                        .frame(maxWidth: ChatLayout.readableWidth)
                    }
                    #else
                    emptyChatHeader {
                        StarterPrompts { prompt in
                            Haptics.send()
                            Task { await model.send(prompt) }
                        }
                    }
                    #endif
                }
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                scrollTarget = nil
            }
            .onChange(of: model.rows) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            #if os(macOS)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { macComposer }
            .scrollEdgeEffectHidden(true, for: .bottom)
            .scrollEdgeEffectStyle(.hard, for: .top)
            .font(.system(size: 14))
            .lineSpacing(2.5)
            #else
            .safeAreaInset(edge: .bottom) { composer }
            #endif
        }
        .navigationTitle(ChatTitle.short(model.title ?? title))
        .navigationBarTitleDisplayMode(.inline)
        .menuButton()
        .toolbar {
            #if os(iOS)
            // The Mac has New Chat in the sidebar toolbar and ⌘N.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    LaunchRequest.post(.newChat)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New chat")
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if model.sessionID != nil {
                        Section(ChatTitle.short(model.title ?? title)) {
                            ShareLink(item: model.transcript.shareText(title: model.title ?? title)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button { Task { await togglePin() } } label: {
                                Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
                            }
                            Button {
                                renameText = model.title ?? title
                                renaming = true
                            } label: { Label("Rename", systemImage: "pencil") }
                            Button { makingTask = true } label: {
                                Label("Make a task", systemImage: "rectangle.split.3x1")
                            }
                            if let sid = model.sessionID { MoveToWorkspaceMenu(sessionID: sid) }
                            Button { Task { await fork() } } label: {
                                Label("Fork chat", systemImage: "arrow.triangle.branch")
                            }
                            .disabled(model.isRunning)
                            Button { finding = true } label: {
                                Label("Find in chat", systemImage: "magnifyingglass")
                            }
                        }
                        Section {
                            Button { Task { await archive() } } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    } else {
                        Button { showModelPicker = true } label: {
                            Label("Model: \(model.modelChoice?.shortName ?? "Default")", systemImage: "cpu")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                #if os(macOS)
                .menuIndicator(.hidden)
                .help("Chat options")
                #endif
                .accessibilityLabel("Chat options")
            }
            #if os(macOS)
            .sharedBackgroundVisibility(.hidden)
            #endif
        }
        .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteChat() } }
        } message: {
            Text("It's removed from your agent server too.")
        }
        .sheet(isPresented: $finding) {
            FindInChatView(query: $findQuery, transcript: model.transcript) { id in
                finding = false
                scrollTarget = id
            }
        }
        .sheet(isPresented: $makingTask) {
            if let client = app.kanbanClient {
                MakeTaskView(client: client, chatTitle: model.title ?? title,
                             transcript: model.transcript, sessionID: model.sessionID)
            }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: { Text(actionError ?? "") }
        .task { await app.loadModelOptions() }
        .task { await app.loadSlashCommands() }
        .onChange(of: fastAvailable, initial: true) { _, on in model.fastAvailable = on }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(selection: Binding(get: { model.modelChoice }, set: { model.modelChoice = $0 }))
        }
        .sheet(isPresented: $showCommands) {
            SlashCommandsSheet(commands: app.slashCommands, filter: commandsFilter) { cmd in
                showCommands = false
                pick(cmd)
            }
        }
        .confirmationDialog(confirmSlash == "/update" ? "Update Hermes on your Mac?" : "Restart the Hermes gateway?",
                            isPresented: Binding(get: { confirmSlash != nil }, set: { if !$0 { confirmSlash = nil } }),
                            titleVisibility: .visible) {
            Button(confirmSlash == "/update" ? "Update" : "Restart", role: .destructive) {
                let cmd = confirmSlash ?? "/restart"
                confirmSlash = nil
                Task { await runOnMac(cmd) }
            }
        } message: {
            Text("Chats in progress stop, and the app reconnects when Hermes is back.")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let jpeg = ImageEncoder.jpeg(from: image) { attachments.append(jpeg) }
            }
            .ignoresSafeArea()
        }
        #endif
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Save") { Task { await model.rename(to: renameText); await app.refresh() } }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: max(1, 4 - attachments.count), matching: .images,
                      preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var failed = 0
                for item in items where attachments.count < 4 {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = ImageEncoder.jpeg(from: data) {
                        attachments.append(jpeg)
                    } else {
                        failed += 1
                    }
                }
                photoItems = []
                if failed > 0 {
                    actionError = failed == 1 ? "That photo couldn't be loaded. If it's in iCloud, open it in Photos first, then try again."
                        : "\(failed) photos couldn't be loaded. If they're in iCloud, open them in Photos first, then try again."
                } else {
                    Haptics.tap()
                }
            }
        }
        .task {
            dictation.onText = { draft = $0 }
            dictation.companion = app.companionClient
            dictation.onRefined = { expected, refined in if draft == expected { draft = refined } }
            #if DEBUG
            if let d = UserDefaults.standard.string(forKey: "hermes.autoDraft") { draft = d }
            if UserDefaults.standard.bool(forKey: "hermes.openPhotos") { showPhotos = true }
            #if os(iOS)
            if UserDefaults.standard.bool(forKey: "hermes.autoPaste") {
                // Same-app clipboard content doesn't trigger the paste prompt.
                let size = CGSize(width: 400, height: 300)
                UIPasteboard.general.image = UIGraphicsImageRenderer(size: size).image { ctx in
                    UIColor.systemTeal.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                NotificationCenter.default.post(name: PastingTextView.debugPasteNotification, object: nil)
            }
            #endif
            #endif
            if draft.isEmpty, launch == nil { draft = DraftStore.get(sessionID: model.sessionID) }
            await model.load()
            await handleLaunch()
            #if DEBUG
            if let slash = UserDefaults.standard.string(forKey: "hermes.autoSlash") {
                for cmd in slash.components(separatedBy: " ; ") { runSlash(cmd); try? await Task.sleep(nanoseconds: 2_500_000_000) }
            }
            if model.items.isEmpty, UserDefaults.standard.string(forKey: "hermes.newChatIn") == nil || model.workspaceID != nil,
               let prompt = DebugLaunch.consumeAutoSend() {
                let images = DebugLaunch.autoImage.flatMap { ImageEncoder.jpeg(from: $0) }.map { [$0] } ?? []
                await model.send(OutgoingMessage(text: prompt, images: images))
                if let steer = DebugLaunch.autoSteer {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await model.send(steer)
                }
            }
            #endif
        }
        .onAppear {
            RunWatcher.shared.visibleSessionID = model.sessionID
            HeadphoneVoiceStart.claim(headphoneClaim) { showVoice = true }
            #if DEBUG
            // Screenshots: `-hermes.voicePreview speaking` opens voice mode straight away.
            if UserDefaults.standard.string(forKey: "hermes.voicePreview") != nil
                || UserDefaults.standard.string(forKey: "hermes.voiceSelfTest") != nil { showVoice = true }
            #endif
        }
        .onChange(of: model.sessionID) { RunWatcher.shared.visibleSessionID = model.sessionID }
        .onChange(of: draft) { _, text in
            if ComposerEcho.isEcho(text, sent: lastSent?.text, sentAt: lastSent?.at) {
                draft = ""
                return
            }
            DraftStore.set(text, sessionID: model.sessionID)
        }
        .onChange(of: model.sessionID) { old, new in
            // A new chat just got its id: move the draft to it.
            if old == nil, new != nil { DraftStore.set("", sessionID: nil); DraftStore.set(draft, sessionID: new) }
        }
        .onChange(of: model.isRunning) { was, now in
            if was && !now { Haptics.success() }
        }
        // A turn started elsewhere (desktop, Telegram, cron, another device): follow it by re-reading
        // the stored transcript every few seconds, and once more when it ends.
        .task(id: activity.remoteRunning && !model.isRunning) {
            guard activity.remoteRunning, !model.isRunning else { return }
            while !Task.isCancelled {
                await model.load(remoteRun: true)
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled || model.isRunning { break }
            }
        }
        .onChange(of: activity.remoteRunning) { was, now in
            if was && !now && !model.isRunning { Task { await model.load() } }
        }
        .animation(.snappy(duration: 0.2), value: ChatRunStatus.of(model, activity) == nil)
        .alert("Dictation", isPresented: Binding(get: { dictation.errorMessage != nil },
                                                 set: { if !$0 { dictation.errorMessage = nil } })) {
            Button("OK") { dictation.errorMessage = nil }
        } message: {
            Text(dictation.errorMessage ?? "")
        }
        .onAppear { Speaker.shared.companion = app.companionClient }
        .fullScreenCover(isPresented: $showVoice) {
            VoiceModeView(session: makeVoiceSession(), title: model.title ?? title)
        }
        // Stop on the voice Live Activity (Lock Screen / Dynamic Island).
        .onReceive(NotificationCenter.default.publisher(for: HandsFreeHooks.stopNotification)) { _ in showVoice = false }
        .onDisappear {
            HeadphoneVoiceStart.release(headphoneClaim)
            dictation.stop()
            speaker.stop()
            model.detach()
            if RunWatcher.shared.visibleSessionID == model.sessionID { RunWatcher.shared.visibleSessionID = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resume()
                if draft.isEmpty { draft = DraftStore.get(sessionID: model.sessionID) }
            } else if phase != .active {
                if dictation.isRecording { dictation.stop() }
                DraftStore.set(draft, sessionID: model.sessionID)
                // Voice mode keeps going with the screen locked: keep following the reply.
                if phase == .background && !showVoice { model.detach() }
            }
        }
        .alert("Error", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        #if os(macOS)
        .modifier(MacChatChrome(model: model, showModelPicker: $showModelPicker, showCommands: $showCommands,
                                commandsFilter: $commandsFilter, inputFocused: $inputFocused, showVoice: $showVoice,
                                showFileImporter: $showFileImporter, finding: $finding,
                                onImages: { addPasted($0) }))
        #endif
    }

    /// `dayStart`: this row opens a new day, so a day separator goes above it.
    @ViewBuilder private func rowView(_ row: ChatRow, dayStart: Date?) -> some View {
                switch row {
                case .item(let item):
                    VStack(spacing: 12) {
                        if let dayStart { DaySeparator(date: dayStart) }
                        ChatItemView(item: item, date: model.date(for: item.id),
                                     showActions: turnEndIDs.contains(item.id),
                                 onRetry: { id in Task { await model.retry(id) } },
                                 onDiscard: { id in model.discard(id) },
                                 isLastNotice: item.id == model.items.last?.id && !model.isRunning,
                                 onRetryTurn: { Task { await model.retryLastTurn() } }) { approval, choice in
                            Task { await model.answer(approval, choice: choice) }
                        }
                    }
                    .id(row.id)
                case .command(let entry):
                    SlashEntryView(entry: entry, onOpen: { id in
                        NotificationCenter.default.post(name: NotificationRouter.openSession, object: nil,
                                                        userInfo: ["sessionID": id])
                    }, onRemove: { withAnimation { model.removeNote(entry.id) } },
                       onClearAll: { withAnimation { model.clearSlashLog() } })
                    .id(row.id)
                }
    }

    private var session: SessionSummary? {
        model.sessionID.flatMap { id in app.sessions.first { $0.id == id } }
    }
    private var isPinned: Bool { session?.isPinned ?? false }

    private func togglePin() async {
        guard let s = session else { return }
        await app.setPinned(s, !s.isPinned)
        Haptics.tap()
    }

    private func archive() async {
        guard let s = session else { return }
        await app.setArchived(s, true)
        Haptics.success()
        NotificationCenter.default.post(name: ChatNav.closeChat, object: nil)
    }

    private func deleteChat() async {
        guard let s = session else { return }
        await app.delete(s)
        Haptics.success()
        NotificationCenter.default.post(name: ChatNav.closeChat, object: nil)
    }

    private func fork() async {
        guard let id = model.sessionID, let client = app.client else { return }
        do {
            let forked = try await client.forkSession(id: id)
            app.noteCreated(forked)
            Haptics.success()
            NotificationCenter.default.post(name: NotificationRouter.openSession, object: nil,
                                            userInfo: ["sessionID": forked.id])
        } catch {
            actionError = AppModel.friendly(error)
        }
    }

    /// The last finished assistant message of each turn gets Copy / Read aloud / Share.
    private var turnEndIDs: Set<String> {
        var ids = Set<String>()
        var lastAssistant: String?
        for item in model.items {
            switch item {
            case .user:
                if let id = lastAssistant { ids.insert(id) }
                lastAssistant = nil
            case .assistant(let id, _, let streaming):
                lastAssistant = streaming ? nil : id
            default: break
            }
        }
        if let id = lastAssistant, !model.isRunning { ids.insert(id) }
        return ids
    }

    private func handleLaunch() async {
        guard let launch, model.sessionID == nil, model.items.isEmpty else { return }
        switch launch {
        case .newChat: inputFocused = true
        case .dictate: await dictation.start(current: draft)
        case .voice: showVoice = true
        case .camera:
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true } else { inputFocused = true }
            #else
            inputFocused = true
            #endif
        case .ask(let prompt): await model.send(prompt)
        }
    }

    private func addPasted(_ jpegs: [Data]) {
        let room = max(0, 4 - attachments.count)
        guard room > 0, !jpegs.isEmpty else { return }
        attachments.append(contentsOf: jpegs.prefix(room))
        Haptics.tap()
    }

    private func sendDraft() {
        if attachments.isEmpty, SlashCommands.isCommand(draft, catalog: app.slashCommands) {
            runSlash(draft)
            return
        }
        dictation.stop()
        let message = OutgoingMessage(text: draft, images: model.isRunning ? [] : attachments)
        lastSent = (draft.trimmed, .now)
        draft = ""
        DraftStore.set("", sessionID: model.sessionID)
        if !model.isRunning { attachments = [] }
        Haptics.send()
        Task { await model.send(message) }
    }

    // MARK: Slash commands

    /// A row tapped in the suggestions/commands list: required arguments → type them; otherwise run it.
    private func pick(_ cmd: SlashCommand) {
        Haptics.tap()
        if cmd.args.hasPrefix("<") {
            draft = "/\(cmd.name) "
            inputFocused = true
        } else {
            runSlash("/\(cmd.name)")
        }
    }

    private func runSlash(_ text: String) {
        guard let (name, arg) = SlashCommands.parse(text) else { return }
        let command = text.trimmed
        dictation.stop()
        lastSent = (command, .now)
        draft = ""
        DraftStore.set("", sessionID: model.sessionID)
        Haptics.send()
        Task { await handleSlash(command, name: name, arg: arg) }
    }

    private static let busyBlocked: Set<String> = ["compress", "compact", "undo", "retry", "rollback"]

    private func handleSlash(_ command: String, name: String, arg: String) async {
        guard let action = SlashCommands.local(name, arg) else {
            if model.isRunning, Self.busyBlocked.contains(name) {
                model.note(command, "Wait for the current reply to finish, then try again.", isError: true)
                return
            }
            await runOnMac(command)
            return
        }
        switch action {
        case .newChat(let title):
            ChatModel.pendingNewTitle = title
            LaunchRequest.post(.newChat)
        case .stop:
            if model.isRunning {
                await model.stop()
                model.note(command, "Stopped.")
            } else {
                model.note(command, "Nothing is running in this chat.")
            }
        case .steer(let text):
            guard !text.isEmpty else { return model.note(command, "Usage: /steer <text>. It's added to the turn that's running.") }
            if !model.isRunning { model.note(command, "Nothing is running, so it went out as a new message.") }
            await model.send(text)
        case .queue(let text):
            guard !text.isEmpty else {
                model.note(command, model.queued.isEmpty ? "Nothing queued. Usage: /queue <message>."
                           : "Queued:\n" + model.queued.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                return
            }
            if model.isRunning { model.note(command, "Queued. It's sent when this reply finishes.") }
            await model.enqueue(text)
        case .background(let prompt):
            guard !prompt.isEmpty else { return model.note(command, "Usage: /bg <prompt>. It runs in its own chat while you keep going here.") }
            do {
                let s = try await model.startBackground(prompt)
                app.noteCreated(s)
                model.note(command, "Running in the background in its own chat. You'll get a notification when it's done.",
                           openSessionID: s.id)
            } catch {
                model.note(command, AppModel.friendly(error), isError: true)
            }
        case .model(let query):
            guard let query else { showModelPicker = true; return }
            if let choice = matchModel(query) {
                model.modelChoice = choice
                model.note(command, "This chat now uses \(choice.shortName).")
            } else {
                model.note(command, "No model matches “\(query)”. Pick one from the list.", isError: true)
                showModelPicker = true
            }
        case .fast(let a):
            let modelName = model.modelChoice?.shortName ?? app.modelOptions?.model ?? "this model"
            guard fastAvailable else { return model.note(command, "Fast mode isn't available for \(modelName).") }
            switch a?.lowercased() {
            case "status": break
            case "on", "fast", "auto", "ultrafast": model.fastMode = true
            case "off", "normal", "cold": model.fastMode = false
            default: model.fastMode = !(model.fastMode ?? false)
            }
            model.note(command, "Fast mode is \(model.fastMode == true ? "on" : "off") for this chat (\(modelName)).")
        case .voice(let a):
            switch a?.lowercased() {
            case "status", "off", "disable":
                model.note(command, "Voice mode opens full screen from the waveform button or /voice; it's off until then.")
            default:
                showVoice = true
            }
        case .approve(let scope):
            guard let pending = model.transcript.pendingApproval else { return model.note(command, "Nothing is waiting for approval.") }
            let wanted = ["session": "session", "always": "always"][scope?.lowercased() ?? ""] ?? "once"
            let choice = pending.choices.contains(wanted) ? wanted : (pending.choices.first { $0 != "deny" } ?? "once")
            await model.answer(pending, choice: choice)
            model.note(command, "Approved (\(choice)).")
        case .deny:
            guard let pending = model.transcript.pendingApproval else { return model.note(command, "Nothing is waiting for approval.") }
            await model.answer(pending, choice: "deny")
            model.note(command, "Denied.")
        case .help(let filter):
            commandsFilter = filter == "skills" ? "" : (filter ?? "")
            showCommands = true
        case .title(let t):
            guard model.sessionID != nil else { return model.note(command, "Send a message first; then this chat can be renamed.") }
            guard let t else { return model.note(command, "Title: \(model.title ?? title)") }
            await model.rename(to: t)
            await app.refresh()
            model.note(command, "Renamed to “\(t)”.")
        case .resume(let q):
            let recent = app.visibleSessions.filter { $0.id != model.sessionID }
            guard let q else {
                let list = recent.prefix(8).map { "• \($0.displayTitle)" }.joined(separator: "\n")
                return model.note(command, "Recent chats:\n\(list)\n\nUse /resume <title> to open one.")
            }
            let needle = q.lowercased()
            if let s = recent.first(where: { $0.id == q || $0.displayTitle.lowercased() == needle })
                ?? recent.first(where: { $0.displayTitle.lowercased().contains(needle) }) {
                NotificationCenter.default.post(name: NotificationRouter.openSession, object: nil, userInfo: ["sessionID": s.id])
            } else {
                model.note(command, "No chat matches “\(q)”.", isError: true)
            }
        case .branch(let name):
            guard let id = model.sessionID, let client = app.client else { return model.note(command, "Send a message first; there's nothing to branch yet.") }
            guard !model.isRunning else { return model.note(command, "Wait for the current reply to finish, then branch.", isError: true) }
            do {
                let forked = try await client.forkSession(id: id)
                app.noteCreated(forked)
                if let name { await app.rename(forked, to: name) }
                model.note(command, "Branched into “\(name ?? forked.displayTitle)”.", openSessionID: forked.id)
                NotificationCenter.default.post(name: NotificationRouter.openSession, object: nil, userInfo: ["sessionID": forked.id])
            } catch {
                model.note(command, AppModel.friendly(error), isError: true)
            }
        case .moa(let prompt):
            guard !prompt.isEmpty else { return model.note(command, "Usage: /moa <prompt>.") }
            guard let moa = app.modelOptions?.providers.first(where: { $0.slug == "moa" || $0.name.localizedCaseInsensitiveContains("Mixture of Agents") }) else {
                return model.note(command, "Mixture of Agents isn't set up on your Hermes.")
            }
            model.note(command, "One turn with Mixture of Agents, then back to this chat's model.")
            await model.send(prompt, oneShot: ModelChoice(provider: moa.slug, model: moa.models?.first ?? "default"))
        case .confirm(let name):
            confirmSlash = "/" + name
        case .unavailable(let text):
            model.note(command, text)
        }
    }

    private func runOnMac(_ command: String) async {
        guard let companion = app.companionClient else {
            model.note(command, "Slash commands need the relay on your Mac. Check Settings → Relay.", isError: true)
            return
        }
        if let prefill = await model.runOnMac(command, companion: companion) {
            draft = prefill
            inputFocused = true
        }
        if let name = SlashCommands.parse(command)?.name, ["title", "compress", "compact", "branch", "undo"].contains(name) {
            await app.refresh()
        }
    }

    private func makeVoiceSession() -> VoiceSession {
        let session = VoiceSession(chat: model, companion: app.companionClient, title: model.title ?? title)
        session.onCommand = { command in await voiceCommand(command) }
        return session
    }

    /// Slash commands said out loud in voice mode ("switch your model to haiku", "new chat").
    private func voiceCommand(_ command: String) async -> VoiceCommandResult {
        guard let (name, arg) = SlashCommands.parse(command) else { return .init(reply: "Sorry, I didn't catch that.") }
        switch SlashCommands.local(name, arg) {
        case .model(let query?):
            if app.modelOptions == nil { await app.loadModelOptions() }
            // Spoken "4.5" → the catalog's "4-5".
            let spokenQuery = query.replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1-$2", options: .regularExpression)
            if let choice = matchModel(spokenQuery) ?? matchModel(query) {
                model.modelChoice = choice
                model.note(command, "This chat now uses \(choice.shortName).")
                return .init(reply: "Okay, I'm on \(VoiceLogic.spokenModelName(choice.model)) now.")
            }
            model.note(command, "No model matches “\(query)”.", isError: true)
            return .init(reply: "I couldn't find a model called \(query). The model is unchanged.")
        case .newChat:
            return .init(reply: "Starting a new chat.") {
                showVoice = false
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    LaunchRequest.post(.voice)
                }
            }
        default:
            return .init(reply: "I can't do that from voice mode.")
        }
    }

    /// `/model sonnet` → the newest matching model this Hermes offers.
    private func matchModel(_ query: String) -> ModelChoice? {
        guard let options = app.modelOptions else { return nil }
        let q = query.lowercased().replacingOccurrences(of: " ", with: "-")
        let all = options.providers.flatMap { p in
            (p.models ?? []).map { ModelChoice(provider: p.slug, model: $0) }
        }
        let current = model.modelChoice?.provider ?? options.provider
        func rank(_ c: ModelChoice) -> Int { c.provider == current ? 0 : 1 }
        if let exact = all.filter({ $0.model.lowercased() == q || $0.shortName.lowercased() == q }).min(by: { rank($0) < rank($1) }) {
            return exact
        }
        // Newest first within the chat's provider ("sonnet" → claude-sonnet-5-5, not 4-6).
        return all.filter { $0.model.lowercased().contains(q) }.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.model.compare(b.model, options: .numeric) == .orderedDescending
        }.first
    }

    private var canSend: Bool {
        if model.isRunning { return !draft.trimmed.isEmpty }
        return !draft.trimmed.isEmpty || !attachments.isEmpty
    }

    /// "Yes, deploy it" when the agent's last message ends by offering something; nil otherwise.
    private var replySuggestion: String? {
        guard draft.isEmpty, attachments.isEmpty, !model.isRunning, !dictation.isRecording,
              case .assistant(_, let text, false)? = model.items.last else { return nil }
        return ReplySuggester.suggest(after: text)
    }

    private var slashSuggestions: [SlashCommand] {
        SlashCommands.suggestions(for: draft, catalog: app.slashCommands)
    }

    /// "Thinking… / Running a command / Writing…" + elapsed + Stop, while the chat runs anywhere.
    @ViewBuilder var statusLine: some View {
        if let status = ChatRunStatus.of(model, activity) {
            RunStatusLine(status: status) { stopRun() }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    func stopRun() {
        if model.isRunning { Task { await model.stop() }; return }
        guard let sid = model.sessionID, let client = app.companionClient else { return }
        Task {
            do { try await client.stopRemoteRun(sessionID: sid) } catch { actionError = AppModel.friendly(error) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceChip(sessionID: model.sessionID, pendingWorkspaceID: model.workspaceID) { model.workspaceID = $0 }
            statusLine
            ActivityTray(sessionID: model.sessionID, isRunning: model.isRunning, store: activity)
            if !slashSuggestions.isEmpty {
                SlashSuggestionList(commands: slashSuggestions) { pick($0) }
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, data in
                            AttachmentThumb(data: data) { attachments.remove(at: index) }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ComposerTextView(
                    text: $draft, isFocused: $inputFocused,
                    placeholder: dictation.isRecording ? "Listening…" : model.isRunning ? "Add to this turn…" : "Message Otto",
                    suggestion: replySuggestion,
                    acceptsImages: !model.isRunning && attachments.count < 4,
                    onSubmit: { if canSend { sendDraft() } }
                ) { images in
                    addPasted(images.compactMap { ImageEncoder.jpeg(from: $0) })
                }
                .padding(.horizontal, 10)
                HStack(spacing: 2) {
                    Menu {
                        #if os(iOS)
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                        #else
                        Button { showFileImporter = true } label: { Label("Choose Images…", systemImage: "folder") }
                        #endif
                        // A PhotosPicker placed inside a Menu is torn down when the menu
                        // closes, so the library never opens. Present it from the screen.
                        Button { showPhotos = true } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 19))
                            .foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .disabled(model.isRunning)
                    .accessibilityLabel("Attach")
                    Button {
                        Haptics.tap()
                        if draft.isEmpty {
                            draft = "/"
                            inputFocused = true
                        } else {
                            commandsFilter = ""
                            showCommands = true
                        }
                    } label: {
                        Text("/")
                            .font(.system(size: 21, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 38)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Commands")
                    Spacer(minLength: 4)
                    if fastAvailable {
                        Button {
                            Haptics.tap()
                            model.fastMode = !(model.fastMode ?? false)
                        } label: {
                            Image(systemName: model.fastMode == true ? "bolt.fill" : "bolt")
                                .font(.system(size: 17))
                                .foregroundStyle(model.fastMode == true ? Color.yellow : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 34, height: 38)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(model.fastMode == true ? "Fast mode on" : "Fast mode off")
                        .accessibilityHint("Faster replies from \(model.modelChoice?.shortName ?? app.modelOptions?.model ?? "this model"), at a higher price")
                    }
                    Button { showModelPicker = true } label: {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 38)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Model: \(model.modelChoice?.shortName ?? "Default")")
                    Button {
                        Haptics.tap()
                        Task { await dictation.toggle(current: draft) }
                    } label: {
                        Image(systemName: dictation.isRecording ? "waveform" : "mic")
                            .font(.system(size: 18))
                            .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                            .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                            .scaleEffect(dictation.isRecording ? 1 + CGFloat(dictation.level) * 0.25 : 1)
                            .animation(.easeOut(duration: 0.1), value: dictation.level)
                            .frame(width: 36, height: 38)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                    if !model.isRunning && draft.trimmed.isEmpty && attachments.isEmpty {
                        Button {
                            dictation.stop()
                            Haptics.tap()
                            showVoice = true
                        } label: {
                            RoundButtonFace(systemName: "waveform", enabled: true, iconSize: 15)
                        }
                        .accessibilityLabel("Voice mode")
                    } else if model.isRunning && draft.trimmed.isEmpty {
                        Button {
                            Task { await model.stop() }
                        } label: {
                            RoundButtonFace(systemName: "stop.fill", enabled: true, iconSize: 12)
                        }
                        .accessibilityLabel("Stop")
                    } else {
                        Button {
                            sendDraft()
                        } label: {
                            RoundButtonFace(systemName: "arrow.up", enabled: canSend)
                        }
                        .disabled(!canSend)
                        .accessibilityLabel("Send")
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .bareControls()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .stroke(dictation.isRecording ? Color.red.opacity(0.5) : Color(.separator).opacity(0.5),
                            lineWidth: dictation.isRecording ? 1.5 : 0.5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: ChatLayout.readableWidth)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            // Fade the conversation out under the floating message bar, like ChatGPT.
            LinearGradient(stops: [.init(color: Color(.systemBackground).opacity(0), location: 0),
                                   .init(color: Color(.systemBackground), location: 0.35)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// White (dark mode) / black (light mode) circle with the icon cut out, like ChatGPT's send.
struct RoundButtonFace: View {
    let systemName: String
    let enabled: Bool
    var iconSize: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(enabled ? Color(.systemBackground) : Color(.tertiaryLabel))
            .frame(width: 34, height: 34)
            .background(enabled ? Color.primary : Color(.systemGray5), in: Circle())
            .frame(width: 38, height: 38)
    }
}

struct AttachmentThumb: View {
    let data: Data
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove photo")
        }
        .padding(.top, 6)
    }
}

struct ChatItemView: View {
    let item: ChatItem
    /// When the message came through; nil shows no time.
    var date: Date? = nil
    var showActions = false
    var onRetry: (String) -> Void = { _ in }
    var onDiscard: (String) -> Void = { _ in }
    var isLastNotice = false
    var onRetryTurn: (() -> Void)? = nil
    let onApproval: (ApprovalRequest, String) -> Void

    var body: some View {
        switch item {
        case .user(let message):
            UserBubble(message: message, date: date, onRetry: { onRetry(message.id) }, onDiscard: { onDiscard(message.id) })
        case .assistant(let id, let text, let streaming):
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { Speaker.shared.toggle(id: id, text: text) } label: {
                            Label("Read aloud", systemImage: "speaker.wave.2")
                        }
                        ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                // The time appears once the reply has finished, so streaming text never moves.
                if showActions {
                    HStack(spacing: 14) {
                        MessageActions(id: id, text: text)
                        if let date { MessageTime(date: date) }
                    }
                } else if !streaming, let date {
                    MessageTime(date: date)
                }
            }
        case .tool(let tool):
            ToolRow(tool: tool)
        case .approval(let approval):
            ApprovalCard(approval: approval, onChoice: { onApproval(approval, $0) })
        case .notice(_, let text, let isError):
            NoticeRow(text: text, isError: isError, onRetry: isLastNotice && isError ? onRetryTurn : nil)
        }
    }
}

/// When a message came through ("2:14 PM"), under it in small secondary type.
struct MessageTime: View {
    let date: Date

    var body: some View {
        Text(ChatTimeline.timeLabel(date))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

/// "Today" / "Yesterday" / "Tuesday" / "Oct 12", centred where the day changes.
struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(ChatTimeline.dayLabel(date))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A small status line in the conversation (interrupted, failed, stopped).
struct NoticeRow: View {
    let text: String
    let isError: Bool
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle" : "info.circle")
            Text(text)
            if let onRetry {
                Button("Try again", action: onRetry)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground).opacity(0.7), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct UserBubble: View {
    #if os(macOS)
    static let alignment: HorizontalAlignment = .leading
    #else
    static let alignment: HorizontalAlignment = .trailing
    #endif
    let message: UserMessage
    var date: Date? = nil
    var onRetry: () -> Void = {}
    var onDiscard: () -> Void = {}

    var body: some View {
        HStack {
            #if os(iOS)
            Spacer(minLength: 48)
            #endif
            VStack(alignment: UserBubble.alignment, spacing: 6) {
                if message.isSteer {
                    Label("Added mid-turn", systemImage: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !message.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: message.images.count == 1 ? 200 : 96,
                                           height: message.images.count == 1 ? 200 : 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                } else if message.placeholderImages > 0 {
                    Label(message.placeholderImages == 1 ? "Photo" : "\(message.placeholderImages) photos",
                          systemImage: "photo")
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                if !message.text.isEmpty {
                    #if os(macOS)
                    // Hermes desktop style: the prompt as a full-width card with a hairline border.
                    Text(message.text)
                        .font(.system(size: 14.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MacPalette.border, lineWidth: 1))
                        .opacity(message.isSteer ? 0.75 : 1)
                        .contextMenu {
                            Button { UIPasteboard.general.string = message.text } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    #else
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground).opacity(message.isSteer ? 0.6 : 1),
                                    in: RoundedRectangle(cornerRadius: 18))
                        .contextMenu {
                            Button { UIPasteboard.general.string = message.text } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    #endif
                }
                switch message.delivery {
                case .sent:
                    if let date { MessageTime(date: date) }
                case .sending:
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                case .failed(let reason):
                    DeliveryFailedRow(reason: reason, onRetry: onRetry, onDiscard: onDiscard)
                }
            }
            .opacity(message.delivery == .sending ? 0.6 : 1)
        }
    }
}

/// Under a message the gateway never got: say so, and offer Retry / Delete.
struct DeliveryFailedRow: View {
    let reason: String
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 14) {
                Label("Not delivered", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Button("Retry", action: onRetry).fontWeight(.semibold)
                Button("Delete", role: .destructive, action: onDiscard).foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .buttonStyle(.borderless)
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .heading(let level, let title):
                    Text(Self.attributed(title))
                        .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, 4)
                case .table(let header, let rows):
                    TableBlock(header: header, rows: rows)
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .textSelection(.enabled)
                case .bullet(let marker, let body, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                        Text(Self.attributed(body)).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                }
            }
        }
    }

    static func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        for run in out.runs where run.link != nil {
            out[run.range].underlineStyle = .single
        }
        return out
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownText.attributed(cell)).font(.footnote.bold())
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { i in
                            Text(MarkdownText.attributed(i < row.count ? row[i] : ""))
                                .font(.footnote)
                                .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Block-level markdown the chat renders natively: fenced code, ATX headings,
/// pipe tables. Everything else is prose with inline markdown.
enum MarkdownBlock: Equatable {
    case prose(String), code(String), heading(Int, String), table([String], [[String]])
    case bullet(String, String, Int)
}

enum MarkdownBlocks {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var prose: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmed
            if !joined.isEmpty { result.append(.prose(joined)) }
            prose = []
        }
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flushProse()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                result.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if let heading = headingLevel(t) {
                flushProse()
                result.append(.heading(heading, String(t.drop(while: { $0 == "#" })).trimmed))
                i += 1
                continue
            }
            if t.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flushProse()
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i])); i += 1
                }
                result.append(.table(header, rows))
                continue
            }
            if let item = listItem(line) {
                flushProse()
                result.append(.bullet(item.marker, item.body, item.indent))
                i += 1
                continue
            }
            prose.append(line)
            i += 1
        }
        flushProse()
        return result
    }

    /// `- x`, `* x`, `+ x` → "•"; `1. x` / `1) x` keep their number.
    static func listItem(_ line: String) -> (marker: String, body: String, indent: Int)? {
        let leading = line.prefix(while: { $0 == " " }).count
        let t = line.dropFirst(leading)
        let indent = min(leading / 2, 3)
        if let first = t.first, "-*+".contains(first), t.dropFirst().first == " " {
            let body = String(t.dropFirst(2)).trimmed
            return body.isEmpty ? nil : ("•", body, indent)
        }
        let digits = t.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = t.dropFirst(digits.count)
            if let p = rest.first, p == "." || p == ")", rest.dropFirst().first == " " {
                let body = String(rest.dropFirst(2)).trimmed
                return body.isEmpty ? nil : ("\(digits).", body, indent)
            }
        }
        return nil
    }

    private static func headingLevel(_ t: String) -> Int? {
        let hashes = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmed }
    }
}

struct ToolRow: View {
    let tool: ToolActivity
    @State private var expanded = ToolRow.startExpanded

    static var startExpanded: Bool {
        #if DEBUG
        return MainActor.assumeIsolated { DebugLaunch.expandTools }
        #else
        return false
        #endif
    }

    #if os(macOS)
    static let titleFont = Font.system(size: 13)
    static let previewFont = Font.system(size: 12, design: .monospaced)
    static let titleStyle = HierarchicalShapeStyle.secondary
    #else
    static let titleFont = Font.footnote.weight(.semibold)
    static let previewFont = Font.system(.footnote, design: .monospaced)
    static let titleStyle = HierarchicalShapeStyle.primary
    #endif

    private var info: ToolInfo.Info { ToolInfo.info(tool.name) }
    private var hasDetail: Bool { (tool.output?.isEmpty == false) || (tool.arguments?.isEmpty == false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if hasDetail { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if tool.state == .running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: info.icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 18)
                    Text(info.title)
                        .font(ToolRow.titleFont)
                        .foregroundStyle(ToolRow.titleStyle)
                    if let preview = tool.preview, !preview.isEmpty {
                        Text(preview)
                            .font(ToolRow.previewFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if let d = tool.duration, d >= 1 {
                        Text(d < 60 ? "\(Int(d))s" : "\(Int(d / 60))m").font(.caption2).foregroundStyle(.tertiary)
                    }
                    switch tool.state {
                    case .running: EmptyView()
                    case .done: Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ToolDetail(tool: tool)
                    .transition(.opacity)
            }
        }
        #if os(macOS)
        .font(.system(size: 13))
        .padding(.vertical, 3)
        #else
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        #endif
    }
}

/// Expanded tool call: inputs as labeled fields, output as a readable block
/// (terminal output as a console, JSON as fields, text as markdown).
struct ToolDetail: View {
    let tool: ToolActivity

    var body: some View {
        let input = ToolFormatting.inputFields(tool.arguments, preview: tool.preview)
        let output = ToolFormatting.outputView(tool.output)
        VStack(alignment: .leading, spacing: 10) {
            if !input.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(input.enumerated()), id: \.offset) { _, field in
                        FieldRow(field: field)
                    }
                }
            }
            switch output {
            case .none:
                EmptyView()
            case .console(let text, let exitCode, let error):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Output").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        if let exitCode, exitCode != 0 {
                            Text("exit \(exitCode)").font(.caption2.weight(.semibold).monospaced())
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red.opacity(0.12), in: Capsule())
                        }
                    }
                    ConsoleBlock(text: text.isEmpty ? "(no output)" : text, isError: false)
                    if let error, !error.isEmpty { ConsoleBlock(text: error, isError: true) }
                }
            case .fields(let fields):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Result").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in FieldRow(field: field) }
                }
            case .text(let text):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        MarkdownText(text: text)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }
}

struct FieldRow: View {
    let field: ToolFormatting.Field

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            switch field.style {
            case .code:
                ConsoleBlock(text: field.value, isError: false)
            case .path:
                Text(field.value)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
            case .link:
                if let url = URL(string: field.value) {
                    Link(field.value, destination: url).font(.footnote).lineLimit(2)
                } else {
                    Text(field.value).font(.footnote)
                }
            case .text:
                Text(field.value)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button { UIPasteboard.general.string = field.value } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }
}

/// Monospaced, softly tinted block for commands, code and terminal output.
struct ConsoleBlock: View {
    let text: String
    let isError: Bool

    var body: some View {
        ScrollView([.vertical]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? Color.red : Color.primary.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .contextMenu {
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }
}

/// Turns raw tool JSON into labeled fields and readable output.
enum ToolFormatting {
    static let maxChars = 8_000

    struct Field: Equatable {
        enum Style: Equatable { case code, path, link, text }
        let label: String
        let value: String
        let style: Style
    }

    enum Output: Equatable {
        case none
        case console(String, exitCode: Int?, error: String?)
        case fields([Field])
        case text(String)
    }

    private static let codeKeys: Set<String> = ["command", "code", "script", "cmd", "patch", "diff", "old_string", "new_string", "content", "file_content", "sql", "query_sql"]
    private static let pathKeys: Set<String> = ["path", "file_path", "file", "workdir", "cwd", "directory", "dir", "pattern", "glob", "file_glob"]
    private static let skipKeys: Set<String> = ["session", "timeout_s", "timeout", "background", "notify", "persist_on_release"]

    /// Arguments as label/value rows, most important first. Long code stays monospaced.
    static func inputFields(_ raw: String?, preview: String?) -> [Field] {
        guard let raw, !raw.trimmed.isEmpty else {
            if let preview, !preview.isEmpty { return [Field(label: "Input", value: preview, style: .code)] }
            return []
        }
        guard let obj = json(raw) as? [String: Any] else { return [Field(label: "Input", value: clip(raw), style: .code)] }
        let order = ["command", "code", "query", "url", "path", "file_path", "goal", "prompt", "question", "name", "action"]
        let keys = obj.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
        return keys.compactMap { key in
            guard !skipKeys.contains(key), let value = obj[key], let s = display(value), !s.isEmpty else { return nil }
            return Field(label: label(key), value: clip(s), style: style(key: key, value: s))
        }
    }

    static func outputView(_ raw: String?) -> Output {
        guard let raw, !raw.trimmed.isEmpty else { return .none }
        if let obj = json(raw) as? [String: Any] {
            if let out = obj["output"] as? String {
                let err = (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .console(clip(out), exitCode: obj["exit_code"] as? Int, error: err)
            }
            if let content = obj["content"] as? String, obj.count <= 4 {
                return .text(clip(content))
            }
            let fields: [Field] = obj.keys.sorted().compactMap { key in
                guard let s = display(obj[key] as Any), !s.isEmpty else { return nil }
                return Field(label: label(key), value: clip(s), style: style(key: key, value: s))
            }
            return fields.isEmpty ? .none : .fields(fields)
        }
        if let arr = json(raw) as? [Any] {
            return .text(clip(arr.compactMap { display($0) }.map { "- \($0)" }.joined(separator: "\n")))
        }
        return .text(clip(raw))
    }

    // Kept for callers that want a single string (copy/share).
    static func arguments(_ raw: String?) -> String? {
        let f = inputFields(raw, preview: nil)
        return f.isEmpty ? nil : f.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    static func output(_ raw: String?) -> String? {
        switch outputView(raw) {
        case .none: return nil
        case .console(let t, let code, let err):
            var s = t.isEmpty ? "(no output)" : t
            if let code, code != 0 { s += "\n[exit \(code)]" }
            if let err { s += "\n\(err)" }
            return s
        case .fields(let f): return f.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        case .text(let t): return t
        }
    }

    private static func label(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    private static func style(key: String, value: String) -> Field.Style {
        if codeKeys.contains(key) || value.contains("\n") && value.count > 80 { return .code }
        if pathKeys.contains(key) { return .path }
        if value.hasPrefix("http://") || value.hasPrefix("https://"), !value.contains(" ") { return .link }
        return .text
    }

    /// Scalars as text; short arrays joined; nested objects as compact key: value lines.
    private static func display(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "yes" : "no"
        case let n as NSNumber: return n.stringValue
        case is NSNull: return nil
        case let arr as [Any]:
            let parts = arr.compactMap { display($0) }
            if parts.allSatisfy({ $0.count < 40 && !$0.contains("\n") }) { return parts.joined(separator: ", ") }
            return parts.map { "• \($0)" }.joined(separator: "\n")
        case let dict as [String: Any]:
            return dict.keys.sorted().compactMap { k in display(dict[k] as Any).map { "\(label(k)): \($0)" } }
                .joined(separator: "\n")
        default: return String(describing: value)
        }
    }

    private static func json(_ s: String) -> Any? {
        s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private static func clip(_ s: String) -> String {
        s.count <= maxChars ? s : String(s.prefix(maxChars)) + "\n… (\(s.count - maxChars) more characters)"
    }
}

struct ApprovalCard: View {
    let approval: ApprovalRequest
    let onChoice: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval needed", systemImage: "hand.raised.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            if let description = approval.description {
                Text(description).font(.callout)
            }
            if let command = approval.command {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }
            if let resolved = approval.resolvedChoice {
                Text(resolved == "deny" ? "Denied" : "Approved (\(Self.label(resolved).lowercased()))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    ForEach(approval.choices.filter { $0 != "deny" }, id: \.self) { choice in
                        Button { onChoice(choice) } label: {
                            // Prominent buttons draw a white label on the tint; our tint is near-white in dark mode.
                            Text(Self.label(choice)).foregroundStyle(Color(.systemBackground))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button("Deny", role: .destructive) { onChoice("deny") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.4)))
    }

    static func label(_ choice: String) -> String {
        switch choice {
        case "once": "Allow once"
        case "session": "This chat"
        case "always": "Always"
        case "deny": "Deny"
        default: choice.capitalized
        }
    }
}

/// Copy / Read aloud / Share under a finished reply, like ChatGPT and Claude.
struct MessageActions: View {
    let id: String
    let text: String
    @State private var copied = false
    private var speaker: Speaker { Speaker.shared }

    var body: some View {
        HStack(spacing: 18) {
            Button {
                UIPasteboard.general.string = text
                Haptics.tap()
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel(copied ? "Copied" : "Copy")
            Button {
                Haptics.tap()
                speaker.toggle(id: id, text: text)
            } label: {
                Image(systemName: speaker.speakingID == id ? "stop.circle" : "speaker.wave.2")
            }
            .accessibilityLabel(speaker.speakingID == id ? "Stop reading" : "Read aloud")
            ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.leading, 2)
    }
}

/// Suggestion chips on an empty chat.
struct StarterPrompts: View {
    let onPick: (String) -> Void

    static let prompts: [(icon: String, title: String, prompt: String)] = [
        ("sun.max", "Brief me on today", "Give me a short briefing for today: calendar, anything urgent in email or messages, and open tasks."),
        ("envelope", "Triage my inbox", "Check my email and tell me what actually needs a reply from me today."),
        ("checklist", "What's on the board?", "What's in progress or blocked on my kanban boards?"),
        ("globe", "Are my sites up?", "Check that all my websites are up and tell me only if something is wrong."),
    ]

    var body: some View {
        #if os(macOS)
        // Hermes-style chips: hairline capsules, wrapping onto centered rows when the chat column is narrow.
        PillFlow(spacing: 8, alignment: .center) {
            ForEach(Self.prompts, id: \.title) { p in
                Button { onPick(p.prompt) } label: {
                    Label(p.title, systemImage: p.icon)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .overlay(Capsule().strokeBorder(MacPalette.border, lineWidth: 1))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        #else
        VStack(spacing: 8) {
            ForEach(Self.prompts, id: \.title) { p in
                Button { onPick(p.prompt) } label: {
                    Label(p.title, systemImage: p.icon)
                        .font(.subheadline)
                        .frame(maxWidth: 260, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        #endif
    }
}

/// "Thinking" with a light sweeping across the letters, like ChatGPT.
struct TypingIndicator: View {
    var text = "Thinking"

    var body: some View {
        TimelineView(.animation) { timeline in
            let period = 1.6
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            // Band center travels from just left of the text to just right of it.
            let center = -0.3 + 1.6 * t
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .secondary.opacity(0.45), location: max(0, center - 0.25)),
                            .init(color: .primary, location: min(1, max(0, center))),
                            .init(color: .secondary.opacity(0.45), location: min(1, center + 0.25)),
                        ],
                        startPoint: .leading, endPoint: .trailing)
                )
        }
        .padding(.vertical, 4)
        .accessibilityLabel(text)
    }
}

#if DEBUG
/// Simulator-only: `-hermes.autosend "prompt"` opens a new chat and sends it once.
@MainActor
enum DebugLaunch {
    private static var consumed = false
    static var autoSend: String? { consumed ? nil : UserDefaults.standard.string(forKey: "hermes.autosend") }
    static var autoImage: Data? {
        UserDefaults.standard.string(forKey: "hermes.autoimage").flatMap { FileManager.default.contents(atPath: $0) }
    }
    static var autoSteer: String? { UserDefaults.standard.string(forKey: "hermes.autosteer") }
    static var expandTools: Bool { UserDefaults.standard.bool(forKey: "hermes.expandTools") }
    static func consumeAutoSend() -> String? {
        defer { consumed = true }
        return autoSend
    }
}
#endif

/// Titles come from the first message; keep the header short and on one line.
enum ChatTitle {
    nonisolated static func short(_ raw: String) -> String {
        let oneLine = (SkillInvocation.describe(raw) ?? raw).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > 30 else { return oneLine }
        let cut = String(oneLine.prefix(30))
        let atWord = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:…-")) + "…"
    }
}

/// On iPad the conversation is a centred column, like ChatGPT/Claude, instead of edge to edge.
enum ChatLayout {
    static let readableWidth: CGFloat = 760
}

#if os(macOS)
// MARK: - Mac composer (one hairline box like the Hermes desktop: + · text · model · mic · send)

extension ChatView {
    var macComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceChip(sessionID: model.sessionID, pendingWorkspaceID: model.workspaceID) { model.workspaceID = $0 }
            statusLine
            ActivityTray(sessionID: model.sessionID, isRunning: model.isRunning, store: activity)
            if !slashSuggestions.isEmpty {
                SlashSuggestionList(commands: slashSuggestions) { pick($0) }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { index, data in
                                AttachmentThumb(data: data) { attachments.remove(at: index) }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                HStack(alignment: .bottom, spacing: 4) {
                    Menu {
                        Button { showFileImporter = true } label: { Label("Choose Images…", systemImage: "folder") }
                        Button { showPhotos = true } label: { Label("Photos Library…", systemImage: "photo.on.rectangle") }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 30)
                            .contentShape(Rectangle())
                    }
                    .disabled(model.isRunning)
                    .help("Attach images (or paste / drop them)")
                    .accessibilityLabel("Attach")
                    ComposerTextView(
                        text: $draft, isFocused: $inputFocused,
                        placeholder: dictation.isRecording ? "Listening…" : model.isRunning ? "Add to this turn…" : "Message Otto",
                        suggestion: replySuggestion,
                        acceptsImages: !model.isRunning && attachments.count < 4,
                        onSubmit: { if canSend { sendDraft() } }
                    ) { images in
                        addPasted(images.compactMap { ImageEncoder.jpeg(from: $0) })
                    }
                    .padding(.top, 1)
                    macControls
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(dictation.isRecording ? Color.red.opacity(0.5) : MacPalette.border,
                                  lineWidth: dictation.isRecording ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
            .bareControls()
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(maxWidth: ChatLayout.readableWidth + 40)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: Color(.systemBackground).opacity(0), location: 0),
                                   .init(color: Color(.systemBackground), location: 0.3)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var modelLabel: String {
        if let c = model.modelChoice { return ModelNames.friendly(c.model) }
        if let m = app.modelOptions?.model, !m.isEmpty { return ModelNames.friendly(m) }
        return "Model"
    }

    @ViewBuilder private var macControls: some View {
        HStack(spacing: 2) {
            Button { commandsFilter = ""; showCommands = true } label: {
                Text("/")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 30)
                    .contentShape(Rectangle())
            }
            .help("Slash commands (or type /)")
            .accessibilityLabel("Commands")
            Button { modelPopover = true } label: {
                HStack(spacing: 3) {
                    Text(modelLabel).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .help("Model for this chat")
            .accessibilityLabel("Model: \(modelLabel)")
            .popover(isPresented: $modelPopover, arrowEdge: .top) {
                ModelPickerView(selection: Binding(get: { model.modelChoice }, set: { model.modelChoice = $0; modelPopover = false }))
                    .frame(width: 340, height: 460)
            }
            if fastAvailable {
                Button { model.fastMode = !(model.fastMode ?? false) } label: {
                    HStack(spacing: 2) {
                        Image(systemName: model.fastMode == true ? "bolt.fill" : "bolt")
                        Text(model.fastMode == true ? "Fast" : "Off")
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(model.fastMode == true ? Theme.accent : Color.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .help("Fast mode: quicker replies at a higher price")
                .accessibilityLabel(model.fastMode == true ? "Fast mode on" : "Fast mode off")
            }
            Button { Task { await dictation.toggle(current: draft) } } label: {
                Image(systemName: dictation.isRecording ? "waveform" : "mic")
                    .font(.system(size: 13.5))
                    .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                    .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .help(dictation.isRecording ? "Stop dictation" : "Dictate")
            .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
            Group {
                if !model.isRunning && draft.trimmed.isEmpty && attachments.isEmpty {
                    Button { dictation.stop(); showVoice = true } label: { MacSendFace(systemName: "waveform", enabled: true) }
                        .help("Voice mode (⇧⌘V)")
                        .accessibilityLabel("Voice mode")
                } else if model.isRunning && draft.trimmed.isEmpty {
                    Button { Task { await model.stop() } } label: { MacSendFace(systemName: "stop.fill", enabled: true, iconSize: 9) }
                        .help("Stop (Esc)")
                        .accessibilityLabel("Stop")
                } else {
                    Button { sendDraft() } label: { MacSendFace(systemName: "arrow.up", enabled: canSend) }
                        .disabled(!canSend)
                        .help("Send (Return) · new line: Shift-Return")
                        .accessibilityLabel("Send")
                }
            }
            .padding(.leading, 2)
        }
    }
}

/// The round send button: a dark disc with the glyph cut out (light disc in dark mode).
struct MacSendFace: View {
    let systemName: String
    let enabled: Bool
    var iconSize: CGFloat = 12

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(enabled ? Color(.systemBackground) : Color(.tertiaryLabel))
            .frame(width: 26, height: 26)
            .background(enabled ? Color.primary.opacity(0.85) : Color(.systemGray5), in: Circle())
            .frame(height: 30)
            .contentShape(Circle())
    }
}
#endif
