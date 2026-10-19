import Foundation

/// Human-friendly names, icons and live labels for Hermes tools.
/// Used by tool rows (title + icon), the live status line ("Searching the web…")
/// and the Live Activity.
enum ToolInfo {
    struct Info: Sendable {
        let title: String       // "Terminal"
        let icon: String        // SF Symbol
        let doing: String       // "Running a command"
    }

    static func info(_ rawName: String) -> Info {
        let name = normalized(rawName)
        if let known = table[name] { return known }
        if name.hasPrefix("kanban_") {
            let verb = name.dropFirst("kanban_".count).replacingOccurrences(of: "_", with: " ")
            return Info(title: "Board · \(verb)", icon: "rectangle.split.3x1", doing: "Updating the board")
        }
        if name.hasPrefix("browser_") {
            let verb = name.dropFirst("browser_".count).replacingOccurrences(of: "_", with: " ")
            return Info(title: "Browser · \(verb)", icon: "safari", doing: "Using the browser")
        }
        if name.hasPrefix("mcp_") || name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_").filter { !$0.isEmpty && $0 != "mcp" }
            let service = parts.first.map { $0.capitalized } ?? "Connector"
            return Info(title: service, icon: "puzzlepiece.extension", doing: "Using \(service)")
        }
        let pretty = name.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        return Info(title: pretty, icon: "wrench.and.screwdriver", doing: "Using \(pretty.lowercased())")
    }

    /// "Running `git status`" style one-liner for the live status line.
    static func liveLabel(name: String, preview: String?) -> String {
        let i = info(name)
        guard let p = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return i.doing }
        let short = p.count > 48 ? String(p.prefix(47)) + "…" : p
        switch normalized(name) {
        case "terminal", "execute_code":
            let line = short.split(separator: "\n").first.map(String.init) ?? short
            return "\(i.doing): \(line)"
        case "web_search", "mcp_perplexity_perplexity_search", "mcp_perplexity_perplexity_ask", "session_search":
            return "\(i.doing): \(short)"
        case "read_file", "write_file", "patch", "search_files":
            return "\(i.doing) \((p as NSString).lastPathComponent)"
        default:
            return i.doing
        }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "mcp__", with: "mcp_")
    }

    private static let table: [String: Info] = [
        "terminal": Info(title: "Terminal", icon: "terminal", doing: "Running a command"),
        "process": Info(title: "Process", icon: "gearshape.2", doing: "Checking a process"),
        "process_manage": Info(title: "Process", icon: "gearshape.2", doing: "Checking a process"),
        "execute_code": Info(title: "Code", icon: "chevron.left.forwardslash.chevron.right", doing: "Running code"),
        "read_file": Info(title: "Read file", icon: "doc.text", doing: "Reading"),
        "write_file": Info(title: "Write file", icon: "square.and.pencil", doing: "Writing"),
        "patch": Info(title: "Edit file", icon: "pencil.line", doing: "Editing"),
        "search_files": Info(title: "Search files", icon: "doc.text.magnifyingglass", doing: "Searching files in"),
        "web_search": Info(title: "Web search", icon: "magnifyingglass", doing: "Searching the web"),
        "web_extract": Info(title: "Read web page", icon: "globe", doing: "Reading a web page"),
        "vision_analyze": Info(title: "Look at image", icon: "eye", doing: "Looking at an image"),
        "computer_use": Info(title: "Computer", icon: "desktopcomputer", doing: "Using the Mac"),
        "browser_exec": Info(title: "Browser", icon: "safari", doing: "Using the browser"),
        "browser_navigate": Info(title: "Browser · open", icon: "safari", doing: "Opening a page"),
        "skill_view": Info(title: "Skill", icon: "book", doing: "Reading a skill"),
        "skill_manage": Info(title: "Update skill", icon: "book.closed", doing: "Updating a skill"),
        "skills_list": Info(title: "Skills", icon: "books.vertical", doing: "Looking through skills"),
        "memory": Info(title: "Memory", icon: "brain", doing: "Updating memory"),
        "context_notes": Info(title: "Memory", icon: "brain", doing: "Updating memory"),
        "session_search": Info(title: "Past chats", icon: "clock.arrow.circlepath", doing: "Searching past chats"),
        "chat_history_lookup": Info(title: "Past chats", icon: "clock.arrow.circlepath", doing: "Searching past chats"),
        "todo": Info(title: "To-do list", icon: "checklist", doing: "Planning"),
        "todo_list": Info(title: "To-do list", icon: "checklist", doing: "Planning"),
        "clarify": Info(title: "Question", icon: "questionmark.bubble", doing: "Asking you something"),
        "delegate_task": Info(title: "Subagent", icon: "person.2", doing: "Handing off to a subagent"),
        "subagent": Info(title: "Subagent", icon: "person.2", doing: "A subagent is working"),
        "send_message": Info(title: "Send message", icon: "paperplane", doing: "Sending a message"),
        "message_agent": Info(title: "Message agent", icon: "paperplane", doing: "Messaging another agent"),
        "cronjob": Info(title: "Automation", icon: "clock", doing: "Scheduling"),
        "cronjob_manage": Info(title: "Automation", icon: "clock", doing: "Scheduling"),
        "tool_search": Info(title: "Find tools", icon: "magnifyingglass", doing: "Finding the right tool"),
        "tool_describe": Info(title: "Tool details", icon: "info.circle", doing: "Looking up a tool"),
        "tool_call": Info(title: "Tool", icon: "wrench.and.screwdriver", doing: "Using a tool"),
        "image_generate": Info(title: "Make image", icon: "photo", doing: "Making an image"),
        "text_to_speech": Info(title: "Speech", icon: "speaker.wave.2", doing: "Making audio"),
        "mcp_perplexity_perplexity_ask": Info(title: "Perplexity", icon: "sparkle.magnifyingglass", doing: "Asking Perplexity"),
        "mcp_perplexity_perplexity_search": Info(title: "Perplexity", icon: "sparkle.magnifyingglass", doing: "Searching with Perplexity"),
    ]
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
