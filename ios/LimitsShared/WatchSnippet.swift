import Foundation

/// Turning a Markdown answer into something a wrist can show.
enum WatchSnippet {
    static func plain(_ s: String) -> String {
        var t = s
        for (pattern, repl) in [("```[\\s\\S]*?```", ""), ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
                                ("(\\*\\*|__|~~|`)", ""), ("(?m)^#{1,6}\\s+", ""), ("(?m)^[-*+]\\s+", "• "),
                                ("(?m)^\\|.*\\|$", ""), ("\\n{3,}", "\n\n")] {
            t = t.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first sentence/line, for a complication or notification-sized line.
    static func firstLine(_ s: String, max: Int = 60) -> String {
        let p = plain(s)
        let line = p.split(whereSeparator: \.isNewline).first.map(String.init) ?? p
        var sentence = line
        if let r = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { sentence = String(line[..<r.upperBound]) }
        sentence = sentence.trimmingCharacters(in: .whitespaces)
        return sentence.count > max ? String(sentence.prefix(max - 1)) + "…" : sentence
    }

    /// Hermes ended by asking you something a Yes/No settles ("Want me to go ahead?").
    static func asksYesNo(_ s: String) -> Bool {
        let p = plain(s)
        guard p.hasSuffix("?") else { return false }
        let tail = p.split(whereSeparator: { ".!\n".contains($0) }).last.map { String($0).lowercased() } ?? ""
        let openers = ["should i", "shall i", "want me to", "do you want", "would you like", "ok to", "okay to",
                       "can i", "may i", "go ahead", "proceed", "is that ok", "is that okay", "sound good",
                       "does that work", "ready to", "confirm", "do it"]
        let questionWords = ["what ", "which ", "when ", "where ", "who ", "how ", "why "]
        if questionWords.contains(where: { tail.trimmingCharacters(in: .whitespaces).hasPrefix($0) }) { return false }
        if tail.contains(" or ") { return false }   // "A or B?" isn't a yes/no
        return openers.contains { tail.contains($0) }
    }
}
