#!/bin/bash
# One-time setup for Otto's ChatGPT voice engine (relay/chatgpt_live*.py).
# - venv with aiortc/websockets/numpy at ~/.hermes/chatgpt-live/venv (the bridge's python)
# - tailnet HTTPS 8657 → bridge 127.0.0.1:8656
# Needs the Codex CLI signed in with ChatGPT (`codex login`). No OpenAI API key is used.
set -euo pipefail
DIR="$HOME/.hermes/chatgpt-live"
PY="${PYTHON:-/opt/homebrew/bin/python3}"
mkdir -p "$DIR"
[ -x "$DIR/venv/bin/python" ] || "$PY" -m venv "$DIR/venv"
"$DIR/venv/bin/pip" install -q --upgrade pip
"$DIR/venv/bin/pip" install -q "aiortc>=1.9" "websockets>=13" numpy
tailscale serve --bg --https=8657 http://127.0.0.1:8656 >/dev/null
echo "ok: $("$DIR/venv/bin/python" -c 'import aiortc, websockets; print("aiortc", aiortc.__version__, "websockets", websockets.__version__)')"
