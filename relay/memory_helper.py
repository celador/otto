"""Memory edits for the Hérmes companion relay.

Runs under the Hermes venv (so it uses Hermes's own MemoryStore: file locks,
char limits, threat scanning) with HERMES_HOME set to the target profile.
Reads one JSON request on stdin, writes one JSON result on stdout.

  {"op": "list"}
  {"op": "add", "target": "memory"|"user", "content": "..."}
  {"op": "replace", "target": ..., "old_text": "...", "content": "..."}
  {"op": "remove", "target": ..., "old_text": "..."}
"""
import json
import sys


def main() -> None:
    req = json.loads(sys.stdin.read() or "{}")
    from hermes_cli.config import load_config
    from tools.memory_tool_store import MemoryStore

    cfg = load_config().get("memory") or {}
    store = MemoryStore(int(cfg.get("memory_char_limit", 2200)), int(cfg.get("user_char_limit", 1375)))
    store.load_from_disk()
    op = req.get("op")
    target = req.get("target")
    if op != "list" and target not in ("memory", "user"):
        print(json.dumps({"success": False, "error": "target must be memory or user"}))
        return
    if op == "add":
        result = store.add(target, str(req.get("content", "")))
    elif op == "replace":
        result = store.replace(target, str(req.get("old_text", "")), str(req.get("content", "")))
    elif op == "remove":
        result = store.remove(target, str(req.get("old_text", "")))
    elif op == "list":
        result = {"success": True}
    else:
        result = {"success": False, "error": f"unknown op {op!r}"}
    if op != "list":
        store.load_from_disk()
    result["memory"] = list(store.memory_entries)
    result["user"] = list(store.user_entries)
    result["limits"] = {"memory": store.memory_char_limit, "user": store.user_char_limit}
    print(json.dumps(result, default=str))


if __name__ == "__main__":
    main()
