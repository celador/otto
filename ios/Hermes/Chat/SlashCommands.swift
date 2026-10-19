import Foundation

/// Slash commands, the same set the Telegram bot registers (`/new`, `/compress`, `/usage`, skills…).
///
/// The list comes from the relay (`GET /hermes/commands`, built from Hermes' own Telegram menu).
/// Commands that act on the phone (new chat, stop, model, voice, approvals…) run here; everything
/// else goes to `POST /hermes/slash`, which runs it on the Mac the way the desktop app does.
struct SlashCommand: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var description: String
    var args: String = ""
    var category: String = "Session"
    var kind: String = "builtin"
    var invoke: String? = nil

    var id: String { name }
    var isSkill: Bool { kind == "skill" }
    var takesArgs: Bool { !args.isEmpty }
}

struct SlashCatalog: Codable, Sendable {
    var commands: [SlashCommand]
}

/// What the Mac answered.
struct SlashReply: Codable, Sendable, Equatable {
    /// output (show text) · send (send `message` as the next turn) · prefill (put `message` in the
    /// composer) · open_session (switch to `session_id`) · error
    var kind: String
    var text: String? = nil
    var message: String? = nil
    var notice: String? = nil
    var sessionId: String? = nil
}

/// One command and its result, shown inline in the chat (not part of the server transcript).
struct SlashEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var command: String
    var output: String?
    var isError = false
    var running = false
    /// Shown after the stored message with this row id (the newest one when the command ran).
    /// Row ids only grow, so the card keeps its place when /compress or /undo rewrites the chat.
    var afterRow: Int? = nil
    /// A chat this command made (/bg, /branch): tapping opens it.
    var openSessionID: String? = nil
}

/// Commands the phone handles itself.
enum SlashLocal: Equatable, Sendable {
    case newChat(title: String?)
    case stop
    case steer(String)
    case queue(String)
    case background(String)
    case model(String?)
    case fast(String?)
    case voice(String?)
    case approve(String?)
    case deny
    case help(String?)
    case title(String?)
    case resume(String?)
    case branch(String?)
    case moa(String)
    case confirm(String)       // restart / update: ask first, then run on the Mac
    case unavailable(String)   // Telegram-only commands
}

enum SlashCommands {
    /// "/compress here 2" → ("compress", "here 2"). nil when the text isn't a command line.
    nonisolated static func parse(_ text: String) -> (name: String, arg: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), t.count > 1 else { return nil }
        let body = t.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty, !name.contains("/"),
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" || $0 == "." })
        else { return nil }
        let arg = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.lowercased().replacingOccurrences(of: "-", with: "_"), arg)
    }

    /// Is this a command we know (so "/Users/sam/x is broken" still goes out as a message)?
    nonisolated static func isCommand(_ text: String, catalog: [SlashCommand]) -> Bool {
        guard let (name, _) = parse(text) else { return false }
        return catalog.contains { $0.name == name || $0.invoke == name } || localNames.contains(name)
    }

    nonisolated static let localNames: Set<String> = [
        "new", "reset", "stop", "steer", "queue", "q", "bg", "background", "model", "fast", "voice",
        "approve", "deny", "help", "commands", "start", "title", "resume", "branch", "fork", "moa",
        "restart", "update", "sethome", "set_home", "topic"]

    /// The phone-side action for a command, or nil to run it on the Mac.
    nonisolated static func local(_ name: String, _ arg: String) -> SlashLocal? {
        let a: String? = arg.isEmpty ? nil : arg
        switch name {
        case "new", "reset": return .newChat(title: a)
        case "stop": return .stop
        case "steer": return .steer(arg)
        case "queue", "q": return .queue(arg)
        case "bg", "background": return .background(arg)
        case "model": return .model(a)
        case "fast": return .fast(a)
        case "voice": return .voice(a)
        case "approve": return .approve(a)
        case "deny": return .deny
        case "help", "commands", "start": return .help(name == "help" ? a : nil)
        case "title": return .title(a)
        case "resume": return .resume(a)
        case "branch", "fork": return .branch(a)
        case "moa": return .moa(arg)
        case "restart", "update": return .confirm(name)
        case "sethome", "set_home":
            return .unavailable("/sethome picks the chat where Hermes sends cron results and notifications. "
                                + "It applies to messaging chats (Telegram, WhatsApp…), so run it there; the app gets "
                                + "results in Automations either way.")
        case "topic":
            return .unavailable("/topic turns on Telegram's per-topic sessions in a DM. Every chat in the app is "
                                + "already its own session.")
        default: return nil
        }
    }

    /// Suggestions for what's typed so far ("/co" → /compress, /context, /codex_runtime…).
    /// Built-ins first in Telegram's order, then skills.
    nonisolated static func suggestions(for text: String, catalog: [SlashCommand], limit: Int = 40) -> [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let q = text.dropFirst().lowercased().replacingOccurrences(of: "-", with: "_")
        if q.isEmpty { return Array(catalog.prefix(limit)) }
        let starts = catalog.filter { $0.name.hasPrefix(q) }
        let contains = catalog.filter { !$0.name.hasPrefix(q) && $0.name.contains(q) }
        return Array((starts + contains).prefix(limit))
    }

    /// Used until the relay answers (or when it's too old to have /hermes/commands).
    nonisolated static let fallback: [SlashCommand] = [
        .init(name: "help", description: "Show available commands (/help skills lists skill commands, /help <text> filters)", args: "[skills|<filter>]", category: "Info"),
        .init(name: "new", description: "Start a new session (fresh session ID + history)", args: "[name]", category: "Session"),
        .init(name: "stop", description: "Kill all running background processes", args: "", category: "Session"),
        .init(name: "status", description: "Show session, model, token, and context info", args: "", category: "Session"),
        .init(name: "egress", description: "Show Docker egress proxy status", args: "[status]", category: "Session"),
        .init(name: "resume", description: "Resume a previously-named session", args: "[name]", category: "Session"),
        .init(name: "sessions", description: "Browse and resume previous sessions", args: "", category: "Session"),
        .init(name: "model", description: "Switch model (session-scoped; --global to persist)", args: "[model] [--provider name] [--reasoning level] [--global|--session] [--refresh]", category: "Configuration"),
        .init(name: "debug", description: "Upload debug report (system info + logs) and get shareable links", args: "[nous|local]", category: "Info"),
        .init(name: "restart", description: "Gracefully restart the gateway after draining active runs", args: "", category: "Session"),
        .init(name: "update", description: "Update Hermes Agent to the latest version", args: "", category: "Info"),
        .init(name: "commands", description: "Browse all commands and skills (paginated)", args: "[page]", category: "Info"),
        .init(name: "approve", description: "Approve a pending dangerous command", args: "[session|always]", category: "Session"),
        .init(name: "deny", description: "Deny a pending dangerous command (optionally with a reason)", args: "[all] [reason]", category: "Session"),
        .init(name: "queue", description: "Queue a prompt for the next turn, or list/edit/rm/move/clear queued prompts", args: "[<prompt>|list|edit N <prompt>|rm N|move A B|clear]", category: "Session"),
        .init(name: "steer", description: "Inject a message after the next tool call without interrupting", args: "<prompt>", category: "Session"),
        .init(name: "bg", description: "Run a prompt in a separate background session", args: "<prompt>", category: "Session"),
        .init(name: "btw", description: "Ask a side question about the current conversation without interrupting it", args: "<question>", category: "Session"),
        .init(name: "reasoning", description: "Manage reasoning effort and display", args: "[level|show|hide|full|clamp] [--global]", category: "Configuration"),
        .init(name: "usage", description: "Show token usage and rate limits; `reset` redeems a banked Codex limit reset", args: "[reset [--force]]", category: "Info"),
        .init(name: "platform", description: "Pause, resume, or list a failing gateway platform", args: "<pause|resume|list> [name]", category: "Info"),
        .init(name: "profile", description: "Show active profile name and home directory", args: "", category: "Info"),
        .init(name: "whoami", description: "Show your slash command access (admin / user)", args: "", category: "Info"),
        .init(name: "start", description: "Acknowledge platform start pings without a reply", args: "", category: "Session"),
        .init(name: "topic", description: "Enable or inspect Telegram DM topic sessions", args: "[off|help|session-id]", category: "Session"),
        .init(name: "save", description: "Export the current conversation (bare /save shows usage)", args: "<json|md|html> [filename] [redact]", category: "Session"),
        .init(name: "retry", description: "Retry the last message (resend to agent)", args: "", category: "Session"),
        .init(name: "undo", description: "Back up N user turns and re-prompt (default 1)", args: "[N]", category: "Session"),
        .init(name: "title", description: "Set a title for the current session", args: "[name]", category: "Session"),
        .init(name: "branch", description: "Branch the current session (new thread on Discord/Telegram/Slack/Matrix; --here stays here)", args: "[--here] [name]", category: "Session"),
        .init(name: "compress", description: "Compress conversation context (add 'here [N]' to keep recent N turns; --preview shows what would happen)", args: "[here [N] | focus topic | --preview|--dry-run]", category: "Session"),
        .init(name: "rollback", description: "List or restore filesystem checkpoints (restores keep your hand-edits; --all overrides)", args: "[number] [--all]", category: "Session"),
        .init(name: "pause", description: "Pause new work globally (emergency stop); '/pause off' resumes", args: "[reason | off]", category: "Session"),
        .init(name: "agents", description: "Show active agents and running tasks", args: "", category: "Session"),
        .init(name: "goal", description: "Set a standing goal Hermes works on across turns until achieved", args: "[text | -- <text> | draft <text> | show | gate add <cmd> | pause | resume | clear | status | wait <pid> | unwait]", category: "Session"),
        .init(name: "heartbeat", description: "Set a recurring prompt that re-enters this session when idle", args: "[every <interval> <prompt> | status | pause | resume | clear]", category: "Session"),
        .init(name: "refine", description: "Review this conversation now and save lessons to memory/skills", args: "[focus instructions]", category: "Session"),
        .init(name: "review", description: "Spawn an independent subagent to review the work just discussed (PR, code, docs)", args: "[review instructions]", category: "Session"),
        .init(name: "loop", description: "Re-run a prompt on a recurring interval in this session", args: "[interval] <prompt> [--times N] [--until <condition>] | status | pause | resume | stop", category: "Session"),
        .init(name: "plan", description: "Write a markdown implementation plan to .hermes/plans/ without executing anything", args: "[task]", category: "Session"),
        .init(name: "initiate_setup", description: "Run the first-run setup: learn about you and set Hermes up around you", args: "", category: "Session"),
        .init(name: "moa", description: "Run one prompt through the default Mixture of Agents preset, then restore your model", args: "<prompt>", category: "Session"),
        .init(name: "subgoal", description: "Add or manage extra criteria on the active goal", args: "[text | remove N | clear]", category: "Session"),
        .init(name: "context", description: "Show detailed context window view with usage gauge, category breakdown, compression stats, and throughput", args: "[all]", category: "Session"),
        .init(name: "sethome", description: "Set this chat as the home channel", args: "", category: "Session"),
        .init(name: "codex_runtime", description: "Toggle codex app-server runtime for OpenAI/Codex models", args: "[auto|codex_app_server]", category: "Configuration"),
        .init(name: "personality", description: "Set a predefined personality", args: "[name]", category: "Configuration"),
        .init(name: "diff", description: "Show git changes in the working directory", args: "[staged|all|session] [--stat] [path...]", category: "Info"),
        .init(name: "footer", description: "Toggle gateway runtime-metadata footer on final replies", args: "[on|off|status]", category: "Configuration"),
        .init(name: "yolo", description: "Toggle YOLO mode (skip all dangerous command approvals)", args: "", category: "Configuration"),
        .init(name: "approvals", description: "Show or set the persistent dangerous-command approval mode", args: "[manual|smart|off]", category: "Configuration"),
        .init(name: "fast", description: "Fast mode — OpenAI Priority Processing / Anthropic Fast Mode (normal/fast/auto/cold/ultrafast)", args: "[normal|fast|auto|cold|status] [--global]", category: "Configuration"),
        .init(name: "voice", description: "Toggle voice mode", args: "[on|off|tts|status]", category: "Configuration"),
        .init(name: "busy", description: "Control how messages behave while Hermes is working", args: "[queue|steer|interrupt|status]", category: "Configuration"),
        .init(name: "memory", description: "Review pending memory writes / toggle the approval gate", args: "[pending|approve|reject|approval] [id|on|off]", category: "Tools & Skills"),
        .init(name: "bundles", description: "List skill bundles (aliases /<name> for multiple skills)", args: "", category: "Tools & Skills"),
        .init(name: "learn", description: "Learn a reusable skill from anything you describe (dirs, URLs, this chat, notes)", args: "<what to learn from>", category: "Tools & Skills"),
        .init(name: "init", description: "Generate or update AGENTS.md project instructions from a repo scan", args: "[notes]", category: "Tools & Skills"),
        .init(name: "suggestions", description: "Review suggested automations (accept/dismiss)", args: "[accept|dismiss N | catalog]", category: "Tools & Skills"),
        .init(name: "blueprint", description: "Set up an automation from a blueprint template", args: "[name] [slot=value ...]", category: "Tools & Skills"),
        .init(name: "curator", description: "Background skill maintenance (status, run, pin, archive, list-archived)", args: "[subcommand]", category: "Tools & Skills"),
        .init(name: "kanban", description: "Multi-profile collaboration board (tasks, links, comments)", args: "[subcommand]", category: "Tools & Skills"),
        .init(name: "reload_mcp", description: "Reload MCP servers from config", args: "", category: "Tools & Skills"),
        .init(name: "reload_skills", description: "Re-scan ~/.hermes/skills/ for newly installed or removed skills", args: "", category: "Tools & Skills"),
        .init(name: "login", description: "Sign in with a Nous account (keeps your connectors)", args: "", category: "Info"),
        .init(name: "topup", description: "Show your Nous balance and manage billing on the portal", args: "", category: "Info"),
        .init(name: "insights", description: "Show usage insights and analytics", args: "[days]", category: "Info"),
        .init(name: "version", description: "Show Hermes Agent version", args: "", category: "Info")
    ]
}

/// A row on the chat screen: a transcript item, or a slash command and its result.
enum ChatRow: Identifiable, Equatable, Sendable {
    case item(ChatItem)
    case command(SlashEntry)

    var id: String {
        switch self {
        case .item(let i): i.id
        case .command(let e): "slash-" + e.id
        }
    }

    /// Slots each command in after the stored message that was newest when it ran; anything still
    /// streaming or not yet delivered stays last.
    nonisolated static func merge(items: [ChatItem], log: [SlashEntry]) -> [ChatRow] {
        let entries = log.enumerated()
            .sorted { ($0.element.afterRow ?? 0, $0.offset) < ($1.element.afterRow ?? 0, $1.offset) }
            .map(\.element)
        var out: [ChatRow] = []
        out.reserveCapacity(items.count + entries.count)
        var next = 0
        for item in items {
            let key = rowID(item.id) ?? Int.max
            while next < entries.count, (entries[next].afterRow ?? 0) < key {
                out.append(.command(entries[next])); next += 1
            }
            out.append(.item(item))
        }
        while next < entries.count { out.append(.command(entries[next])); next += 1 }
        return out
    }

    /// "h123" / "h123-2" (history rows) → 123; streamed and outbox items have none.
    nonisolated static func rowID(_ id: String) -> Int? {
        guard id.hasPrefix("h") else { return nil }
        return Int(id.dropFirst().prefix { $0.isNumber })
    }

    /// The newest stored row in a transcript (0 when it has none yet).
    nonisolated static func newestRow(_ items: [ChatItem]) -> Int {
        items.compactMap { rowID($0.id) }.max() ?? 0
    }
}

/// Keeps a chat's command log across relaunches (last 40 entries).
enum SlashLogStore {
    private static func key(_ sessionID: String?) -> String { "slashlog.\(sessionID ?? "new")" }

    static func load(sessionID: String?) -> [SlashEntry] {
        guard let data = UserDefaults.standard.data(forKey: key(sessionID)),
              var log = try? JSONDecoder().decode([SlashEntry].self, from: data) else { return [] }
        // Cards from build 49 were placed by position and drift when a chat is compressed; drop them.
        log.removeAll { $0.afterRow == nil }
        // A command that was running when the app quit never got its answer here.
        for i in log.indices where log[i].running {
            log[i].running = false
            log[i].output = log[i].output ?? "No answer (the app was closed while it ran)."
        }
        return log
    }

    static func save(_ log: [SlashEntry], sessionID: String?) {
        let trimmed = Array(log.suffix(40))
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(sessionID))
        } else if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key(sessionID))
        }
    }
}
