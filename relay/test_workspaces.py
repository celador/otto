import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import companion  # noqa: E402
import slash_bridge  # noqa: E402
import workspaces  # noqa: E402

PROJECT = {"id": "p_abcd1234", "slug": "otto", "name": "Otto", "icon": "🛠", "color": "#f97316",
           "board_slug": "otto", "primary_path": "/tmp", "archived": False, "created_at": 1,
           "folders": [{"path": "/tmp", "label": None, "is_primary": True, "added_at": 1}]}


class FakeHermes:
    """Stands in for the dashboard: answers RPC batches and kanban HTTP calls, records both."""

    def __init__(self, boards=("ficha",)):
        self.calls: list[dict] = []
        self.http: list[tuple] = []
        self.boards = [{"slug": b} for b in boards]

    def rpc(self, calls):
        out = []
        for c in calls:
            self.calls.append(c)
            m, p = c["method"], c["params"]
            if m == "projects.list":
                out.append({"result": {"projects": [PROJECT, {**PROJECT, "id": "p_00000002", "name": "Old",
                                                               "archived": True}], "active_id": None}})
            elif m == "projects.tree":
                out.append({"result": {"projects": [
                    {"id": "p_abcd1234", "sessionCount": 2, "lastActive": 50.0, "sessionIds": ["s1", "s2"],
                     "previewSessions": [{"id": "s2", "title": "b", "last_active": 50.0, "system_prompt": "x"}]},
                    {"id": "__no_project__", "sessionCount": 9, "sessionIds": ["s9"]}]}})
            elif m == "projects.get":
                out.append({"result": {"project": PROJECT}} if p["id"] == PROJECT["id"]
                           else {"error": "no such project"})
            elif m == "projects.project_sessions":
                out.append({"result": {"project": {"repos": [{"groups": [
                    {"sessions": [{"id": "s1", "title": "a", "last_active": 10.0}]},
                    {"sessions": [{"id": "s2", "title": "b", "last_active": 50.0},
                                  {"id": "s1", "title": "a", "last_active": 10.0}]}]}]}}})
            elif m in ("projects.create", "projects.update", "projects.add_folder"):
                out.append({"result": {"project": {**PROJECT, **{k: v for k, v in p.items() if k != "folders"}}}})
            elif m == "session.workspace.move":
                out.append({"result": {"cwd": p["cwd"], "branch": "main", "git_repo_root": p["cwd"]}})
            elif m == "projects.discover_repos":
                out.append({"result": {"repos": [{"root": "/r/a", "label": "a", "sessions": 1, "last_active": 1.0},
                                                 {"root": "/r/b", "label": "b", "sessions": 3, "last_active": 9.0}]}})
            else:
                out.append({"result": {}})
        return out

    def dash(self, method, path, query=None, body=None):
        self.http.append((method, path, body))
        if method == "GET":
            return {"boards": self.boards}
        return {"board": body}


def make(fake=None, order_path=None):
    import tempfile
    fake = fake or FakeHermes()
    order_path = order_path or Path(tempfile.mkdtemp()) / "order.json"  # never John's real file
    return workspaces.Workspaces(fake.rpc, fake.dash, order_path), fake


def test_dragged_order_is_kept_and_new_workspaces_go_on_top(tmp_path):
    w, _ = make(order_path=tmp_path / "otto" / "order.json")
    rows = [{"id": "p_0000000a", "last_active": 1}, {"id": "p_0000000b", "last_active": 9},
            {"id": "p_0000000c", "last_active": 5}, {"id": "p_0000000d", "archived": True}]
    assert w.handle("PUT", "/workspaces/order", {}, {"ids": ["p_0000000a", "p_0000000c", "p_0000000b", "p_0000000a"]}) \
        == {"ok": True, "ids": ["p_0000000a", "p_0000000c", "p_0000000b"]}
    w.sort_rows(rows)
    assert [r["id"] for r in rows] == ["p_0000000a", "p_0000000c", "p_0000000b", "p_0000000d"]
    rows.append({"id": "p_0000000e", "last_active": 0})
    w.sort_rows(rows)
    assert rows[0]["id"] == "p_0000000e"
    with pytest.raises(workspaces.WorkspaceError):
        w.handle("PUT", "/workspaces/order", {}, {"ids": ["../etc"]})
    with pytest.raises(workspaces.WorkspaceError):
        w.handle("POST", "/workspaces/order", {}, {"ids": []})


def test_list_merges_projects_with_tree_counts_and_recent_chats():
    w, fake = make()
    data = w.handle("GET", "/workspaces", {}, {})
    first, second = data["workspaces"]
    assert first["id"] == "p_abcd1234" and first["session_count"] == 2 and first["session_ids"] == ["s1", "s2"]
    assert first["board_slug"] == "otto" and first["primary_path"] == "/tmp"
    assert first["recent"][0]["id"] == "s2" and "system_prompt" not in first["recent"][0]
    assert second["archived"] is True and second["session_count"] == 0  # archived sorts last
    assert [c["method"] for c in fake.calls] == ["projects.list", "projects.tree"]
    w.handle("GET", "/workspaces", {}, {})
    assert len(fake.calls) == 2  # cached for a few seconds
    w.handle("GET", "/workspaces", {"refresh": "1"}, {})
    assert len(fake.calls) == 4


def test_sessions_flattens_lanes_newest_first_without_duplicates():
    w, _ = make()
    rows = w.handle("GET", "/workspaces/p_abcd1234/sessions", {}, {})["sessions"]
    assert [r["id"] for r in rows] == ["s2", "s1"]


def test_create_validates_and_creates_project_and_new_board(tmp_path):
    w, fake = make()
    out = w.handle("POST", "/workspaces", {}, {"name": "Otto", "path": str(tmp_path), "icon": "🛠",
                                                "color": "hsl(30 68% 58%)", "create_board": True})
    create = next(c for c in fake.calls if c["method"] == "projects.create")
    real = os.path.realpath(tmp_path)
    assert create["params"]["folders"] == [real] and create["params"]["primary_path"] == real
    assert create["params"]["board_slug"] == "otto"
    assert ("POST", "/api/plugins/kanban/boards") == fake.http[-1][:2]
    assert fake.http[-1][2]["slug"] == "otto" and fake.http[-1][2]["project_id"] == "p_abcd1234"
    assert out["workspace"]["id"] == "p_abcd1234"


def test_create_never_touches_an_existing_board(tmp_path):
    w, fake = make(FakeHermes(boards=("ficha",)))
    w.handle("POST", "/workspaces", {}, {"name": "Fícha", "path": str(tmp_path), "board_slug": "ficha",
                                         "create_board": True})
    assert [h[0] for h in fake.http] == ["GET"]  # looked, found it, didn't POST/PATCH


@pytest.mark.parametrize("body,detail", [
    ({"path": "/tmp"}, "need a name"),
    ({"name": "x", "path": "/definitely/not/here"}, "folder doesn't exist"),
    ({"name": "x", "path": str(Path.home())}, "home folder"),
    ({"name": "x", "path": "/tmp", "color": "red; drop"}, "color"),
    ({"name": "x", "path": "/tmp", "color": "hsl(30 68% 58%); x"}, "color"),
    ({"name": "x", "path": "/tmp", "board_slug": "../etc"}, "bad board slug"),
    ({"name": "x" * 200, "path": "/tmp"}, "name must be text"),
])
def test_create_rejects_bad_input(body, detail):
    w, fake = make()
    with pytest.raises(workspaces.WorkspaceError) as e:
        w.handle("POST", "/workspaces", {}, body)
    assert e.value.status == 400 and detail in e.value.detail
    assert not any(c["method"] == "projects.create" for c in fake.calls)


def test_update_fields_folder_and_unknown_fields(tmp_path):
    w, fake = make()
    w.handle("PATCH", "/workspaces/p_abcd1234", {}, {"name": "Otto 2", "board_slug": "", "path": str(tmp_path)})
    methods = [c["method"] for c in fake.calls]
    assert methods == ["projects.get", "projects.update", "projects.add_folder"]
    assert fake.calls[1]["params"] == {"id": "p_abcd1234", "name": "Otto 2", "board_slug": ""}
    assert fake.calls[2]["params"]["is_primary"] is True
    with pytest.raises(workspaces.WorkspaceError) as e:
        w.handle("PATCH", "/workspaces/p_abcd1234", {}, {"slug": "x"})
    assert e.value.status == 400


def test_move_session_rehomes_into_primary_folder():
    w, fake = make()
    out = w.handle("POST", "/workspaces/p_abcd1234/move-session", {}, {"session_id": "api_1_ab"})
    move = fake.calls[-1]
    assert move == {"method": "session.workspace.move", "params": {"session_key": "api_1_ab", "cwd": "/tmp"}}
    assert out["cwd"] == "/tmp"
    w.handle("POST", "/workspaces/unassign-session", {}, {"session_id": "api_1_ab"})
    assert fake.calls[-1]["params"]["cwd"] == str(Path.home())
    with pytest.raises(workspaces.WorkspaceError):
        w.handle("POST", "/workspaces/p_abcd1234/move-session", {}, {"session_id": "../x y"})


def test_archive_and_restore():
    w, fake = make()
    assert w.handle("POST", "/workspaces/p_abcd1234/archive", {}, {})["archived"] is True
    assert fake.calls[-1]["params"] == {"id": "p_abcd1234", "restore": False}
    w.handle("POST", "/workspaces/p_abcd1234/archive", {}, {"restore": True})
    assert fake.calls[-1]["params"]["restore"] is True


def test_ids_methods_and_unknown_projects():
    w, _ = make()
    with pytest.raises(workspaces.WorkspaceError) as e:
        w.handle("GET", "/workspaces/../../etc", {}, {})
    assert e.value.status in (400, 404)
    with pytest.raises(workspaces.WorkspaceError) as e:
        w.handle("DELETE", "/workspaces/p_abcd1234", {}, {})
    assert e.value.status == 405
    with pytest.raises(workspaces.WorkspaceError) as e:
        w.handle("GET", "/workspaces/p_ffffffff/sessions", {}, {})
    assert e.value.status == 404


def test_folders_sorted_by_recent_activity():
    w, fake = make()
    out = w.handle("GET", "/workspaces/folders", {}, {})
    assert [f["path"] for f in out["folders"]] == ["/r/b", "/r/a"]
    assert fake.calls[-1]["params"] == {"scan": True}


def test_companion_mounts_workspaces_through_the_rpc_bridge():
    c = companion.Companion("http://127.0.0.1:1", lambda: "tok")
    sent = []
    fake = FakeHermes()
    c._bridge = lambda req, timeout: sent.append(req) or {"results": fake.rpc(req["calls"])}
    data = c.handle("GET", "/workspaces", {}, {})
    assert data["workspaces"][0]["name"] == "Otto"
    assert sent[0]["op"] == "rpc" and [x["method"] for x in sent[0]["calls"]] == ["projects.list", "projects.tree"]
    with pytest.raises(companion.RouteError) as e:
        c.handle("GET", "/workspaces/p_ffffffff", {}, {})
    assert e.value.status == 404
    c._bridge = lambda req, timeout: {"kind": "error", "text": "Dashboard token missing on the Mac."}
    c._workspaces = None
    with pytest.raises(companion.RouteError) as e:
        c.handle("GET", "/workspaces", {"refresh": "1"}, {})
    assert e.value.status == 502


def test_bridge_rpc_allowlist():
    assert "projects.delete" not in slash_bridge.RPC_ALLOWED
    assert "session.delete" not in slash_bridge.RPC_ALLOWED
    assert {"projects.create", "session.workspace.move"} <= slash_bridge.RPC_ALLOWED


def test_slugify_keeps_accented_letters():
    assert workspaces.slugify("Fícha") == "ficha"
    assert workspaces.slugify("à La Barra") == "a-la-barra"
    assert workspaces.slugify("  ") == "workspace"
