import AppKit
import SwiftUI

// Mac look, modelled on the Hermes desktop app: warm off-white surfaces, hairline warm
// borders, orange accent, dense 13pt sidebar rows, quiet tool activity.

enum MacPalette {
    private static func pair(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? c(dark) : c(light) })
    }

    static var sidebar: Color { pair(0xF6F5F3, 0x191817) }
    static var selection: Color { pair(0xEEE8E2, 0x302B27) }
    static var hover: Color { pair(0xF0EDEA, 0x252321) }
    static var border: Color { pair(0xE6DDD5, 0x3A3532) }
    static var chip: Color { pair(0xEFEBE7, 0x2B2826) }
}

// MARK: - Friendly model names ("claude-opus-5-5" → "Opus 5.5")

enum ModelNames {
    static func friendly(_ raw: String) -> String {
        var id = raw.split(separator: "/").last.map(String.init) ?? raw
        id = id.replacingOccurrences(of: ":", with: "-")
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        var parts = id.split(separator: "-").map(String.init)
        // Drop date pins (20251101) and "latest".
        parts.removeAll { ($0.count == 8 && Int($0) != nil) || $0 == "latest" }
        var words: [String] = []
        for p in parts {
            let isNumber = p.allSatisfy { $0.isNumber || $0 == "." }
            if isNumber, let last = words.last, last.last?.isNumber == true, !last.contains(" "), p.count <= 2 {
                words[words.count - 1] = last + "." + p
            } else if isNumber {
                words.append(p)
            } else if p.lowercased() == "gpt" {
                words.append("GPT")
            } else if p.count <= 2 {
                words.append(p.uppercased())
            } else {
                words.append(p.prefix(1).uppercased() + p.dropFirst())
            }
        }
        let name = words.joined(separator: " ")
        return name.isEmpty ? raw : name
    }
}

// MARK: - Transcript grouping (consecutive tool calls → one quiet "Ran 3 commands ›" row)

enum MacTranscript: Identifiable {
    case row(ChatRow)
    case tools(id: String, [ToolActivity])

    var id: String {
        switch self {
        case .row(let r): r.id
        case .tools(let id, _): "tools-" + id
        }
    }

    static func group(_ rows: [ChatRow]) -> [MacTranscript] {
        var out: [MacTranscript] = []
        var run: [ToolActivity] = []
        func flush() {
            guard let first = run.first else { return }
            out.append(.tools(id: first.id, run))
            run = []
        }
        for row in rows {
            if case .item(.tool(let t)) = row { run.append(t); continue }
            flush()
            out.append(.row(row))
        }
        flush()
        return out
    }
}

struct MacToolGroup: View {
    let tools: [ToolActivity]
    @State private var expanded = false
    @State private var hovering = false

    private var running: ToolActivity? { tools.last { $0.state == .running } }
    private var failed: Int { tools.filter { $0.state == .failed }.count }

    private var summary: String {
        if let running { return ToolInfo.info(running.name).doing }
        let commands = tools.filter { ToolInfo.info($0.name).title == "Terminal" }.count
        let n = tools.count
        let base: String
        if commands == n {
            base = n == 1 ? "Ran a command" : "Ran \(n) commands"
        } else if n == 1 {
            base = ToolInfo.info(tools[0].name).title
        } else {
            base = "Used \(n) tools"
        }
        return failed > 0 ? base + " · \(failed) failed" : base
    }

    private var single: ToolActivity? { tools.count == 1 ? tools[0] : nil }

    var body: some View {
        if let single {
            // One call: show it directly (its own row expands to the details).
            ToolRow(tool: single)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if running != nil {
                            ProgressView().controlSize(.mini).frame(width: 14)
                        }
                        Text(summary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(hovering || expanded ? 1 : 0.6)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(failed > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tools, id: \.id) { ToolRow(tool: $0) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(MacPalette.border).frame(width: 1)
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - Sidebar bits

// RelativeShort and SessionDot live in ios/Hermes/Views/SidebarBits.swift (shared with iOS).

struct SidebarRow<Leading: View>: View {
    let title: String
    let selected: Bool
    var trailing: String? = nil
    var trailingKeys: [String] = []
    @ViewBuilder let leading: () -> Leading
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading().frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(trailingKeys, id: \.self) { k in
                    Text(k)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(MacPalette.chip, in: RoundedRectangle(cornerRadius: 4))
                        .opacity(hovering ? 1 : 0.7)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? MacPalette.selection : hovering ? MacPalette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

struct SidebarHeader: View {
    let title: String
    var icon: String? = nil
    var accent = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.2)
        }
        .foregroundStyle(accent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
