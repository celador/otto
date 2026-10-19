"""Artifacts index for the Hérmes iOS app: the same list as the desktop app's
Artifacts page (apps/desktop/src/app/artifacts/artifact-utils.ts).

The desktop scans the 30 most recent sessions (all profiles, >=1 message) and
pulls images, files and links out of assistant text and artifact-producing tool
results. The phone can't download tens of MB of transcripts, so the relay does
the scan and returns a compact list. Per-session results are cached by
(message_count, last_active) so a refresh only rescans sessions that changed.

Local files are served back only if they are in the current index (no
arbitrary file reads), under a size cap.
"""
from __future__ import annotations

import json
import mimetypes
import os
import re
import threading
import time
from pathlib import Path
from typing import Any, Callable, Iterable
from urllib.parse import unquote, urlsplit

SESSION_LIMIT = 30
PAGE_SIZE = 100
MAX_FILE_BYTES = 25 * 1024 * 1024
INDEX_TTL = 60.0

MARKDOWN_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)\)")
MARKDOWN_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
URL_RE = re.compile(r"https?://[^\s<>\"')`]+")
PATH_RE = re.compile(r"(^|[\s(\"'`])((?:/|~[\\/]|\.\.?[\\/])[^\s\"'`<>]+(?:\.[a-z0-9]{1,8})?)", re.I)
IMAGE_EXT_RE = re.compile(r"\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$", re.I)
FILE_EXT_RE = re.compile(
    r"\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|xlsx?|docx?|pptx?|html|zip|tar|gz|avi|flac|m4a|mkv|mp3"
    r"|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$", re.I)
MEDIA_EXTS = ("png|jpg|jpeg|gif|webp|bmp|tiff|svg|mp4|mov|webm|mkv|avi|mp3|m4a|wav|ogg|opus|flac|aac|pdf|txt|md|csv"
              "|json|html|zip|docx?|xlsx?|pptx?")
MEDIA_TAG_RE = re.compile(
    r"[`\"']?MEDIA:\s*(`[^`\n]+`|\"[^\"\n]+\"|'[^'\n]+'|(?:~/|/)\S+?(?:[^\S\n]+\S+?)*?\.(?:" + MEDIA_EXTS
    + r")(?=[\s`\"'*_,;:)\]}]|MEDIA:|$)|[^\s`\"]+)[`\"']?", re.I)
SCREENSHOT_PATH_RE = re.compile(r"Screenshot path:\s*([^\r\n<>]+)", re.I)
PRODUCER_TOOL_RE = re.compile(
    r"(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)", re.I)
STRONG_KEY_RE = re.compile(
    r"^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)"
    r"|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$", re.I)
PRODUCER_KEY_RE = re.compile(
    r"^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?"
    r"|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path"
    r"|media(?:_(?:file|path|url))?|path)$", re.I)
SHELL_OUTPUT_KEY_RE = re.compile(r"^(?:output|stdout|path)$", re.I)
PIP_CACHE_RE = re.compile(r"/(?:\.cache/pip|library/caches/pip)/")
WHEEL_RE = re.compile(r"\.whl(?:\.metadata)?$")
INDEX_DIST_RE = re.compile(r"/packages/.+\.(?:tar\.gz|tar\.bz2|zip|egg)(?:\.metadata)?$")
UNTRUSTED_RE = re.compile(r"^<untrusted_tool_result\b[^>]*>\s*")


def _filter_path(value: str) -> str:
    if re.match(r"^(?:https?|file)://", value, re.I):
        try:
            return unquote(urlsplit(value).path).lower()
        except ValueError:
            pass
    return value.replace("\\", "/").lower()


def _pip(value: str) -> bool:
    p = _filter_path(value)
    return bool(PIP_CACHE_RE.search(p) or WHEEL_RE.search(p)
                or (re.match(r"^https?://", value, re.I) and INDEX_DIST_RE.search(p)))


def is_file_path(value: str) -> bool:
    return bool(re.match(r"^(?:file:|/|[~.][\\/]|\.\.[\\/])", value, re.I))


def _path_or_url(value: str) -> bool:
    return value.startswith(("http://", "https://", "data:image/")) or is_file_path(value)


def looks_like_artifact(value: str, explicit: bool = False) -> bool:
    if not explicit and _pip(value):
        return False
    if re.match(r"^(?:https?://|data:image/)", value):
        return True
    if not _path_or_url(value):
        return False
    if explicit:
        return True
    return bool(IMAGE_EXT_RE.search(value) or FILE_EXT_RE.search(value))


def kind_of(value: str) -> str:
    if value.startswith("data:image/") or IMAGE_EXT_RE.search(value):
        return "image"
    if is_file_path(value):
        return "file"
    return "link"


def label_of(value: str) -> str:
    if re.match(r"^https?://", value):
        try:
            item = [p for p in urlsplit(value).path.split("/") if p]
            return item[-1] if item else value
        except ValueError:
            return value
    parts = [p for p in re.split(r"[\\/]", value) if p]
    return parts[-1] if parts else value


def _unquote(value: str) -> str:
    t = value.strip()
    if t and t[0] == t[-1] and t[0] in "\"'`" and len(t) > 1:
        return t[1:-1]
    return re.sub(r"[`\"'*_]{1,3}$", "", t)


def normalize(value: str) -> str:
    t = value.strip()
    for _ in range(3):
        if len(t) > 1 and t[0] == t[-1] and t[0] in "\"'`":
            t = t[1:-1].strip()
            continue
        break
    t = re.sub(r"[`*]+$", "", t)
    return re.sub(r"[),.;\\]+$", "", t)


def _decode_media_href(value: str) -> str:
    if value.startswith("#media:"):
        try:
            return unquote(value[len("#media:"):])
        except Exception:
            return value
    return value


Push = Callable[[str, bool], None]


def _media_values(text: str, push: Push) -> None:
    for m in MEDIA_TAG_RE.finditer(text):
        v = _unquote(m.group(1)).rstrip(".,;:!?")
        if "/" in v or "\\" in v or re.search(r"\.[^.]", v):
            push(v, True)


def collect_from_text(text: str, push: Push) -> None:
    _media_values(text, push)
    for m in MARKDOWN_IMAGE_RE.finditer(text):
        push(m.group(2) or "", False)
    for m in MARKDOWN_LINK_RE.finditer(text):
        if m.start() > 0 and text[m.start() - 1] == "!":
            continue
        v = _decode_media_href(m.group(2) or "")
        if looks_like_artifact(v):
            push(v, False)
    for m in URL_RE.finditer(text):
        if looks_like_artifact(m.group(0)):
            push(m.group(0), False)
    for m in PATH_RE.finditer(text):
        push(m.group(2) or "", False)


def _payloads(text: str) -> list[Any]:
    out: list[Any] = []
    cands = [text]
    t = text.strip()
    om = UNTRUSTED_RE.match(t)
    if om:
        close = t.rfind("</untrusted_tool_result>")
        if close > om.end():
            wrapped = t[om.end():close].strip()
            i = wrapped.find("\n\n")
            cands.append((wrapped if i == -1 else wrapped[i + 2:]).strip())
    for c in cands:
        if c and c.strip():
            try:
                out.append(json.loads(c))
            except (json.JSONDecodeError, ValueError):
                pass
    return out


def _strings(value: Any, key_path: str, fn: Callable[[str, str], None]) -> None:
    if isinstance(value, str):
        fn(value, key_path)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            _strings(v, f"{key_path}.{i}", fn)
    elif isinstance(value, dict):
        for k, v in value.items():
            _strings(v, f"{key_path}.{k}" if key_path else str(k), fn)


def _text(msg: dict[str, Any]) -> str:
    for k in ("content", "text", "context"):
        v = msg.get(k)
        if isinstance(v, str) and v.strip():
            return v
    return ""


def collect_from_message(msg: dict[str, Any], push: Push) -> None:
    text = _text(msg)
    role = msg.get("role")
    if role == "assistant":
        if text:
            collect_from_text(text, push)
        return
    if role != "tool":
        return
    name = str(msg.get("tool_name") or msg.get("name") or "").strip().lower()
    producer = bool(PRODUCER_TOOL_RE.search(name)) or name.startswith("bfl_flux3_")
    terminal = name == "terminal"
    payloads = _payloads(text)
    # JSON tool results are walked key by key below; scanning their raw text as prose
    # picks up JSON-escaped fragments ("\\n/path") as fake paths.
    if text and (producer or terminal) and not payloads:
        collect_from_text(text, push)
    if name == "browser_vision" and text:
        for m in SCREENSHOT_PATH_RE.finditer(text):
            push(m.group(1) or "", False)
    content = msg.get("content")
    if isinstance(content, dict):
        payloads.append(content.get("meta") if content.get("_multimodal") is True else content)
    elif isinstance(content, list):
        payloads.append(content)

    def visit(value: str, key_path: str) -> None:
        segs = [s for s in key_path.split(".") if s and not s.isdigit()]
        shell = terminal and any(SHELL_OUTPUT_KEY_RE.match(s) for s in segs)
        explicit_key = any(STRONG_KEY_RE.match(s) or (producer and PRODUCER_KEY_RE.match(s)) for s in segs)
        if not shell and not explicit_key:
            return
        if shell:
            if value:
                collect_from_text(value, push)
            return
        _media_values(value, push)
        n = normalize(_decode_media_href(value))
        if n and looks_like_artifact(n):
            push(n, False)

    for p in payloads:
        if p is not None:
            _strings(p, "tool_result", visit)


def _ts(v: Any) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f <= 0:
        return None
    return f / 1000 if f > 10_000_000_000 else f


def collect_for_session(session: dict[str, Any], messages: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    title = (session.get("title") or "").strip() or (session.get("preview") or "").strip() or "Untitled session"
    sid = session["id"]
    for msg in messages:
        if msg.get("role") not in ("assistant", "tool"):
            continue
        ts = _ts(msg.get("timestamp")) or _ts(session.get("last_active")) or _ts(session.get("started_at")) or time.time()

        def push(cand: str, explicit: bool = False) -> None:
            value = normalize(_decode_media_href(cand))
            if not value or not looks_like_artifact(value, explicit):
                return
            if value.startswith("data:"):   # inline blobs are too big to list; the chat shows them
                return
            if any(ch in value for ch in "{}*"):   # code templates (http://{host}) and globs (share-*.png)
                return
            key = f"{sid}:{value}"
            if key in found:
                return
            found[key] = {"id": key, "kind": kind_of(value), "value": value, "label": label_of(value),
                          "session_id": sid, "profile": session.get("profile") or "default",
                          "session_title": title, "timestamp": ts}

        collect_from_message(msg, push)
    return list(found.values())


def local_path(value: str) -> Path | None:
    """The on-disk path for a file artifact (file:// URL, absolute or ~ path)."""
    if value.startswith("file:"):
        try:
            value = unquote(urlsplit(value).path)
        except ValueError:
            return None
    if value.startswith("~/"):
        return Path.home() / value[2:]
    if value.startswith("/"):
        return Path(value)
    return None   # relative paths belong to an unknown cwd


class ArtifactIndex:
    def __init__(self, dash: Callable[..., Any]):
        self.dash = dash
        self.lock = threading.Lock()
        self.per_session: dict[str, tuple[tuple[Any, Any], list[dict[str, Any]]]] = {}
        self.items: list[dict[str, Any]] = []
        self.built_at = 0.0
        self.failures = 0

    def build(self, force: bool = False) -> dict[str, Any]:
        with self.lock:
            if not force and self.items is not None and time.time() - self.built_at < INDEX_TTL and self.built_at:
                return self._result()
            data = self.dash("GET", "/api/profiles/sessions", {
                "limit": SESSION_LIMIT, "offset": 0, "min_messages": 1, "archived": "exclude",
                "order": "recent", "profile": "all"})
            sessions = (data or {}).get("sessions", [])[:SESSION_LIMIT]
            items: list[dict[str, Any]] = []
            failures = 0
            fresh: dict[str, tuple[tuple[Any, Any], list[dict[str, Any]]]] = {}
            for s in sessions:
                sid = s.get("id")
                if not sid:
                    continue
                stamp = (s.get("message_count"), s.get("last_active"))
                cached = self.per_session.get(sid)
                if cached and cached[0] == stamp:
                    fresh[sid] = cached
                    items.extend(cached[1])
                    continue
                try:
                    found = self._scan(s)
                except Exception:
                    failures += 1
                    if cached:
                        fresh[sid] = cached
                        items.extend(cached[1])
                    continue
                fresh[sid] = (stamp, found)
                items.extend(found)
            self.per_session = fresh
            items.sort(key=lambda a: a["timestamp"], reverse=True)
            self.items = items
            self.failures = failures
            self.built_at = time.time()
            return self._result()

    def _scan(self, session: dict[str, Any]) -> list[dict[str, Any]]:
        found: dict[str, dict[str, Any]] = {}
        offset = 0
        profile = session.get("profile") or "default"
        while True:
            page = self.dash("GET", f"/api/sessions/{session['id']}/messages", {
                "limit": PAGE_SIZE, "offset": offset, "order": "oldest", "include_compacted": "true",
                "profile": profile})
            msgs = (page or {}).get("messages", [])
            for a in collect_for_session(session, msgs):
                found.setdefault(a["id"], a)
            pag = (page or {}).get("pagination")
            if not pag or not msgs or len(msgs) < int(pag.get("limit") or PAGE_SIZE):
                break
            offset += len(msgs)
            if offset > 20_000:
                break
        return list(found.values())

    def _result(self) -> dict[str, Any]:
        out = []
        for a in self.items:
            row = dict(a)
            p = local_path(a["value"]) if a["kind"] != "link" else None
            if p is not None:
                try:
                    st = p.stat()
                    row["exists"] = p.is_file()
                    row["size"] = st.st_size
                except OSError:
                    row["exists"] = False
            out.append(row)
        return {"artifacts": out, "sessions_failed": self.failures, "indexed_at": self.built_at}

    def file(self, value: str) -> tuple[bytes, str, str]:
        """Bytes of an indexed local file. Only values in the current index are served."""
        with self.lock:
            known = any(a["value"] == value for a in self.items)
        if not known:
            self.build()
            with self.lock:
                known = any(a["value"] == value for a in self.items)
        if not known:
            raise PermissionError("not an indexed artifact")
        p = local_path(value)
        if p is None or not p.is_file():
            raise FileNotFoundError(value)
        size = p.stat().st_size
        if size > MAX_FILE_BYTES:
            raise ValueError(f"file is {size // (1024 * 1024)} MB; the limit is {MAX_FILE_BYTES // (1024 * 1024)} MB")
        mime = mimetypes.guess_type(p.name)[0] or "application/octet-stream"
        if p.suffix.lower() == ".md":
            mime = "text/markdown"
        return p.read_bytes(), mime, p.name
