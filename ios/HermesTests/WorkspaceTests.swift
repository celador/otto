import Foundation
import Testing
@testable import Hermes

@Suite struct WorkspaceTests {
    @Test func decodesRelayWorkspaceList() throws {
        let json = """
        {"workspaces": [{"id": "p_b68a028b", "slug": "otto", "name": "Otto", "description": null, "icon": "device-mobile",
          "color": "hsl(30 68% 58%)", "board_slug": "otto", "primary_path": "/Users/sam/code/hermes-ios", "archived": false,
          "created_at": 1, "folders": [{"path": "/Users/sam/code/hermes-ios", "label": null, "is_primary": true, "added_at": 1}],
          "session_count": 2, "last_active": 1791914705.5, "session_ids": ["a", "b"],
          "recent": [{"id": "b", "title": "Fix it", "preview": "hi", "source": "api_server", "started_at": 1.0,
                      "last_active": 2.0, "message_count": 4, "model": "m", "archived": false, "cwd": "/x", "git_branch": null}]}]}
        """
        let list = try HermesClient.decoder.decode(WorkspaceList.self, from: Data(json.utf8)).workspaces
        let w = try #require(list.first)
        #expect(w.boardSlug == "otto" && w.sessionIds == ["a", "b"] && w.sessionCount == 2)
        #expect(w.folder == "/Users/sam/code/hermes-ios")
        #expect(w.shortFolder == "~/code/hermes-ios")
        #expect(w.recent?.first?.summary.displayTitle == "Fix it")
    }

    @Test func iconsAreTheDesktopCodiconsDrawnAsSymbols() {
        #expect(WorkspaceLook.symbol("device-mobile") == "iphone")
        #expect(WorkspaceLook.symbol(nil) == "folder")
        #expect(WorkspaceLook.symbol("hammer.fill") == "hammer.fill")   // an SF Symbol typed by hand
        #expect(WorkspaceLook.symbol("🦦") == nil)                     // emoji: drawn as text
        #expect(WorkspaceLook.icons.count == 28)
        #expect(WorkspaceLook.swatches.first == "hsl(0 68% 58%)" && WorkspaceLook.swatches.count == 12)
    }

    @Test func colorsParseHexAndHsl() {
        #expect(WorkspaceLook.color("#f97316") != nil)
        #expect(WorkspaceLook.color("hsl(210 68% 58%)") != nil)
        #expect(WorkspaceLook.color("red") == nil)
        #expect(WorkspaceLook.color(nil) == nil)
    }

    @Test func slugsDropAccents() {
        #expect(WorkspaceLook.slug("Fícha") == "ficha")
        #expect(WorkspaceLook.slug("à La Barra") == "a-la-barra")
        #expect(WorkspaceLook.slug("Story Grove!") == "story-grove")
    }

    @Test func workspaceScreenRoundTripsAndMessagingIsGone() {
        #expect(Screen.from(storageKey: "workspace:p_1234abcd") == .workspace("p_1234abcd"))
        #expect(Screen.workspace("p_1234abcd").storageKey == "workspace:p_1234abcd")
        #expect(Screen.from(storageKey: "messaging") == nil)
    }

    @Test func draftJSONCarriesBoardChoice() {
        var d = WorkspaceDraft()
        d.name = " Otto "
        d.path = "~/code/hermes-ios"
        d.boardSlug = "otto"
        d.createBoard = true
        let j = d.json
        #expect(j["name"] as? String == "Otto")
        #expect(j["create_board"] as? Bool == true)
        #expect(j["board_slug"] as? String == "otto")
    }
}

@MainActor
struct WorkspaceOrderTests {
    private func ws(_ id: String, archived: Bool = false) -> Workspace {
        Workspace(id: id, slug: nil, name: id, description: nil, icon: nil, color: nil, boardSlug: nil,
                  primaryPath: nil, archived: archived, folders: nil, sessionCount: nil, lastActive: nil,
                  sessionIds: nil, recent: nil)
    }

    @Test func orderedKeepsDraggedOrderNewOnTopArchivedLast() {
        let list = [ws("a"), ws("b"), ws("z", archived: true), ws("c"), ws("new")]
        let out = WorkspaceStore.ordered(list, by: ["c", "a", "b"]).map(\.id)
        #expect(out == ["new", "c", "a", "b", "z"])
    }
}

/// Opening a workspace draws its chats on the first frame: no network, no spinner.
@MainActor
struct WorkspaceInstantChatsTests {
    private func summary(_ id: String, _ title: String, active: Double) -> SessionSummary {
        SessionSummary(id: id, source: "api_server", title: title, preview: nil, model: nil, startedAt: active,
                       lastActive: active, messageCount: 2, pinned: nil, archived: nil)
    }

    private func ws(_ id: String, ids: [String], recent: [WorkspaceSession] = [], count: Int? = nil) -> Workspace {
        Workspace(id: id, slug: nil, name: id, description: nil, icon: nil, color: nil, boardSlug: nil,
                  primaryPath: "/tmp/\(id)", archived: false, folders: nil, sessionCount: count ?? ids.count,
                  lastActive: nil, sessionIds: ids, recent: recent)
    }

    @Test func derivesRowsFromKnownMembersWithoutCache() {
        let known = [summary("a", "Alpha", active: 10), summary("b", "Beta", active: 30), summary("x", "Elsewhere", active: 99)]
        let w = ws("p_1", ids: ["a", "b", "gone"])
        let rows = WorkspaceSessionCache.rows(for: "p_1", workspace: w, cached: nil, known: known)
        #expect(rows.map(\.id) == ["b", "a"])          // members only, newest first like the relay
        #expect(rows.first?.title == "Beta")
    }

    @Test func recentRowsCoverChatsMissingFromTheMainList() {
        let recent = [WorkspaceSession(id: "old", title: "Old one", preview: nil, source: nil, startedAt: 1,
                                       lastActive: 5, messageCount: 1, model: nil, archived: false)]
        let rows = WorkspaceSessionCache.rows(for: "p_1", workspace: ws("p_1", ids: ["old"], recent: recent),
                                              cached: nil, known: [])
        #expect(rows.map(\.id) == ["old"])
    }

    @Test func cacheWinsAndPendingMovesApply() {
        let cached = [WorkspaceSession(summary("a", "Alpha", active: 10)), WorkspaceSession(summary("b", "Beta", active: 20))]
        let known = [summary("a", "Alpha renamed", active: 40), summary("n", "Moved in", active: 50)]
        let rows = WorkspaceSessionCache.rows(for: "p_1", workspace: ws("p_1", ids: []), cached: cached, known: known,
                                              pending: ["b": .some("p_2"), "n": .some("p_1")])
        #expect(rows.map(\.id) == ["n", "a"])
        #expect(rows.last?.title == "Alpha renamed")
    }

    @Test func storeAnswersSynchronouslyForAnyWorkspace() {
        // Non-optional and immediate: the view never has a "not loaded yet" state to draw a spinner for.
        let rows: [WorkspaceSession] = WorkspaceStore.shared.sessions(for: "p_never_seen")
        #expect(rows.isEmpty)
    }

    @Test func cacheRoundTripsToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ["p_1": [WorkspaceSession(summary("a", "Alpha", active: 10))], "p_2": []]
        WorkspaceSessionCache.save(cache, to: url)
        let back = WorkspaceSessionCache.load(from: url)
        #expect(back == cache)
        #expect(WorkspaceSessionCache.load(from: url.appendingPathExtension("missing")).isEmpty)
    }
}
