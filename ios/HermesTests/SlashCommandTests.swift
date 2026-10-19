import Foundation
import Testing
@testable import Hermes

struct SlashCommandTests {
    let catalog = SlashCommands.fallback + [SlashCommand(name: "caveman", description: "Terse voice", kind: "skill")]

    @Test func parsesCommandLines() {
        #expect(SlashCommands.parse("/compress here 2")! == ("compress", "here 2"))
        #expect(SlashCommands.parse("  /New  my chat ")! == ("new", "my chat"))
        #expect(SlashCommands.parse("/reload-mcp")!.name == "reload_mcp")
        #expect(SlashCommands.parse("/") == nil)
        #expect(SlashCommands.parse("hello /new") == nil)
        #expect(SlashCommands.parse("/Users/sam/file.txt is broken") == nil)
    }

    @Test func onlyKnownCommandsAreIntercepted() {
        #expect(SlashCommands.isCommand("/compress", catalog: catalog))
        #expect(SlashCommands.isCommand("/caveman", catalog: catalog))
        #expect(SlashCommands.isCommand("/bg do the thing", catalog: catalog))
        #expect(!SlashCommands.isCommand("/etc/hosts has a typo", catalog: catalog))
        #expect(!SlashCommands.isCommand("/notacommand", catalog: catalog))
    }

    @Test func coversEveryTelegramBuiltin() {
        let telegram = ["help", "new", "stop", "status", "egress", "resume", "sessions", "model", "debug", "restart",
                        "update", "commands", "approve", "deny", "queue", "steer", "bg", "btw", "reasoning", "usage",
                        "platform", "profile", "whoami", "start", "topic", "save", "retry", "undo", "title", "branch",
                        "compress", "rollback", "pause", "agents", "goal", "heartbeat", "refine", "review", "loop", "plan",
                        "initiate_setup", "moa", "subgoal", "context", "sethome", "codex_runtime", "personality", "diff",
                        "footer", "yolo", "approvals", "fast", "voice", "busy", "memory", "bundles", "learn", "init",
                        "suggestions", "blueprint", "curator", "kanban", "reload_mcp", "reload_skills", "login", "topup",
                        "insights", "version"]
        let names = Set(SlashCommands.fallback.map(\.name))
        #expect(telegram.allSatisfy { names.contains($0) })
    }

    @Test func phoneSideCommands() {
        #expect(SlashCommands.local("new", "") == .newChat(title: nil))
        #expect(SlashCommands.local("new", "Trip") == .newChat(title: "Trip"))
        #expect(SlashCommands.local("stop", "") == .stop)
        #expect(SlashCommands.local("bg", "check mail") == .background("check mail"))
        #expect(SlashCommands.local("restart", "") == .confirm("restart"))
        #expect(SlashCommands.local("compress", "") == nil)  // runs on the Mac
        #expect(SlashCommands.local("usage", "") == nil)
        if case .unavailable = SlashCommands.local("sethome", "") {} else { Issue.record("sethome should explain") }
    }

    @Test func suggestionsPreferPrefixMatches() {
        let s = SlashCommands.suggestions(for: "/co", catalog: catalog).map(\.name)
        #expect(s.first == "commands" || s.first == "compress" || s.first == "context" || s.first == "codex_runtime")
        #expect(s.allSatisfy { $0.contains("co") })
        #expect(SlashCommands.suggestions(for: "/compress now", catalog: catalog).isEmpty)
        #expect(SlashCommands.suggestions(for: "hi", catalog: catalog).isEmpty)
        #expect(SlashCommands.suggestions(for: "/", catalog: catalog).count == 40)
    }

    @Test func commandResultsSitWhereTheyRan() {
        let items: [ChatItem] = [.notice(id: "h10", text: "1", isError: false), .notice(id: "h12-0", text: "2", isError: false),
                                 .notice(id: "h20", text: "3", isError: false), .notice(id: "p", text: "pending", isError: false)]
        let early = SlashEntry(command: "/status", afterRow: 10)
        let late = SlashEntry(command: "/usage", afterRow: 25)
        let rows = ChatRow.merge(items: items, log: [late, early])
        #expect(rows.map(\.id) == ["h10", "slash-" + early.id, "h12-0", "h20", "slash-" + late.id, "p"])
        // After /compress rewrites rows 10-20 into new rows 30+, old cards stay above the new messages.
        let compressed: [ChatItem] = [.notice(id: "h30", text: "summary", isError: false)]
        #expect(ChatRow.merge(items: compressed, log: [early]).map(\.id) == ["slash-" + early.id, "h30"])
        #expect(ChatRow.newestRow(items) == 20)
    }

    @Test func decodesRelayReplies() throws {
        let json = #"{"kind":"open_session","text":"Branched","session_id":"20261009_1"}"#
        let r = try HermesClient.decoder.decode(SlashReply.self, from: Data(json.utf8))
        #expect(r.kind == "open_session" && r.sessionId == "20261009_1")
        let cat = try HermesClient.decoder.decode(SlashCatalog.self, from: Data(
            #"{"commands":[{"name":"bg","description":"x","args":"<prompt>","category":"Session","kind":"builtin","invoke":"background"}]}"#.utf8))
        #expect(cat.commands.first?.invoke == "background" && cat.commands.first?.takesArgs == true)
    }
}

struct SlashOutputLayoutTests {
    @Test func tablesScrollProseWraps() {
        #expect(SlashEntryView.isTabular("+-----+\n| hi  |\n+-----+"))
        #expect(SlashEntryView.isTabular("Session Token Usage\n────────\nModel: x"))
        #expect(!SlashEntryView.isTabular("Fast mode is off for this chat (claude-opus-5-5)."))
        #expect(!SlashEntryView.isTabular("Hermes TUI Status\n\nSession ID: abc\nTitle: x"))
    }
}
