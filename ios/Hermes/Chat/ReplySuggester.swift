import Foundation

/// A one-tap reply for the composer's placeholder, from the agent's last message.
/// "…Want me to deploy it?" → "Yes, deploy it". Accept with → / Tab (hardware keyboard),
/// a space-bar drag to the right, or a swipe right on the empty field; then send.
/// Local and instant: plain pattern matching on the closing question, no model call.
enum ReplySuggester {
    static func suggest(after assistantText: String) -> String? {
        if let question = closingQuestion(in: assistantText), let r = suggest(question: question) { return r }
        return suggest(offerIn: closingSentences(in: assistantText))
    }

    /// Offers that aren't questions: "If you want, I can X.", "…or say "submit it" and I'll do it.",
    /// "I'd do item 2 next.", "Let me know if you want me to X."
    static func suggest(offerIn sentences: [String]) -> String? {
        for raw in sentences.reversed() {
            let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
            if let said = first(#"\bsay\s+["“]([^"”]{1,60})["”]\s+and\s+I(?:'|’)?ll\b"#, in: s) {
                return capitalizedFirst(said)
            }
            if s.range(of: #"\bsay the word\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return "Yes, go ahead" }
            if let a = first(#"\bif\s+you(?:'d|’d|\s+would)?\s+(?:want|like|prefer)\b[^,]*,\s*I\s+(?:can|could|will)\s+(?:also\s+)?(.+)$"#, in: s)
                ?? first(#"\bif\s+you(?:'d|’d|\s+would)?\s+(?:want|like|prefer)\b[^,]*,\s*I(?:'|’)ll\s+(.+)$"#, in: s)
                ?? first(#"^I\s+(?:can|could)\s+(?:also\s+)?(.+?)\s+if\s+you(?:'d|’d)?\s+(?:want|like)\b"#, in: s)
                ?? first(#"\blet me know if you(?:'d|’d)?\s+(?:want|like)\s+me\s+to\s+(.+)$"#, in: s)
                ?? first(#"\bhappy to\s+(.+?)(?:\s+if\s+you(?:'d|’d)?\s+(?:want|like).*)?$"#, in: s) {
                return reply(for: a, lead: "Yes, ")
            }
            if let a = first(#"^I(?:'d|’d| would)\s+((?:do|start with|tackle|go with|pick|ship)\s+.+?\s+(?:next|first))$"#, in: s) {
                return reply(for: a, lead: "Yes, ")
            }
        }
        return nil
    }

    static func suggest(question: String) -> String? {
        let q = question.trimmingCharacters(in: .whitespaces)
        let lower = q.lowercased()

        if lower.range(of: #"\banything else\b"#, options: .regularExpression) != nil
            || lower.range(of: #"^any (other )?(questions|changes|tweaks|thoughts|feedback)\b"#, options: .regularExpression) != nil {
            return "No, that's all"
        }
        if let m = first(#"\b(?:does|do|did)\s+(?:that|this|it|these|those|everything)\s+(look|sound|seem|work)s?\b"#, in: q) {
            switch m.lowercased() {
            case "sound": return "Sounds good"
            case "work": return "Yes, works for me"
            default: return "Looks good"
            }
        }
        if lower.range(of: #"\b(?:is|are)\s+(?:that|this|these|those)\s+(?:ok|okay|alright|all right|fine|right|correct)\b"#,
                       options: .regularExpression) != nil
            || lower.range(of: #"^(?:ok|okay|sound good|good|cool|fine)$"#, options: .regularExpression) != nil {
            return "Yes, that's fine"
        }
        if let action = first(#"\b(?:would|do)\s+you\s+(?:like|want)\s+me\s+to\b\s*(.*)$"#, in: q)
            ?? first(#"(?:^|[\s,;:—–-])(?:want|need)\s+me\s+to\b\s*(.*)$"#, in: q)
            ?? first(#"\b(?:should|shall)\s+I\b\s*(.*)$"#, in: q) {
            return reply(for: action, lead: "Yes, ")
        }
        if let action = first(#"\b(?:should|shall)\s+we\b\s*(.*)$"#, in: q) {
            return reply(for: action, lead: "Yes, let's ")
        }
        if lower.range(of: #"\bready\s+(?:for\s+me\s+)?to\b"#, options: .regularExpression) != nil
            || lower.range(of: #"^(?:want|would you like)\s+(?:a|an|the|some|that|this|it|me)\b"#, options: .regularExpression) != nil
            || lower.range(of: #"^(?:proceed|go ahead|continue)$"#, options: .regularExpression) != nil {
            return "Yes, go ahead"
        }
        return nil
    }

    /// The last sentence of the reply if it's a question (or the one before it, when the reply
    /// ends with a short aside). Markdown is flattened first.
    /// The last two sentences of the reply's last paragraph, markdown flattened.
    static func closingSentences(in text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n")
            .map { flatten($0) }
            .filter { !$0.isEmpty }
        guard let last = paragraphs.last else { return [] }
        return Array(splitSentences(last).suffix(2))
    }

    static func closingQuestion(in text: String) -> String? {
        for s in closingSentences(in: text).reversed() where s.hasSuffix("?") {
            return String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - Pieces

    private static func reply(for rawAction: String, lead: String) -> String {
        var a = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
        // Asides and qualifiers after a dash/parenthesis/semicolon aren't part of the action.
        for sep in [" — ", " – ", " - ", " (", "; ", ": "] {
            if let r = a.range(of: sep) { a = String(a[..<r.lowerBound]) }
        }
        a = a.replacingOccurrences(of: #"[,\s]+or not$"#, with: "", options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: #"^(?:go ahead and|also|just|now|then)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        a = a.replacingOccurrences(of: #"\s+for you$"#, with: "", options: [.regularExpression, .caseInsensitive])
        a = a.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!"))
        // "Should I ship now or wait?" → the first option, stated plainly.
        var choice = false
        if let r = a.range(of: #",?\s+or\s+"#, options: .regularExpression), !a[..<r.lowerBound].isEmpty {
            a = String(a[..<r.lowerBound]); choice = true
        }
        a = swapPerson(a)
        guard !a.isEmpty, a.count <= 90 else { return "Yes, go ahead" }
        if a.lowercased() == "go ahead" || a.lowercased() == "proceed" || a.lowercased() == "do that"
            || a.lowercased() == "do it" { return "Yes, go ahead" }
        if choice { return capitalizedFirst(a) }
        return lead + lowercasedFirst(a)
    }

    /// The agent's "you/your" is the user's "me/my", and the other way round.
    private static func swapPerson(_ s: String) -> String {
        let map = ["you": "me", "your": "my", "yours": "mine", "yourself": "myself",
                   "me": "you", "my": "your", "mine": "yours", "myself": "yourself", "i": "you",
                   "i'll": "you'll", "i've": "you've", "i'm": "you're", "we": "we"]
        var out: [String] = []
        for word in s.split(separator: " ", omittingEmptySubsequences: false) {
            let w = String(word)
            let core = w.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’")))
            let key = core.lowercased().replacingOccurrences(of: "’", with: "'")
            if let rep = map[key], let r = w.range(of: core) {
                out.append(w.replacingCharacters(in: r, with: rep))
            } else {
                out.append(w)
            }
        }
        return out.joined(separator: " ")
    }

    private static func lowercasedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        // Keep acronyms and names that are ALL CAPS ("PR", "API").
        let second = s.dropFirst().first
        if let second, second.isUppercase { return s }
        return f.lowercased() + s.dropFirst()
    }

    private static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private static func flatten(_ line: String) -> String {
        var s = line
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)  // links
        s = s.replacingOccurrences(of: #"[*_`~]+"#, with: "", options: .regularExpression)                // emphasis/code
        s = s.replacingOccurrences(of: #"^\s*(?:[#>]+|[-+•]|\d+[.)])\s+"#, with: "", options: .regularExpression)  // headings, bullets
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func splitSentences(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            if ".!?".contains(c), i + 1 == chars.count || chars[i + 1] == " " {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// First capture group of a case-insensitive regex, or nil.
    private static func first(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
