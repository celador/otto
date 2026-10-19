import Foundation
import Testing
@testable import Hermes

@Suite struct SSEParserTests {
    @Test func parsesEventsAndSkipsComments() {
        var p = SSEParser()
        let stream = ": open\nid: 0\ndata: {\"event\":\"tool.started\"}\n\n: keepalive\n\nid: 1\r\ndata: a\r\ndata: b\r\n\r\n"
        let msgs = p.feed(Array(stream.utf8))
        #expect(msgs == [
            SSEMessage(id: "0", event: nil, data: "{\"event\":\"tool.started\"}"),
            SSEMessage(id: "1", event: nil, data: "a\nb"),
        ])
    }

    @Test func handlesChunkBoundariesMidLine() {
        var p = SSEParser()
        let bytes = Array("event: x\ndata: héllo\n\n".utf8)
        var out: [SSEMessage] = []
        for chunk in stride(from: 0, to: bytes.count, by: 3) {
            out += p.feed(bytes[chunk..<min(chunk + 3, bytes.count)])
        }
        #expect(out == [SSEMessage(id: nil, event: "x", data: "héllo")])
    }
}

@Suite struct RunEventDecodingTests {
    // Payloads captured from the live gateway (Hermes 0.21.5), 2026-09-30.
    @Test func decodesCapturedPayloads() throws {
        let d = HermesClient.decoder
        let started = try d.decode(RunEvent.self, from: Data(#"{"event": "tool.started", "run_id": "run_be", "timestamp": 1790767077.02426, "tool": "terminal", "preview": "sleep 4 + 1 command", "seq": 0}"#.utf8))
        #expect(started.event == "tool.started" && started.tool == "terminal" && started.seq == 0)

        let completedTool = try d.decode(RunEvent.self, from: Data(#"{"event": "tool.completed", "tool": "terminal", "duration": 4.2, "error": false, "seq": 1}"#.utf8))
        #expect(completedTool.isError == false && completedTool.duration == 4.2)

        let failed = try d.decode(RunEvent.self, from: Data(#"{"event": "run.failed", "error": "boom", "seq": 9}"#.utf8))
        #expect(failed.isError && failed.errorMessage == "boom")

        let done = try d.decode(RunEvent.self, from: Data(#"{"event": "run.completed", "run_id": "r", "output": "hi", "usage": {"input_tokens": 1}, "seq": 4}"#.utf8))
        #expect(done.output == "hi")

        let approval = try d.decode(RunEvent.self, from: Data(#"{"command": "rm -rf build", "pattern_key": "rm", "description": "Recursive delete", "request_id": "req1", "event": "approval.request", "run_id": "r", "timestamp": 1, "choices": ["once", "session", "always", "deny"]}"#.utf8))
        #expect(approval.command == "rm -rf build" && approval.requestId == "req1" && approval.choices?.count == 4)
    }
}

@Suite struct TranscriptTests {
    @Test func streamsDeltasToolsAndCompletion() {
        var t = Transcript()
        t.appendUser("run date")
        t.beginRun()
        t.apply(RunEvent(event: "tool.started", seq: 0, tool: "terminal", preview: "date"), runID: "r")
        t.apply(RunEvent(event: "tool.completed", seq: 1, tool: "terminal", duration: 0.3), runID: "r")
        t.apply(RunEvent(event: "message.delta", seq: 2, delta: "\n\nThe"), runID: "r")
        t.apply(RunEvent(event: "message.delta", seq: 3, delta: " time"), runID: "r")
        #expect(t.items.last == .assistant(id: t.items.last!.id, text: "The time", streaming: true))
        t.apply(RunEvent(event: "run.completed", seq: 4, output: "The time is now."), runID: "r")
        #expect(t.terminalStatus == "completed")
        guard case .tool(let tool) = t.items[1] else { Issue.record("expected tool"); return }
        #expect(tool.state == .done && tool.duration == 0.3)
        guard case .assistant(_, let text, let streaming) = t.items[2] else { Issue.record("expected text"); return }
        #expect(text == "The time is now." && !streaming)
    }

    @Test func ignoresReplayedEventsAfterReattach() {
        var t = Transcript()
        t.beginRun()
        t.apply(RunEvent(event: "message.delta", seq: 0, delta: "Hi"), runID: "r")
        t.apply(RunEvent(event: "message.delta", seq: 1, delta: " there"), runID: "r")
        // Reattach replays from an older seq; duplicates must not double the text.
        t.apply(RunEvent(event: "message.delta", seq: 1, delta: " there"), runID: "r")
        t.apply(RunEvent(event: "message.delta", seq: 2, delta: "!"), runID: "r")
        guard case .assistant(_, let text, _) = t.items.last else { Issue.record("expected text"); return }
        #expect(text == "Hi there!")
        #expect(t.lastSeq == 2)
    }

    @Test func approvalLifecycle() {
        var t = Transcript()
        t.beginRun()
        t.apply(RunEvent(event: "approval.request", command: "rm -rf x", description: "delete",
                         choices: ["once", "deny"], requestId: "q1"), runID: "r")
        #expect(t.pendingApproval?.requestID == "q1")
        t.resolveApproval(requestID: "q1", choice: "deny")
        #expect(t.pendingApproval == nil)
    }

    @Test func failedToolAndRunNotice() {
        var t = Transcript()
        t.beginRun()
        t.apply(RunEvent(event: "tool.started", seq: 0, tool: "terminal"), runID: "r")
        t.apply(RunEvent(event: "tool.completed", seq: 1, tool: "terminal", isError: true), runID: "r")
        t.apply(RunEvent(event: "run.failed", seq: 2, isError: true, errorMessage: "Provider down"), runID: "r")
        guard case .tool(let tool) = t.items[0] else { Issue.record("expected tool"); return }
        #expect(tool.state == .failed)
        #expect(t.items.last == .notice(id: t.items.last!.id, text: "Provider down", isError: true))
    }

    @Test func buildsFromHistoryWithToolFailure() throws {
        let json = #"""
        {"object":"list","data":[
         {"id":1,"role":"user","content":"Run date","tool_call_id":null,"tool_calls":null,"tool_name":null,"timestamp":1},
         {"id":2,"role":"assistant","content":"","tool_calls":[{"id":"t1","type":"function","function":{"name":"terminal","arguments":"{\"command\": \"date\"}"}}],"tool_name":null,"timestamp":2},
         {"id":3,"role":"tool","content":"{\"output\": \"\", \"exit_code\": 1, \"error\": null}","tool_call_id":"t1","tool_calls":null,"tool_name":"terminal","timestamp":3},
         {"id":4,"role":"assistant","content":"It failed.","tool_calls":null,"tool_name":null,"timestamp":4},
         {"id":5,"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"[image]"}}],"timestamp":5}
        ]}
        """#
        let list = try HermesClient.decoder.decode(MessageList.self, from: Data(json.utf8))
        let t = Transcript.fromHistory(list.data)
        #expect(t.items.count == 4)
        guard case .tool(let tool) = t.items[1] else { Issue.record("expected tool"); return }
        #expect(tool.name == "terminal" && tool.preview == "date" && tool.state == .failed)
        #expect(t.items[3] == .user(UserMessage(id: "h5", text: "look")))
    }
}

@Suite struct ConnectionParsingTests {
    @Test func normalizesURLs() {
        #expect(AppModel.normalizedURL("my-mac.example.ts.net:8642/")?.absoluteString == "https://my-mac.example.ts.net:8642")
        #expect(AppModel.normalizedURL("http://192.168.1.5:8642")?.absoluteString == "http://192.168.1.5:8642")
        #expect(AppModel.normalizedURL("  ") == nil)
        #expect(AppModel.normalizedURL("ftp://x") == nil)
    }

    @Test func parsesConnectionLink() {
        let link = "hermes://connect?url=https%3A%2F%2Fnano.ts.net%3A8642&key=abc123"
        let parsed = AppModel.parseConnectionLink(link)
        #expect(parsed?.url == "https://nano.ts.net:8642")
        #expect(parsed?.key == "abc123")
        #expect(AppModel.parseConnectionLink("https://example.com") == nil)
    }
}

@Suite struct MarkdownBlockTests {
    @Test func parsesTablesHeadingsAndCode() {
        let md = "## Result\nThe icon is biggest.\n\n| File | Size |\n|---|---:|\n| a.png | 709 KB |\n| b.swift | 10 KB |\n\n```\nls -la\n```\nDone."
        #expect(MarkdownBlocks.parse(md) == [
            .heading(2, "Result"),
            .prose("The icon is biggest."),
            .table(["File", "Size"], [["a.png", "709 KB"], ["b.swift", "10 KB"]]),
            .code("ls -la"),
            .prose("Done."),
        ])
    }

    @Test func pipeWithoutSeparatorIsProse() {
        #expect(MarkdownBlocks.parse("| not a table") == [.prose("| not a table")])
        #expect(MarkdownBlocks.parse("#hashtag") == [.prose("#hashtag")])
    }
}

@Suite struct SkillInvocationTests {
    static let body = "[IMPORTANT: The user has invoked the \"continue\" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]\n\n---\nname: continue\n---\n\n# /continue\n\nWhat's next?\n\n[Skill directory: /Users/x/.hermes/skills/productivity/continue]\nResolve any relative paths in this skill against that directory, then run them with the terminal tool using the absolute path."

    @Test func bareSkillShowsAsTyped() {
        #expect(SkillInvocation.describe(Self.body) == "/continue")
        #expect(HistoryCleaner.userText(Self.body) == "/continue")
        #expect(HistoryCleaner.userText(Self.body + "\n<memory-context>\nfacts\n</memory-context>") == "/continue")
    }

    @Test func skillWithInstruction() {
        let m = Self.body + "\n\nThe user has provided the following instruction alongside the skill invocation: ship  the\nfix\n\n[Runtime note: x]"
        #expect(SkillInvocation.describe(m) == "/continue ship the fix")
    }

    @Test func bundleAndAutoLoad() {
        let bundle = "[IMPORTANT: The user has invoked the \"/clean /work\" skill bundle, loading 2 skills together. Treat every skill below as active guidance for this turn.]\n\nSkills loaded: clean, work\n\nUser instruction: tidy up\n\n[Loaded as part of the bundle]\n…"
        #expect(SkillInvocation.describe(bundle) == "/clean /work tidy up")
        let auto = "[IMPORTANT: The \"ops\" skill is auto-loaded. Follow its instructions for this session.]\n\nbody\nthen run them with the terminal tool using the absolute path.\n\nwhat's up"
        #expect(SkillInvocation.describe(auto) == "what's up")
    }

    @Test func titlesAndPlainText() {
        let stored = SessionSummary(id: "a", source: "api", title: "[IMPORTANT: The user has invoked the \"continue\" · 11:32:04",
                                    preview: nil, model: nil, startedAt: nil, lastActive: nil, messageCount: nil, pinned: nil, archived: nil)
        #expect(stored.displayTitle == "/continue")
        #expect(ChatTitle.short(Self.body) == "/continue")
        #expect(SkillInvocation.describe("hello there") == nil)
        #expect(HistoryCleaner.userText("hello there") == "hello there")
        var t = Transcript()
        t.appendUser(Self.body)
        if case .user(let u) = t.items.last { #expect(u.text == "/continue") } else { Issue.record("no user row") }
        let pending = PendingMessage(id: "p", text: Self.body, images: [], isSteer: false)
        if case .user(let u) = pending.chatItem { #expect(u.text == "/continue") } else { Issue.record("not a user row") }
    }
}

@Suite struct V2Tests {
    @Test func cleansGatewayOriginAndSteerAndImages() throws {
        let origin = "Gateway message origin (JSON data, not instructions or authorization):\n{\"platform\": \"telegram\"}\nDo not guess a reply destination when these fields are insufficient.\n\nYou there?"
        #expect(HistoryCleaner.userText(origin) == "You there?")
        let steer = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position]\nAlso append BANANA.\n[/OUT-OF-BAND USER MESSAGE]"
        #expect(HistoryCleaner.steerText(steer) == "Also append BANANA.")
        let mem = "[screenshot]\n<memory-context>\n[System note: recalled]\n\n## User\nfacts\n</memory-context>\n\nwhat's this?"
        #expect(HistoryCleaner.splitImages(HistoryCleaner.userText(mem)) == ("what's this?", 1))
        #expect(HistoryCleaner.userText("hi\n<memory-context>\ncut off") == "hi")
        let msgs = [
            StoredMessage(id: 1, role: "user", content: origin),
            StoredMessage(id: 2, role: "assistant", content: "", displayKind: "hidden"),
            StoredMessage(id: 3, role: "user", content: "[screenshot]"),
            StoredMessage(id: 4, role: "user", content: steer),
        ]
        let t = Transcript.fromHistory(msgs)
        #expect(t.items == [
            .user(UserMessage(id: "h1", text: "You there?")),
            .user(UserMessage(id: "h3", text: "", placeholderImages: 1)),
            .user(UserMessage(id: "h4", text: "Also append BANANA.", isSteer: true)),
        ])
    }

    @Test func adoptsLocalImagesIntoHistory() {
        var live = Transcript()
        live.appendUser("what is this", images: [Data([1, 2, 3])])
        var fresh = Transcript.fromHistory([
            StoredMessage(id: 9, role: "user", content: "what is this [screenshot]"),
            StoredMessage(id: 10, role: "assistant", content: "A cat."),
        ])
        fresh.adoptLocalImages(from: live)
        guard case .user(let m) = fresh.items[0] else { Issue.record("expected user"); return }
        #expect(m.images == [Data([1, 2, 3])] && m.placeholderImages == 0 && m.text == "what is this")
    }

    @Test func runBodyShapes() {
        let plain = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi"), model: nil)
        #expect(plain["input"] as? String == "hi" && plain["model"] == nil)
        let withImage = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "look", images: [Data([0xFF])]),
                                             model: ModelChoice(provider: "anthropic", model: "claude-sonnet-5"))
        let input = withImage["input"] as? [[String: Any]]
        let parts = input?.first?["content"] as? [[String: Any]]
        #expect(parts?.count == 2)
        #expect(parts?[0]["type"] as? String == "input_text")
        #expect((parts?[1]["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(withImage["provider"] as? String == "anthropic")
    }

    @Test func toolOutputFormatting() {
        #expect(ToolFormatting.output(#"{"output": "hi", "exit_code": 0, "error": null}"#) == "hi")
        #expect(ToolFormatting.output(#"{"output": "", "exit_code": 2, "error": null}"#) == "(no output)\n[exit 2]")
        #expect(ToolFormatting.arguments(#"{"command": "ls -la"}"#) == "Command: ls -la")
        let live = RunEvent(event: "tool.completed", seq: 1, tool: "terminal", preview: "total 8")
        var t = Transcript()
        t.beginRun()
        t.apply(RunEvent(event: "tool.started", seq: 0, tool: "terminal", preview: "ls"), runID: "r")
        t.apply(live, runID: "r")
        guard case .tool(let tool) = t.items[0] else { Issue.record("expected tool"); return }
        #expect(tool.output == "total 8" && tool.preview == "ls")
    }

    @Test func sessionOrderingAndDisplayTitle() throws {
        let json = #"{"data":[{"id":"a","title":null,"preview":"Gateway message origin (JSON data, not instructions or authorization):\n{}\nDo not guess a reply destination when these fields are insufficient.\n\nHello","last_active":1},{"id":"b","title":"Pinned","pinned":true,"last_active":0}]}"#
        let list = try HermesClient.decoder.decode(SessionList.self, from: Data(json.utf8))
        #expect(list.data[0].displayTitle == "Hello")
        #expect(list.data[1].isPinned)
    }
}

@Suite struct ListTests {
    @Test func parsesBulletsAndNumbers() {
        #expect(MarkdownBlocks.parse("Intro\n- one\n  - nested\n2. two") == [
            .prose("Intro"), .bullet("•", "one", 0), .bullet("•", "nested", 1), .bullet("2.", "two", 0),
        ])
        #expect(MarkdownBlocks.parse("-not a list") == [.prose("-not a list")])
    }
}

@Suite struct LaunchActionTests {
    @Test func parsesWidgetAndShortcutURLs() {
        #expect(LaunchAction(url: URL(string: "hermes://new")!) == .newChat)
        #expect(LaunchAction(url: URL(string: "hermes://new?dictate=1")!) == .dictate)
        #expect(LaunchAction(url: URL(string: "hermes://new?camera=1")!) == .camera)
        #expect(LaunchAction(url: URL(string: "hermes://new?prompt=What%27s%20up%3F")!) == .ask("What's up?"))
        #expect(LaunchAction(url: URL(string: "hermes://new?prompt=%20%20")!) == .newChat)
        #expect(LaunchAction(url: URL(string: "hermes://connect?url=x&key=y")!) == nil)
    }

    @Test func roundTripsThroughURL() {
        for action in [LaunchAction.newChat, .dictate, .camera, .ask("brief me & check sites")] {
            #expect(LaunchAction(url: action.url) == action)
        }
    }
}

@Suite struct SpeechTextTests {
    @Test func stripsMarkdownForReadingAloud() {
        let md = """
        ## Today
        - **Call** Sam about [the site](https://example.com)
        - Check `shop-site` at https://shop.example.com/x
        ```bash
        echo hello
        ```
        | Site | Status |
        |---|---|
        | example.com | up |
        """
        let spoken = SpeechText.clean(md)
        #expect(spoken == "Today\nCall Sam about the site\nCheck shop-site at link\n(code omitted)\nSite, Status\nexample.com, up")
    }
}

@Suite(.serialized) struct DraftStoreTests {
    @Test func keepsDraftPerChatAndClearsBlank() {
        DraftStore.set("half-typed thought", sessionID: "s_test_1")
        DraftStore.set("new chat idea", sessionID: nil)
        #expect(DraftStore.get(sessionID: "s_test_1") == "half-typed thought")
        #expect(DraftStore.get(sessionID: nil) == "new chat idea")
        DraftStore.set("   ", sessionID: "s_test_1")
        DraftStore.set("", sessionID: nil)
        #expect(DraftStore.get(sessionID: "s_test_1") == "")
        #expect(DraftStore.get(sessionID: nil) == "")
    }
}

@Suite(.serialized) struct OutboxTests {
    @Test func keepsUnsentMessagesUntilRemoved() {
        let sid = "s_outbox_test"
        Outbox.save([], sessionID: sid)
        Outbox.add(PendingMessage(id: "p1", text: "are you there?", images: [Data([1])]), sessionID: sid)
        Outbox.markFailed(id: "p1", error: "offline", sessionID: sid)
        let loaded = Outbox.load(sessionID: sid)
        #expect(loaded.map(\.text) == ["are you there?"])
        #expect(loaded.first?.error == "offline" && loaded.first?.images == [Data([1])])
        Outbox.remove(id: "p1", sessionID: sid)
        #expect(Outbox.load(sessionID: sid).isEmpty)
    }

    @Test func newChatOutboxMovesToCreatedSession() {
        Outbox.save([PendingMessage(id: "p2", text: "first message")], sessionID: nil)
        Outbox.save([], sessionID: "s_outbox_new")
        Outbox.move(fromNewChatTo: "s_outbox_new")
        #expect(Outbox.load(sessionID: nil).isEmpty)
        #expect(Outbox.load(sessionID: "s_outbox_new").map(\.id) == ["p2"])
        Outbox.save([], sessionID: "s_outbox_new")
    }

    @Test func pendingRendersAsSendingOrNotDelivered() {
        #expect(PendingMessage(id: "p3", text: "hi").chatItem
                == .user(UserMessage(id: "p3", text: "hi", delivery: .sending)))
        #expect(PendingMessage(id: "p3", text: "hi", error: "offline").chatItem
                == .user(UserMessage(id: "p3", text: "hi", delivery: .failed("offline"))))
    }

    @Test func messagesLeftSendingAtLaunchCountAsNotDelivered() {
        let restored = Outbox.restoredAfterLaunch([PendingMessage(id: "p4", text: "mid-send"),
                                                   PendingMessage(id: "p5", text: "old", error: "offline")])
        #expect(restored.map(\.error) == [Outbox.interruptedError, "offline"])
    }

    @Test func steerToFinishedRunIsRecognised() {
        #expect(HermesError.http(409, "Run is not currently accepting steer input: r").runNotAcceptingSteer)
        #expect(!HermesError.http(500, nil).runNotAcceptingSteer)
    }
}

@Suite struct OpenChatRestoreTests {
    @Test func encodesAndRestoresTheOpenChat() {
        let s = SessionSummary.stub(id: "20260930_105452_1dd3c4c1")
        #expect(OpenChat.encode(.session(s)) == "session:20260930_105452_1dd3c4c1")
        #expect(OpenChat.encode(.new(UUID())) == "new")
        #expect(OpenChat.route(from: "session:20260930_105452_1dd3c4c1", sessions: [s]) == .session(s))
        if case .new = OpenChat.route(from: "new", sessions: []) {} else { Issue.record("expected new chat") }
        #expect(OpenChat.route(from: "session:gone", sessions: [s]) == nil)
        #expect(OpenChat.route(from: "", sessions: [s]) == nil)
    }
}

extension SessionSummary {
    static func stub(id: String) -> SessionSummary {
        SessionSummary(id: id, source: "telegram", title: "Chat", preview: nil, model: nil,
                       startedAt: nil, lastActive: nil, messageCount: nil, pinned: nil, archived: nil)
    }
}

@Suite struct ComposerEchoTests {
    let sentAt = Date(timeIntervalSince1970: 1_000)
    let sent = "Please check the build on my phone"

    @Test func clearsTextThatComesBackRightAfterSend() {
        // Late speech result / keyboard dictation re-commit: the whole message.
        #expect(ComposerEcho.isEcho(sent, sent: sent, sentAt: sentAt, now: sentAt + 0.4))
        // Pending autocorrect or last dictated phrase: the end of the message.
        #expect(ComposerEcho.isEcho("my phone", sent: sent, sentAt: sentAt, now: sentAt + 0.4))
    }

    @Test func leavesNewTypingAlone() {
        #expect(!ComposerEcho.isEcho("p", sent: sent, sentAt: sentAt, now: sentAt + 0.5))
        #expect(!ComposerEcho.isEcho("Also", sent: sent, sentAt: sentAt, now: sentAt + 0.5))
        #expect(!ComposerEcho.isEcho(sent, sent: sent, sentAt: sentAt, now: sentAt + 5))
        #expect(!ComposerEcho.isEcho("", sent: sent, sentAt: sentAt, now: sentAt + 0.1))
        #expect(!ComposerEcho.isEcho(sent, sent: nil, sentAt: nil, now: sentAt))
    }
}


@Suite struct BoardAndAutomationTests {
    @Test func relayURLDefaultsToGatewayHostOnRelayPort() {
        let gw = URL(string: "https://my-mac.example.ts.net:8642")!
        #expect(KanbanClient.relayURL(forGateway: gw, override: nil)?.absoluteString == "https://my-mac.example.ts.net:8651")
        #expect(KanbanClient.relayURL(forGateway: gw, override: "  ")?.absoluteString == "https://my-mac.example.ts.net:8651")
        #expect(KanbanClient.relayURL(forGateway: gw, override: "board.example.ts.net:9000/")?.absoluteString == "https://board.example.ts.net:9000")
        // The Mac app talks to the local gateway; its relay is the plain local port.
        let local = URL(string: "http://127.0.0.1:8642")!
        #expect(KanbanClient.relayURL(forGateway: local, override: nil)?.absoluteString == "http://127.0.0.1:8650")
    }

    @Test func decodesBoardAndTaskFromRelay() throws {
        let board = #"{"columns":[{"name":"triage","tasks":[{"id":"t_04f4e9d6","title":"Move text","body":"x","assignee":null,"status":"triage","priority":7,"created_at":1789754073,"comment_count":2,"latest_summary":null}]},{"name":"done","tasks":[]}],"tenants":[],"now":1}"#
        let b = try HermesClient.decoder.decode(KanbanBoard.self, from: Data(board.utf8))
        #expect(b.columns.count == 2)
        #expect(b.columns[0].tasks[0].commentCount == 2)
        #expect(b.columns[0].tasks[0].priority == 7)
        let detail = #"{"task":{"id":"t_1","title":"T","status":"blocked"},"comments":[{"id":30,"task_id":"t_1","author":"default","body":"Fixed","created_at":1790510676}],"events":[{"id":296,"task_id":"t_1","kind":"created","payload":{"a":1},"created_at":1790203978,"run_id":null}],"attachments":[]}"#
        let d = try HermesClient.decoder.decode(KanbanTaskDetail.self, from: Data(detail.utf8))
        #expect(d.comments.first?.author == "default")
        #expect(d.events.first?.kind == "created")
    }

    @Test func boardOpenCountIgnoresDoneAndArchived() throws {
        let json = #"{"boards":[{"slug":"atelier","name":"Atelier","icon":"🎨","counts":{"blocked":1,"done":15,"todo":2,"triage":1,"archived":4},"total":19}]}"#
        let r = try HermesClient.decoder.decode(KanbanBoardsResponse.self, from: Data(json.utf8))
        #expect(r.boards[0].openCount == 4)
    }

    @Test func decodesJobsAndFriendlySchedules() throws {
        let json = #"{"jobs":[{"id":"a0e97eb1e357","name":"Daily briefing","enabled":true,"state":"scheduled","schedule_display":"0 7 * * *","next_run_at":"2026-10-01T07:00:00-03:00","last_run_at":"2026-09-30T07:01:47.138493-03:00","last_status":"ok","deliver":"telegram"}]}"#
        let jobs = try HermesClient.decoder.decode(JobList.self, from: Data(json.utf8)).jobs
        #expect(jobs[0].nextRun != nil)
        #expect(jobs[0].lastRun != nil)
        #expect(!jobs[0].isPaused)
        #expect(ScheduleText.friendly("0 7 * * *") == "Daily at 07:00")
        #expect(ScheduleText.friendly("30 8 * * 1") == "Mondays at 08:30")
        #expect(ScheduleText.friendly("every 30m") == "Every 30 min")
    }
}

@Suite struct ChatMenuTests {
    @Test func shareTextAndFind() throws {
        let json = #"{"data":[{"id":1,"role":"user","content":"Check the Atelier site"},{"id":2,"role":"assistant","content":"elier.ai is **up** and fast."}]}"#
        let messages = try HermesClient.decoder.decode(MessageList.self, from: Data(json.utf8)).data
        let t = Transcript.fromHistory(messages)
        let share = t.shareText(title: "Site check")
        #expect(share == "Site check\n\nYou: Check the Atelier site\n\nAgent: elier.ai is **up** and fast.")
        #expect(t.matches("ATELIER").count == 1)
        #expect(t.matches("fast").count == 1)
        #expect(t.matches("  ").isEmpty)
    }

    @Test func shortTitles() {
        #expect(ChatTitle.short("Site check") == "Site check")
        #expect(ChatTitle.short("For Atelier...   I'm pivoting from offering paid agents") == "For Atelier... I'm pivoting…")
    }
}

@Suite(.serialized) struct RichToolsAndStatusTests {
    @Test func toolFieldsAreReadable() {
        let f = ToolFormatting.inputFields(#"{"command":"git status","workdir":"/Users/sam/code","timeout":30,"background":false}"#, preview: nil)
        #expect(f.map(\.label) == ["Command", "Workdir"])
        #expect(f[0].style == .code)
        #expect(f[1].style == .path)
        let web = ToolFormatting.inputFields(#"{"query":"hermes ios","limit":5}"#, preview: nil)
        #expect(web.first?.label == "Query" && web.first?.style == .text)
    }

    @Test func terminalOutputIsConsole() {
        let out = ToolFormatting.outputView(#"{"output":"On branch main","exit_code":1,"error":"boom"}"#)
        #expect(out == .console("On branch main", exitCode: 1, error: "boom"))
        if case .fields(let f) = ToolFormatting.outputView(#"{"success":true,"path":"/tmp/x"}"#) {
            #expect(f.map(\.label) == ["Path", "Success"])
            #expect(f.last?.value == "yes")
        } else { Issue.record("expected fields") }
    }

    @Test func friendlyToolNamesAndLiveLabels() {
        #expect(ToolInfo.info("terminal").title == "Terminal")
        #expect(ToolInfo.info("kanban_show").title == "Board · show")
        #expect(ToolInfo.liveLabel(name: "terminal", preview: "ls") == "Running a command: ls")
        #expect(ToolInfo.liveLabel(name: "terminal", preview: nil) == "Running a command")
        #expect(ToolInfo.liveLabel(name: "web_search", preview: "best espresso montevideo") == "Searching the web: best espresso montevideo")
        #expect(ToolInfo.liveLabel(name: "read_file", preview: "/Users/sam/code/x/ChatView.swift") == "Reading ChatView.swift")
    }

    @Test func remoteRunStatusLine() {
        // A turn running elsewhere: its stored tool call without a result is in progress, not done.
        let calls = [ToolCall(id: "c1", function: .init(name: "terminal", arguments: #"{"command":"git status"}"#))]
        var t = Transcript.fromHistory([
            StoredMessage(id: 1, role: "user", content: "check the repo"),
            StoredMessage(id: 2, role: "assistant", content: "", toolCalls: calls),
        ])
        if case .tool(let a) = t.items.last { #expect(a.state == .done) } else { Issue.record("expected a tool") }
        t.markOpenToolsRunning()
        if case .tool(let a) = t.items.last { #expect(a.state == .running) } else { Issue.record("expected a tool") }
        #expect(t.liveStatus == "Running a command: git status")
        var run = ChatActivity.RemoteRun(running: true, kind: "tool", tool: "web_search", preview: "otto")
        #expect(run.label == "Searching the web: otto")
        run.waiting = true
        #expect(run.label == "Waiting for your approval")
        #expect(ChatActivity.RemoteRun(running: true, kind: "thinking").label == "Thinking…")
        #expect(RunStatusLine.elapsed(7) == "0:07")
        #expect(RunStatusLine.elapsed(3723) == "1:02:03")
    }

    @Test func interruptedRepliesBecomeNotices() throws {
        let json = #"{"data":[{"id":1,"role":"user","content":"hi"},{"id":2,"role":"assistant","content":"Operation interrupted: waiting for model response (6.1s elapsed)."}]}"#
        let t = Transcript.fromHistory(try HermesClient.decoder.decode(MessageList.self, from: Data(json.utf8)).data)
        guard case .notice(_, let text, true) = t.items.last else { Issue.record("expected notice"); return }
        #expect(text == "This reply was interrupted before it finished.")
    }

    @Test func liveStatusFollowsRunningTool() {
        var t = Transcript()
        t.appendUser("check")
        t.beginRun()
        t.apply(RunEvent(event: "tool.started", seq: 1, tool: "web_search", preview: "hermes"), runID: "r")
        #expect(t.liveStatus == "Searching the web: hermes")
        t.apply(RunEvent(event: "tool.completed", seq: 2, tool: "web_search"), runID: "r")
        #expect(t.liveStatus == nil)
        #expect(t.toolsThisTurn == 1)
    }

    @Test func storedPhotosReplacePlaceholders() throws {
        let sid = "test_photos_\(UUID().uuidString.prefix(6))"
        defer { PhotoStore.deleteAll(sessionID: sid) }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        PhotoStore.save([jpeg], text: "what is this?", sessionID: sid)
        let json = #"{"data":[{"id":1,"role":"user","content":"what is this? [screenshot]"}]}"#
        var t = Transcript.fromHistory(try HermesClient.decoder.decode(MessageList.self, from: Data(json.utf8)).data)
        t.attachStoredPhotos(sessionID: sid)
        guard case .user(let m) = t.items.first else { Issue.record("expected user"); return }
        #expect(m.images == [jpeg])
        #expect(m.placeholderImages == 0)
    }
}


@Suite struct CompanionTests {
    @Test func memoryUsageCountsDelimiters() throws {
        let json = #"{"memory":["abc","de"],"user":[],"limits":{"memory":2200,"user":1375}}"#
        let m = try HermesClient.decoder.decode(MemoryState.self, from: Data(json.utf8))
        #expect(m.used(.memory) == 8)
        #expect(m.used(.user) == 0)
        #expect(m.limit(.user) == 1375)
    }

    @Test func profileTitles() throws {
        let json = #"{"profiles":[{"name":"default","model":"anthropic/claude-opus-5-5"},{"name":"atelier-lifecycle-marketer"}],"active":"default"}"#
        let r = try HermesClient.decoder.decode(ProfilesResponse.self, from: Data(json.utf8))
        #expect(r.profiles[0].title == "Main agent")
        #expect(r.profiles[0].modelShort == "claude-opus-5-5")
        #expect(r.profiles[1].title == "Atelier Lifecycle Marketer")
    }

    @Test @MainActor func skillFrontmatterIsStripped() {
        let s = "---\nname: x\ndescription: y\n---\n# Title\nBody"
        #expect(SkillDetailViewProbe.strip(s) == "# Title\nBody")
    }

    @Test func screensRoundTrip() {
        for s in [Screen.board, .automations, .archived, .agents, .skills, .memory, .usage] {
            #expect(Screen.from(storageKey: s.storageKey!) == s)
        }
    }
}


@Suite struct AutomationExtrasTests {
    @Test func schedulesReadNaturally() {
        #expect(ScheduleText.friendly("every 30m") == "Every 30 min")
        #expect(ScheduleText.friendly("every 1h") == "Every hour")
        #expect(ScheduleText.friendly("*/15 * * * *") == "Every 15 min")
        #expect(ScheduleText.friendly("17 3 * * 0,6") == "Weekends at 03:17")
        #expect(ScheduleText.friendly("0 7 * * *") == "Daily at 07:00")
    }

    @Test func runSummaries() throws {
        let json = #"{"runs":[{"id":"cron_output:abc:2026-09-30_22-57-57","title":"COMPLETED · # Cron Job: X **Status:** silent (empty output)","source":"cron_output","started_at":1790819877.0},{"id":"cron_a_1","title":"Daily briefing","source":"cron","started_at":1790762489.18,"ended_at":1790762506.08,"tool_call_count":3,"estimated_cost_usd":0.152}]}"#
        let runs = try HermesClient.decoder.decode(JobRuns.self, from: Data(json.utf8)).runs
        #expect(runs[0].isScriptOutput && runs[0].silent)
        #expect(runs[0].summary == "Nothing to report")
        #expect(runs[1].summary == "3 steps · $0.15")
        #expect(Int(runs[1].duration ?? 0) == 16)
    }

    @Test func blueprintValuesDecode() throws {
        let json = #"{"blueprints":[{"key":"important-mail","title":"Mail","fields":[{"name":"interval_min","type":"enum","label":"How often?","default":"30","options":["15",30]}]}]}"#
        let b = try HermesClient.decoder.decode(Blueprints.self, from: Data(json.utf8)).blueprints[0]
        #expect(b.fields[0].options?.map(\.text) == ["15", "30"])
        #expect(b.icon == "envelope.badge")
        #expect(Delivery.label("bot-chat:webmaster") == "Bot chat · webmaster")
    }

    @Test func pairingDecodes() throws {
        let json = #"{"pending":[{"platform":"telegram","request_id":"r_abc123","user_id":"42","user_name":"Ana","age_minutes":3}],"approved":[{"platform":"telegram","user_id":"7","user_name":"K","approved_at":1790000000.5}]}"#
        let p = try HermesClient.decoder.decode(PairingState.self, from: Data(json.utf8))
        #expect(p.pending[0].requestId == "r_abc123")
        #expect(p.approved[0].id == "telegram:7")
    }
}


@Suite struct VoiceTests {
    @Test func sentencesAreSpokenAsTheyArrive() {
        let (a, n) = VoiceSession.completeSentences("Sure. Your briefing ran at seven and everything is fine. Also, the", flush: false)
        #expect(a == "Sure. Your briefing ran at seven and everything is fine.")
        #expect(n == 56)
        let (b, _) = VoiceSession.completeSentences("Still typing without an end", flush: false)
        #expect(b.isEmpty)
        let (c, m) = VoiceSession.completeSentences(" last bit", flush: true)
        #expect(c == "last bit" && m == 9)
    }

    @Test func voiceTurnsAskForSpokenReplies() {
        let body = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi", voice: true), model: nil)
        #expect((body["instructions"] as? String)?.contains("read aloud") == true)
        let plain = HermesClient.runBody(sessionID: "s", message: OutgoingMessage(text: "hi"), model: nil)
        #expect(plain["instructions"] == nil)
    }

    @Test func voiceLaunchURL() {
        #expect(LaunchAction(url: URL(string: "hermes://new?voice=1")!) == .voice)
        #expect(LaunchAction.voice.url.absoluteString == "hermes://new?voice=1")
    }
}
