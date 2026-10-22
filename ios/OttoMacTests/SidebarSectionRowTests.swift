import Foundation
import Testing
@testable import Otto

/// A chat shown in two sidebar sections (pinned + its expanded workspace) must get two distinct
/// row ids; with one shared id the lazy stack reused the indented workspace row for the pinned one.
struct SidebarSectionRowTests {
    private struct Chat: Identifiable { let id: String }

    @Test func sameChatInTwoSectionsGetsDistinctIDs() {
        let chats = [Chat(id: "a"), Chat(id: "b")]
        let pinned = SidebarSectionRow.rows(chats, section: "pinned")
        let expanded = SidebarSectionRow.rows([Chat(id: "b")], section: "expanded.p_1")
        let all = (pinned + expanded).map(\.id)
        #expect(Set(all).count == all.count)
        #expect(pinned.map(\.item.id) == ["a", "b"])
        #expect(expanded.first?.item.id == "b")
    }

    @Test func keepsOrderAndSectionScope() {
        let rows = SidebarSectionRow.rows([Chat(id: "x"), Chat(id: "y")].prefix(5), section: "recents")
        #expect(rows.map(\.id) == ["recents/x", "recents/y"])
    }
}
