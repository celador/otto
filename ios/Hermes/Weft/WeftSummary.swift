import Foundation

/// The one-line summary a feed row shows, without the actor's name (the row already shows it).
///
/// Coordinators attach their own summary (spec §6.4, reference template in
/// weft `packages/protocol/src/summary.ts`), but that template names symbols, and for files the
/// analyzer doesn't parse (md, json, swift, py…) the only "symbol" is the whole-file key
/// `path#*`, so it reads "added * in weft-probe-2.md" or "released * (expired)". The log is
/// append-only, so the phone rebuilds those summaries from the record's structured fields.
enum WeftSummary {
    nonisolated static func render(_ e: WeftEvent) -> String {
        if let rebuilt = rebuild(e) { return rebuilt }
        return capitalized(dropActor(e.summary, who: e.who))
    }

    /// The full sentence with the actor ("hermes-default created weft-probe-2.md"), for the detail
    /// screen and Copy summary.
    nonisolated static func withActor(_ e: WeftEvent) -> String {
        guard var rebuilt = rebuild(e) else { return e.summary }
        var prefix = ""
        if rebuilt.hasPrefix("Blocked: ") { prefix = "Blocked: "; rebuilt.removeFirst(prefix.count) }
        let lower = rebuilt.hasPrefix("→") ? rebuilt : rebuilt.prefix(1).lowercased() + rebuilt.dropFirst()
        return prefix + e.who + " " + lower
    }

    /// nil when the coordinator's summary is already readable (no whole-file key involved).
    nonisolated static func rebuild(_ e: WeftEvent) -> String? {
        let blocked = e.summary.hasPrefix("Blocked: ") ? "Blocked: " : ""
        let why = reason(e.summary)
        let head: String
        switch e.kind {
        case "edit":
            guard e.writes.contains(where: { WeftSymbol.isWholeFile($0.key) }) else { return nil }
            head = editHead(e.writes)
        case "claim":
            guard e.writes.contains(where: { WeftSymbol.isWholeFile($0.key) }) else { return nil }
            let verb = e.payload?["source"]?.string == "predicted" ? "Is predicted to touch"
                : e.payload?["firm"]?.bool == true ? "Firmly claimed" : "Claimed"
            head = "\(verb) \(names(e.writes.map(\.key)))"
        case "release":
            let keys = e.payload?["keys"]?.array?.compactMap(\.string) ?? []
            guard keys.contains(where: WeftSymbol.isWholeFile) else { return nil }
            let what = keys.count == 1 ? "its claim on" : "its claims on"
            let r = e.payload?["reason"]?.string.map { " (\($0))" } ?? ""
            head = "Released \(what) \(names(keys))\(r)"
            return blocked + head   // the coordinator adds no reason to releases beyond the payload's
        case "land":
            guard e.writes.contains(where: { WeftSymbol.isWholeFile($0.key) }) else { return nil }
            head = "Landed \(e.change ?? "change") (\(landCount(e.writes)))"
        case "negotiate.propose":
            let keys = e.payload?["keys"]?.array?.compactMap(\.string) ?? []
            guard keys.contains(where: WeftSymbol.isWholeFile) else { return nil }
            let terms = e.payload?["terms"]?["kind"]?.string ?? "terms"
            let to = e.payload?["to"]?["agent"]?.string ?? e.payload?["to"]?["change"]?.string ?? "?"
            head = "→ \(to): proposes \(terms) on \(names(keys))"
        default:
            return nil
        }
        return blocked + head + (why.map { " — \($0)" } ?? "")
    }

    /// "edited *, added * in 43 files" → "Edited run-4.driver.log, created 1-work.prompt.txt +41 more".
    nonisolated static func editHead(_ writes: [WeftWrite]) -> String {
        let files = writes.filter { WeftSymbol.isWholeFile($0.key) }
        let symbols = writes.filter { !WeftSymbol.isWholeFile($0.key) }
        var parts: [String] = []
        // Whole files: say what happened to the file, by name.
        let edited = files.filter { $0.kind != "new" && $0.kind != "deleted" }.map(\.key)
        let created = files.filter { $0.kind == "new" }.map(\.key)
        let deleted = files.filter { $0.kind == "deleted" }.map(\.key)
        if !edited.isEmpty { parts.append("edited \(names(edited))") }
        if !created.isEmpty { parts.append("created \(names(created))") }
        if !deleted.isEmpty { parts.append("deleted \(names(deleted))") }
        // Parsed files keep the coordinator's symbol phrasing.
        if !symbols.isEmpty {
            let by = { (k: String) in symbols.filter { $0.kind == k }.map(\.key) }
            var sp: [String] = []
            if !by("signature").isEmpty { sp.append("changed signature of \(names(by("signature")))") }
            if !by("body").isEmpty { sp.append("edited \(names(by("body")))") }
            if !by("new").isEmpty { sp.append("added \(names(by("new")))") }
            if !by("deleted").isEmpty { sp.append("removed \(names(by("deleted")))") }
            let symFiles = unique(symbols.map { WeftSymbol.file($0.key) })
            let whereText = symFiles.count == 1 ? " in \(WeftSymbol.baseName(symFiles[0]))" : " in \(symFiles.count) files"
            parts.append(sp.joined(separator: ", ") + whereText)
        }
        return capitalized(parts.joined(separator: ", "))
    }

    /// "a.md", "a.md, b.json", "a.md, b.json +3 more" (files by base name, symbols by name).
    nonisolated static func names(_ keys: [String]) -> String {
        let shown = unique(keys.map(WeftSymbol.display))
        if shown.isEmpty { return "all claims" }
        if shown.count <= 2 { return shown.joined(separator: ", ") }
        return shown.prefix(2).joined(separator: ", ") + " +\(shown.count - 2) more"
    }

    nonisolated static func landCount(_ writes: [WeftWrite]) -> String {
        let files = unique(writes.filter { WeftSymbol.isWholeFile($0.key) }.map(\.key)).count
        let symbols = writes.count - writes.filter { WeftSymbol.isWholeFile($0.key) }.count
        var out: [String] = []
        if files > 0 { out.append(files == 1 ? "1 file" : "\(files) files") }
        if symbols > 0 { out.append(symbols == 1 ? "1 symbol" : "\(symbols) symbols") }
        return out.joined(separator: ", ")
    }

    /// The coordinator's " — <intent>" tail, if the summary kept one.
    nonisolated static func reason(_ summary: String) -> String? {
        guard let r = summary.range(of: " — ") else { return nil }
        let t = summary[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    nonisolated static func dropActor(_ summary: String, who: String) -> String {
        let prefix = who + " "
        return summary.hasPrefix(prefix) ? String(summary.dropFirst(prefix.count)) : summary
    }

    nonisolated static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    private nonisolated static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
