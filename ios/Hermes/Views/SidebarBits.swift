import SwiftUI

// Shared by the Mac sidebar and the workspace chat lists on every platform.

enum RelativeShort {
    /// "now", "5m", "13h", "1d", "3w" like the Hermes sidebar.
    static func string(_ date: Date, now: Date = .now) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 86_400 * 14 { return "\(Int(s / 86_400))d" }
        if s < 86_400 * 60 { return "\(Int(s / (86_400 * 7)))w" }
        return "\(Int(s / (86_400 * 30)))mo"
    }
}

enum SessionDot {
    private static let colors: [Color] = [
        Color(red: 0.42, green: 0.80, blue: 0.82), Color(red: 0.50, green: 0.69, blue: 0.35),
        Color(red: 0.85, green: 0.60, blue: 0.35), Color(red: 0.36, green: 0.58, blue: 0.86),
        Color(red: 0.62, green: 0.45, blue: 0.85), Color(red: 0.86, green: 0.45, blue: 0.70),
        Color(red: 0.85, green: 0.38, blue: 0.36), Color(red: 0.86, green: 0.80, blue: 0.40),
    ]

    static func color(for id: String) -> Color {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return colors[Int(h % UInt32(colors.count))]
    }
}

/// A row in one sidebar section, identified by section + item id.
///
/// The sidebars are one LazyVStack, and a chat can show in two sections at once (pinned and in its
/// expanded workspace on Mac). Two rows with the same id in one lazy stack share a view, so the
/// pinned copy picked up the workspace copy's leading indent. Scoping every id by its section keeps
/// each row's identity, and its layout, its own.
struct SidebarSectionRow<Item>: Identifiable {
    let id: String
    let item: Item

    static func rows<S: Sequence>(_ items: S, section: String) -> [SidebarSectionRow<Item>]
    where S.Element == Item, Item: Identifiable, Item.ID == String {
        items.map { SidebarSectionRow(id: section + "/" + $0.id, item: $0) }
    }
}
