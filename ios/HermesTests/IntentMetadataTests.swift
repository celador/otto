import Foundation
import Testing

/// App Store Connect rejects uploads whose App Intent metadata names Apple devices (ITMS-90626:
/// "App Intent descriptions cannot contain 'iPhone'"). Build 72 was rejected for this. This test scans
/// every Swift source under ios/ for intent and shortcut text (descriptions, titles, Siri phrases,
/// short titles, parameter titles, dialogs, widget descriptions) and fails if any names a device.
struct IntentMetadataTests {
    /// Words Apple refuses in App Intent metadata. Lowercased; matched case-insensitively.
    static let banned = ["iphone", "ipad", "ipod", "apple watch", "macbook"]

    /// Line markers for text that ends up in the App Intents metadata (or the widget gallery).
    static let markers = [
        "IntentDescription(", "static var title", "shortTitle:", "phrases:", "@Parameter(",
        "IntentDialog(", ".description(\"", ".configurationDisplayName(\"", "DisplayRepresentation(",
        "TypeDisplayRepresentation(", "caseDisplayRepresentations",
    ]

    static var iosRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Returns "file:line: text" for every offending metadata line in the ios/ tree.
    static func offenders() throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: iosRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.path.contains("/HermesTests/") || url.path.contains("/HermesUITests/") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("AppIntent") || text.contains("WidgetKit") || text.contains("AppShortcut") else { continue }
            var inPhrases = false
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                if line.contains("phrases:") { inPhrases = !line.contains("]") }
                else if inPhrases && line.hasPrefix("]") { inPhrases = false }
                let isMetadata = inPhrases || markers.contains { line.contains($0) }
                guard isMetadata else { continue }
                // Only quoted literals count, not identifiers.
                let literals = line.split(separator: "\"", omittingEmptySubsequences: false)
                    .enumerated().filter { $0.offset % 2 == 1 }.map { $0.element.lowercased() }
                if literals.contains(where: { lit in banned.contains { lit.contains($0) } }) {
                    out.append("\(url.lastPathComponent):\(i + 1): \(line)")
                }
            }
        }
        return out
    }

    @Test func sourcesAreReachable() {
        #expect(FileManager.default.fileExists(atPath: Self.iosRoot.appendingPathComponent("Shared/HandsFreeIntents.swift").path))
    }

    @Test func intentMetadataNamesNoDevice() throws {
        let bad = try Self.offenders()
        #expect(bad.isEmpty, "App Intent text must not name a device (ITMS-90626):\n\(bad.joined(separator: "\n"))")
    }
}
