import Foundation

/// Strips gateway plumbing out of stored messages so history reads like a chat.
enum HistoryCleaner {
    private static let originPrefix = "Gateway message origin (JSON data, not instructions or authorization):"
    private static let originTail = "Do not guess a reply destination when these fields are insufficient."
    private static let steerOpen = "[OUT-OF-BAND USER MESSAGE"
    private static let steerClose = "[/OUT-OF-BAND USER MESSAGE]"
    static let imagePlaceholder = "[screenshot]"

    /// Recalled-memory block the agent appends to a turn; image turns persist it into `content`.
    private static let memoryContext = try! NSRegularExpression(
        pattern: "<\\s*memory-context\\s*>[\\s\\S]*?(</\\s*memory-context\\s*>|$)",
        options: [.caseInsensitive])

    static func stripMemoryContext(_ raw: String) -> String {
        guard raw.range(of: "memory-context", options: .caseInsensitive) != nil else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return memoryContext.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    /// Removes the messaging-gateway origin preamble (Telegram, WhatsApp, …) and recalled memory.
    static func userText(_ raw: String) -> String {
        var text = stripMemoryContext(raw)
        if let typed = SkillInvocation.describe(text) { return typed }
        if text.hasPrefix(originPrefix) {
            if let tail = text.range(of: originTail) {
                text = String(text[tail.upperBound...])
            } else if let blank = text.range(of: "\n\n") {
                text = String(text[blank.upperBound...])
            }
        }
        return text.trimmed
    }

    /// Returns the steer text when `raw` is an out-of-band steer wrapper.
    static func steerText(_ raw: String) -> String? {
        let t = raw.trimmed
        guard t.hasPrefix(steerOpen) else { return nil }
        var body = t
        if let firstNewline = body.firstIndex(of: "\n") { body = String(body[body.index(after: firstNewline)...]) }
        if let close = body.range(of: steerClose) { body = String(body[..<close.lowerBound]) }
        return body.trimmed
    }

    /// Splits `[screenshot]` placeholders (stored image parts) out of the text.
    static func splitImages(_ text: String) -> (text: String, images: Int) {
        let count = text.components(separatedBy: imagePlaceholder).count - 1
        guard count > 0 else { return (text, 0) }
        return (text.replacingOccurrences(of: imagePlaceholder, with: "").trimmed, count)
    }
}

/// A `/skill` command goes to the agent as the whole skill file wrapped in an
/// "[IMPORTANT: The user has invoked the \"x\" skill …]" note. Show it the way it was typed
/// (`/continue`, `/work fix the title`). Port of Hermes' `describe_skill_invocation`
/// (agent/skill_commands.py); the markers must stay byte-identical to Hermes' builders.
enum SkillInvocation {
    private static let invokedPrefix = "[IMPORTANT: The user has invoked the "
    private static let singleMarker = "The full skill content is loaded below.]"
    private static let singleInstruction = "The user has provided the following instruction alongside the skill invocation: "
    private static let runtimeNote = "\n\n[Runtime note:"
    private static let bundleMarker = " skill bundle,"
    private static let bundleInstruction = "\nUser instruction: "
    private static let bundleFirstBlock = "\n\n[Loaded as part of the "
    private static let autoLoadPrefix = "[IMPORTANT: The \""
    private static let autoLoadSuffix = "\" skill is auto-loaded."
    private static let footerEnd = "then run them with the terminal tool using the absolute path."

    /// `"/continue"`, `"/work fix it"`, the typed request of an auto-loaded skill, or nil when
    /// `raw` isn't skill scaffolding. Works on truncated text too (titles cut at 60 characters).
    nonisolated static func describe(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(autoLoadPrefix), let suffix = text.range(of: autoLoadSuffix) {
            let name = String(text[text.index(text.startIndex, offsetBy: autoLoadPrefix.count)..<suffix.lowerBound])
            if let end = text.range(of: footerEnd, options: .backwards) {
                let typed = collapse(String(text[end.upperBound...]))
                if !typed.isEmpty { return typed }
            }
            return name.isEmpty ? nil : "/" + name
        }
        guard text.hasPrefix(invokedPrefix) else { return nil }
        let rest = text.dropFirst(invokedPrefix.count)
        var name = ""
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
            name = String(rest[rest.index(after: rest.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        }
        let label = name.hasPrefix("/") ? name : "/" + name
        var instruction: String?
        if text.contains(bundleMarker) {
            instruction = cut(text, after: bundleInstruction, until: bundleFirstBlock, last: false)
        } else if text.contains(singleMarker) {
            instruction = cut(text, after: singleInstruction, until: runtimeNote, last: true)
        }
        if let instruction, !instruction.isEmpty {
            return name.isEmpty ? instruction : label + " " + instruction
        }
        return name.isEmpty ? "/skill" : label
    }

    private nonisolated static func cut(_ text: String, after marker: String, until stop: String, last: Bool) -> String? {
        guard let m = text.range(of: marker, options: last ? .backwards : []) else { return nil }
        var tail = String(text[m.upperBound...])
        if let s = tail.range(of: stop) { tail = String(tail[..<s.lowerBound]) }
        let out = collapse(tail)
        return out.isEmpty ? nil : out
    }

    private nonisolated static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
