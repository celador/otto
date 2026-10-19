import SwiftUI

/// A unified diff, the way a code review tool shows it: monospaced, old/new line numbers,
/// added/removed lines tinted, light syntax colouring, scrolls sideways instead of wrapping.
struct WeftDiffView: View {
    let diff: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let lines = DiffParser.parse(diff)
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in row(line) }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.visible)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func row(_ l: DiffLine) -> some View {
        HStack(spacing: 0) {
            if l.kind == .fileHeader || l.kind == .hunk {
                Text(l.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(l.kind == .hunk ? Color.secondary : Color.primary)
                    .fontWeight(l.kind == .fileHeader ? .semibold : .regular)
                    .padding(.horizontal, 10)
                    .padding(.vertical, l.kind == .fileHeader ? 4 : 2)
            } else {
                gutter(l.oldNumber)
                gutter(l.newNumber)
                Text(l.marker)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(markerColor(l.kind))
                    .frame(width: 14)
                Text(SyntaxTint.attributed(l.text, dark: scheme == .dark))
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.trailing, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(l.kind))
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 30, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func markerColor(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: .green
        case .removed: .red
        default: .secondary
        }
    }

    private func background(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: Color.green.opacity(scheme == .dark ? 0.18 : 0.12)
        case .removed: Color.red.opacity(scheme == .dark ? 0.18 : 0.10)
        case .hunk: Color.primary.opacity(0.04)
        case .fileHeader: Color.primary.opacity(0.07)
        default: .clear
        }
    }
}

struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case fileHeader, hunk, added, removed, context, meta }
    var id: Int
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
    var marker: String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }
}

enum DiffParser {
    /// Parses a unified diff; file headers collapse to one "path" row, hunks keep their header.
    static func parse(_ diff: String) -> [DiffLine] {
        var out: [DiffLine] = []
        var oldN = 0, newN = 0
        var i = 0
        func add(_ kind: DiffLine.Kind, _ text: String, _ o: Int? = nil, _ n: Int? = nil) {
            out.append(DiffLine(id: i, kind: kind, text: text, oldNumber: o, newNumber: n)); i += 1
        }
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                let parts = line.split(separator: " ")
                let path = parts.last.map { String($0).replacingOccurrences(of: "b/", with: "", options: .anchored) } ?? line
                add(.fileHeader, path)
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("index ")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") {
                continue
            } else if line.hasPrefix("@@") {
                let (o, n) = hunkStarts(line)
                oldN = o; newN = n
                add(.hunk, line)
            } else if line.hasPrefix("+") {
                add(.added, String(line.dropFirst()), nil, newN); newN += 1
            } else if line.hasPrefix("-") {
                add(.removed, String(line.dropFirst()), oldN, nil); oldN += 1
            } else if line.hasPrefix("\\") {
                add(.meta, line)
            } else {
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                add(.context, text, oldN, newN); oldN += 1; newN += 1
            }
        }
        // A trailing newline yields an empty context row; drop it.
        if let last = out.last, last.kind == .context, last.text.isEmpty { out.removeLast() }
        return out
    }

    /// `@@ -10,3 +12,4 @@` → (10, 12).
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ p: Substring?) -> Int {
            guard let p else { return 0 }
            return Int(p.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start(parts.dropFirst().first), start(parts.dropFirst(2).first))
    }
}

/// Minimal syntax colouring for TS/JS/Swift/Python-ish code in diffs: keywords, types,
/// strings, numbers, comments. Good enough to read a change at a glance; not a parser.
enum SyntaxTint {
    static let keywords: Set<String> = [
        "export", "import", "from", "function", "async", "await", "return", "const", "let", "var", "if", "else",
        "for", "while", "of", "in", "new", "class", "interface", "type", "extends", "implements", "throw", "try",
        "catch", "finally", "default", "switch", "case", "break", "continue", "true", "false", "null", "undefined",
        "this", "self", "func", "struct", "enum", "guard", "def", "public", "private", "static", "readonly", "void",
        "typeof", "as", "is", "yield", "None", "True", "False",
    ]

    static func attributed(_ code: String, dark: Bool) -> AttributedString {
        let kw: Color = dark ? Color(red: 0.99, green: 0.37, blue: 0.64) : Color(red: 0.61, green: 0.14, blue: 0.58)
        let str: Color = dark ? Color(red: 0.99, green: 0.42, blue: 0.36) : Color(red: 0.77, green: 0.1, blue: 0.09)
        let num: Color = dark ? Color(red: 0.82, green: 0.75, blue: 0.5) : Color(red: 0.11, green: 0.0, blue: 0.81)
        let typ: Color = dark ? Color(red: 0.36, green: 0.85, blue: 1.0) : Color(red: 0.04, green: 0.31, blue: 0.47)
        let com: Color = .secondary

        var out = AttributedString()
        let chars = Array(code)
        var i = 0
        func emit(_ s: String, _ c: Color?) {
            var a = AttributedString(s)
            if let c { a.foregroundColor = c }
            out += a
        }
        while i < chars.count {
            let c = chars[i]
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                emit(String(chars[i...]), com); break
            }
            if c == "#", i == chars.firstIndex(where: { !$0.isWhitespace }) {
                emit(String(chars[i...]), com); break
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), str); i = j; continue
            }
            if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), num); i = j; continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" { j += 1 }
                let word = String(chars[i..<j])
                if keywords.contains(word) { emit(word, kw) }
                else if word.first?.isUppercase == true { emit(word, typ) }
                else { emit(word, nil) }
                i = j; continue
            }
            var j = i
            while j < chars.count, !(chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$"
                                     || chars[j] == "\"" || chars[j] == "'" || chars[j] == "`" || chars[j] == "/" || chars[j] == "#") { j += 1 }
            if j == i { j = i + 1 }
            emit(String(chars[i..<j]), nil); i = j
        }
        return out
    }
}
