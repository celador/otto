"""Otto workspaces: Hermes projects (``~/.hermes/projects.db``) with their chats and kanban board.

Mounted by companion.py under /hermes/workspaces. Everything goes through the dashboard's own
JSON-RPC (projects.* and session.workspace.move, via slash_bridge's allowlisted "rpc" op) or its
kanban plugin API, so a workspace made in Otto is a project in the Hermes desktop too and a chat
moved here is re-homed in Hermes (its stored cwd changes) — no Otto-only store.

Routes (bearer-authenticated by the relay):
  GET   /workspaces                       projects + counts + 5 recent chats + every claimed session id
  POST  /workspaces                       {name, path, icon?, color?, description?, board_slug?, create_board?}
  GET   /workspaces/folders               folders to pick from (discovered repos + recent chat folders)
  POST  /workspaces/unassign-session      {session_id}: back to "Other chats" (cwd = home)
  GET   /workspaces/<id>                  one project
  PATCH /workspaces/<id>                  {name?, icon?, color?, description?, board_slug?, path?, create_board?}
  POST  /workspaces/<id>/archive          {restore?: bool}
  GET   /workspaces/<id>/sessions         the project's chats, newest first
  POST  /workspaces/<id>/move-session     {session_id}: re-home the chat into the project's folder
  PUT   /workspaces/order                 {ids: [...]}: the sidebar order John dragged (Otto-only, kept in
                                          ~/.hermes/otto/workspace-order.json; Hermes projects have no order)
"""
from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path
from typing import Any, Callable

PROJECT_ID = re.compile(r"p_[0-9a-f]{4,32}")
SESSION_ID = re.compile(r"[A-Za-z0-9_.:-]{1,128}")
BOARD_SLUG = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
# The desktop's swatches are "hsl(30 68% 58%)"; hex also accepted.
COLOR = re.compile(r"#[0-9A-Fa-f]{6}|hsl\(\d{1,3} \d{1,3}% \d{1,3}%\)")
SESSION_FIELDS = ("id", "title", "preview", "source", "started_at", "last_active", "message_count", "model",
                  "archived", "cwd", "git_branch")
PROJECT_FIELDS = ("id", "slug", "name", "description", "icon", "color", "board_slug", "primary_path", "archived",
                  "created_at", "folders")
TEXT_LIMITS = {"name": 80, "description": 500, "icon": 32}


class WorkspaceError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def slugify(name: str) -> str:
    """"Fícha" -> "ficha", "à La Barra" -> "a-la-barra" (Hermes' own slugify drops accented letters)."""
    import unicodedata
    plain = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-z0-9]+", "-", plain.lower()).strip("-")
    return s[:64] or "workspace"


def check_path(raw: Any) -> str:
    if not isinstance(raw, str) or not raw.strip() or len(raw) > 1024 or "\x00" in raw:
        raise WorkspaceError(400, "need a folder")
    path = os.path.realpath(os.path.expanduser(raw.strip()))
    if not os.path.isabs(path) or not os.path.isdir(path):
        raise WorkspaceError(400, f"folder doesn't exist: {raw.strip()}")
    if path in (os.sep, os.path.realpath(os.path.expanduser("~"))):
        raise WorkspaceError(400, "pick a project folder, not your home folder")
    return path


def clean_fields(body: dict[str, Any], *, creating: bool) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, limit in TEXT_LIMITS.items():
        if key in body and body[key] is not None:
            v = body[key]
            if not isinstance(v, str) or len(v) > limit:
                raise WorkspaceError(400, f"{key} must be text under {limit} chars")
            out[key] = v.strip()
    if creating and not out.get("name"):
        raise WorkspaceError(400, "need a name")
    if "name" in out and not out["name"]:
        raise WorkspaceError(400, "name can't be empty")
    if body.get("color") is not None:
        c = body["color"]
        if not isinstance(c, str) or (c and not COLOR.fullmatch(c)):
            raise WorkspaceError(400, "color must be #rrggbb or hsl(h s% l%)")
        out["color"] = c
    if body.get("board_slug") is not None:
        b = body["board_slug"]
        if not isinstance(b, str) or (b and not BOARD_SLUG.fullmatch(b)):
            raise WorkspaceError(400, "bad board slug")
        out["board_slug"] = b
    return out


def slim_session(row: dict) -> dict:
    return {k: row.get(k) for k in SESSION_FIELDS}


def slim_project(p: dict) -> dict:
    return {k: p.get(k) for k in PROJECT_FIELDS}


class Workspaces:
    """``rpc(calls) -> results`` runs dashboard RPCs (slash_bridge op "rpc"); ``dash(method, path, query,
    body)`` calls the dashboard's HTTP API (kanban plugin for boards)."""

    CACHE_SECONDS = 3.0

    def __init__(self, rpc: Callable[[list[dict]], list[dict]], dash: Callable[..., Any],
                 order_path: Path | None = None):
        self._rpc = rpc
        self.dash = dash
        self._cache: tuple[float, dict] | None = None
        self.order_path = order_path or Path(os.environ.get("HERMES_HOME_ROOT", Path.home() / ".hermes")) \
            / "otto" / "workspace-order.json"

    # --- sidebar order ----------------------------------------------------------

    def order(self) -> list[str]:
        try:
            ids = json.loads(self.order_path.read_text()).get("ids") or []
            return [i for i in ids if isinstance(i, str) and PROJECT_ID.fullmatch(i)]
        except (OSError, ValueError, AttributeError):
            return []

    def set_order(self, ids: Any) -> dict:
        if not isinstance(ids, list) or len(ids) > 500 or not all(
                isinstance(i, str) and PROJECT_ID.fullmatch(i) for i in ids):
            raise WorkspaceError(400, "need ids: a list of workspace ids")
        seen: list[str] = []
        for i in ids:
            if i not in seen:
                seen.append(i)
        self.order_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.order_path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"ids": seen, "updated_at": time.time()}))
        os.replace(tmp, self.order_path)
        self.invalidate()
        return {"ok": True, "ids": seen}

    def sort_rows(self, rows: list[dict]) -> None:
        """Archived last. Dragged order first-class; workspaces not in it yet (new ones) go on top,
        newest activity first, so a fresh workspace is never buried."""
        rank = {pid: n for n, pid in enumerate(self.order())}
        rows.sort(key=lambda w: (bool(w.get("archived")),
                                 w.get("id") in rank,
                                 rank.get(w.get("id"), 0),
                                 -(w.get("last_active") or 0),
                                 (w.get("name") or "").lower()))

    # --- plumbing -------------------------------------------------------------

    def call(self, method: str, params: dict | None = None) -> dict:
        res = self._rpc([{"method": method, "params": params or {}}])[0]
        if "error" in res:
            msg = str(res["error"])
            status = 404 if "no such project" in msg else 400 if any(
                w in msg for w in ("must", "already", "not exist", "required", "empty")) else 502
            raise WorkspaceError(status, msg)
        return res.get("result") or {}

    def project(self, pid: str) -> dict:
        if not PROJECT_ID.fullmatch(pid or ""):
            raise WorkspaceError(400, "bad workspace id")
        return self.call("projects.get", {"id": pid}).get("project") or {}

    @staticmethod
    def primary(project: dict) -> str:
        folders = project.get("folders") or []
        return project.get("primary_path") or next((f["path"] for f in folders if f.get("is_primary")), "") \
            or (folders[0]["path"] if folders else "")

    def invalidate(self) -> None:
        self._cache = None

    # --- reads ------------------------------------------------------------------

    def list(self, force: bool = False) -> dict:
        if not force and self._cache and time.time() - self._cache[0] < self.CACHE_SECONDS:
            return self._cache[1]
        listed, tree = self._rpc([
            {"method": "projects.list", "params": {}},
            {"method": "projects.tree", "params": {"preview_limit": 5, "session_limit": 3000}},
        ])
        if "error" in listed:
            raise WorkspaceError(502, str(listed["error"]))
        nodes = {n.get("id"): n for n in ((tree.get("result") or {}).get("projects") or [])}
        out = []
        for p in (listed.get("result") or {}).get("projects") or []:
            node = nodes.get(p.get("id")) or {}
            row = slim_project(p)
            row["primary_path"] = self.primary(p) or None
            row["session_count"] = int(node.get("sessionCount") or 0)
            row["last_active"] = node.get("lastActive") or None
            row["session_ids"] = list(node.get("sessionIds") or [])
            row["recent"] = [slim_session(s) for s in node.get("previewSessions") or []]
            out.append(row)
        self.sort_rows(out)
        data = {"workspaces": out}
        self._cache = (time.time(), data)
        return data

    def sessions(self, pid: str) -> dict:
        self.project(pid)  # 404 for an unknown id
        node = self.call("projects.project_sessions", {"project_id": pid}).get("project") or {}
        rows: dict[str, dict] = {}
        for repo in node.get("repos") or []:
            for lane in repo.get("groups") or []:
                for s in lane.get("sessions") or []:
                    if s.get("id"):
                        rows[s["id"]] = slim_session(s)
        ordered = sorted(rows.values(), key=lambda s: s.get("last_active") or s.get("started_at") or 0, reverse=True)
        return {"sessions": ordered}

    def folders(self) -> dict:
        repos = self.call("projects.discover_repos", {"scan": True}).get("repos") or []
        out = [{"path": r.get("root"), "label": r.get("label"), "sessions": r.get("sessions") or 0,
                "last_active": r.get("last_active") or None} for r in repos if r.get("root")]
        out.sort(key=lambda r: (-(r["last_active"] or 0), (r["label"] or "").lower()))
        return {"folders": out, "home": str(Path.home())}

    # --- writes -----------------------------------------------------------------

    def ensure_board(self, slug: str, name: str, project: dict) -> None:
        """Create the board if it doesn't exist (the dashboard's create is idempotent: an existing
        slug is returned untouched, so John's existing boards are never modified)."""
        boards = (self.dash("GET", "/api/plugins/kanban/boards") or {}).get("boards") or []
        if any(b.get("slug") == slug for b in boards):
            return
        self.dash("POST", "/api/plugins/kanban/boards", None, {
            # The project icon is a codicon name; boards show emoji, so the board gets none.
            "slug": slug, "name": name, "project_id": project.get("id")})

    def create(self, body: dict[str, Any]) -> dict:
        fields = clean_fields(body, creating=True)
        path = check_path(body.get("path"))
        if body.get("create_board") and not fields.get("board_slug"):
            fields["board_slug"] = slugify(fields["name"])
        params = {"name": fields["name"], "slug": slugify(fields["name"]), "folders": [path], "primary_path": path,
                  **{k: fields[k] for k in ("description", "icon", "color", "board_slug") if fields.get(k)}}
        project = self.call("projects.create", params).get("project") or {}
        if body.get("create_board") and project.get("id"):
            self.ensure_board(fields["board_slug"], fields["name"], project)
        self.invalidate()
        return {"workspace": slim_project(project)}

    def update(self, pid: str, body: dict[str, Any]) -> dict:
        allowed = {"name", "icon", "color", "description", "board_slug", "path", "create_board"}
        extra = set(body) - allowed
        if extra:
            raise WorkspaceError(400, f"fields not allowed: {', '.join(sorted(extra))}")
        current = self.project(pid)
        fields = clean_fields(body, creating=False)
        if body.get("create_board") and not fields.get("board_slug"):
            fields["board_slug"] = current.get("board_slug") or slugify(fields.get("name") or current.get("name") or "")
        project = current
        if fields:
            project = self.call("projects.update", {"id": pid, **fields}).get("project") or project
        if body.get("path") is not None:
            path = check_path(body["path"])
            project = self.call("projects.add_folder", {"id": pid, "path": path, "is_primary": True}).get("project") \
                or project
        if body.get("create_board") and project.get("board_slug"):
            self.ensure_board(project["board_slug"], project.get("name") or project["board_slug"], project)
        self.invalidate()
        return {"workspace": slim_project(project)}

    def archive(self, pid: str, restore: bool) -> dict:
        self.project(pid)
        self.call("projects.archive", {"id": pid, "restore": bool(restore)})
        self.invalidate()
        return {"ok": True, "archived": not restore}

    def move_session(self, pid: str, sid: str) -> dict:
        if not SESSION_ID.fullmatch(sid or ""):
            raise WorkspaceError(400, "need session_id")
        project = self.project(pid)
        cwd = self.primary(project)
        if not cwd:
            raise WorkspaceError(409, "this workspace has no folder yet")
        res = self.call("session.workspace.move", {"session_key": sid, "cwd": cwd})
        self.invalidate()
        return {"ok": True, "session_id": sid, "workspace_id": pid, "cwd": res.get("cwd") or cwd}

    def unassign_session(self, sid: str) -> dict:
        if not SESSION_ID.fullmatch(sid or ""):
            raise WorkspaceError(400, "need session_id")
        res = self.call("session.workspace.move", {"session_key": sid, "cwd": str(Path.home())})
        self.invalidate()
        return {"ok": True, "session_id": sid, "cwd": res.get("cwd")}

    # --- routing ------------------------------------------------------------------

    def handle(self, method: str, sub: str, query: dict[str, str], body: dict[str, Any]) -> Any:
        """``sub`` is the path after /hermes (starts with /workspaces)."""
        rest = sub[len("/workspaces"):]
        if rest in ("", "/"):
            if method == "GET":
                return self.list(force=query.get("refresh") == "1")
            if method == "POST":
                return self.create(body)
            raise WorkspaceError(405, "method not allowed")
        if rest == "/order":
            if method != "PUT":
                raise WorkspaceError(405, "method not allowed")
            return self.set_order(body.get("ids"))
        if rest == "/folders" and method == "GET":
            return self.folders()
        if rest == "/unassign-session" and method == "POST":
            return self.unassign_session(str(body.get("session_id") or ""))
        m = re.fullmatch(r"/([^/]+)(?:/(sessions|archive|move-session))?", rest)
        if not m:
            raise WorkspaceError(404, "not found")
        pid, action = m.groups()
        if not PROJECT_ID.fullmatch(pid):
            raise WorkspaceError(400, "bad workspace id")
        routes = {(None, "GET"): lambda: {"workspace": slim_project(self.project(pid))},
                  (None, "PATCH"): lambda: self.update(pid, body),
                  ("sessions", "GET"): lambda: self.sessions(pid),
                  ("archive", "POST"): lambda: self.archive(pid, bool(body.get("restore"))),
                  ("move-session", "POST"): lambda: self.move_session(pid, str(body.get("session_id") or ""))}
        fn = routes.get((action, method))
        if fn is None:
            raise WorkspaceError(405, "method not allowed")
        return fn()
