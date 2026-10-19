"""Otto ↔ ChatGPT voice bridge (see chatgpt_live.py for the shape).

Runs in ~/.hermes/chatgpt-live/venv (aiortc, websockets, numpy), started by the relay on
127.0.0.1:8656 (tailnet: https 8657). One persistent `codex app-server` (ChatGPT login) opens a
realtime WebRTC call per phone session; this process terminates the WebRTC media and speaks
Gemini-Live-style JSON to the phone over a websocket.
"""
from __future__ import annotations

import argparse
import asyncio
import collections
import fractions
import json
import os
import sys
import tempfile
import time
from array import array
from typing import Any
from urllib.parse import parse_qs, urlsplit

from aiortc import MediaStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from av import AudioFrame
import websockets
from websockets.asyncio.server import serve
from websockets.http11 import Response
from websockets.datastructures import Headers

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chatgpt_live as cl  # noqa: E402

FRAME = 960  # 20 ms @ 48 kHz
MAX_QUEUE = 150  # frames of mic audio (3 s) kept while ChatGPT warms up; older ones are dropped
PRIME = 3  # after running dry, wait for 60 ms of audio before resuming (no choppy zero gaps)
QUIET = 400  # peak below this is silence; queued silence is skipped to catch up after a backlog
WARMUP = 1.0  # ChatGPT drops speech in its first ~second: hold the mic (queued) that long
END_QUIET = 0.8  # the phone ended the turn (tap / its quiet fallback): send ChatGPT clean silence this long


def log(*a: Any) -> None:
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


class AppServer:
    """A persistent `codex app-server` over stdio JSON-RPC."""

    def __init__(self) -> None:
        self.proc: asyncio.subprocess.Process | None = None
        self.pending: dict[int, asyncio.Future] = {}
        self.handlers: dict[str, Any] = {}  # threadId → Session
        self.nid = 0
        self.lock = asyncio.Lock()

    async def ensure(self) -> None:
        async with self.lock:
            if self.proc and self.proc.returncode is None:
                return
            codex = cl.codex_bin()
            if not codex:
                raise RuntimeError("codex CLI not found")
            env = {k: v for k, v in os.environ.items() if k != "OPENAI_API_KEY"}
            self.proc = await asyncio.create_subprocess_exec(
                codex, "app-server", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, env=env, cwd=tempfile.mkdtemp(prefix="otto-rt-"), limit=1 << 24)
            asyncio.ensure_future(self._read(self.proc))
            await self._call("initialize", {"clientInfo": {"name": "otto-chatgpt-live", "title": None, "version": "1"},
                                            "capabilities": {"experimentalApi": True, "requestAttestation": False}})
            self._write({"jsonrpc": "2.0", "method": "initialized"})
            log("app-server ready")

    def _write(self, obj: dict[str, Any]) -> None:
        assert self.proc and self.proc.stdin
        self.proc.stdin.write((json.dumps(obj) + "\n").encode())

    async def _call(self, method: str, params: dict[str, Any], timeout: float = 30) -> dict[str, Any]:
        self.nid += 1
        fut = asyncio.get_running_loop().create_future()
        self.pending[self.nid] = fut
        self._write({"jsonrpc": "2.0", "id": self.nid, "method": method, "params": params})
        msg = await asyncio.wait_for(fut, timeout)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error'].get('message', msg['error'])}")
        return msg.get("result") or {}

    async def call(self, method: str, params: dict[str, Any], timeout: float = 30) -> dict[str, Any]:
        await self.ensure()
        return await self._call(method, params, timeout)

    async def _read(self, proc: asyncio.subprocess.Process) -> None:
        assert proc.stdout
        async for line in proc.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if "id" in m and ("result" in m or "error" in m):
                f = self.pending.pop(m["id"], None)
                if f and not f.done():
                    f.set_result(m)
                continue
            if "id" in m and "method" in m:
                # A server request (approvals etc.): never approve anything.
                self._write({"jsonrpc": "2.0", "id": m["id"], "result": {"decision": "decline"}})
                continue
            params = m.get("params") or {}
            tid = params.get("threadId") or (params.get("thread") or {}).get("id")
            s = self.handlers.get(tid)
            if s:
                s.on_notification(m.get("method", ""), params)
        log("app-server exited", proc.returncode)
        for f in self.pending.values():
            if not f.done():
                f.set_exception(RuntimeError("app-server exited"))
        self.pending.clear()


APP = AppServer()
USED_NONCES: dict[str, float] = {}


class MicTrack(MediaStreamTrack):
    """Phone mic (16 kHz PCM16 chunks) → 20 ms 48 kHz frames for WebRTC; silence when idle."""
    kind = "audio"

    def __init__(self) -> None:
        super().__init__()
        self.q: collections.deque[array] = collections.deque()
        self.pending = array("h")
        self.ts = 0
        self.t0: float | None = None
        self.primed = False
        self.hold_until = float("inf")  # set when the session is ready
        self.quiet_until = 0.0  # end_turn(): digital silence (mic dropped) until then

    def end_turn(self, now: float | None = None) -> None:
        """The phone says John is done (tap to send, or its quiet fallback): drop the queued mic
        audio (background noise after his words) and feed ChatGPT clean silence for END_QUIET s, so
        its turn detection hears the end even in a noisy room."""
        now = time.time() if now is None else now
        self.q.clear()
        del self.pending[:]
        self.primed = False
        self.quiet_until = now + END_QUIET

    def push(self, pcm16k: bytes) -> None:
        if time.time() < self.quiet_until:
            return
        self.pending.extend(cl.pcm16k_to_48k(pcm16k))
        while len(self.pending) >= FRAME:
            self.q.append(self.pending[:FRAME])
            del self.pending[:FRAME]
        while len(self.q) > MAX_QUEUE:
            self.q.popleft()

    async def recv(self) -> AudioFrame:
        if self.t0 is None:
            self.t0 = time.time()
        wait = self.t0 + self.ts / 48000 - time.time()
        if wait > 0:
            await asyncio.sleep(wait)
        if time.time() < self.hold_until or time.time() < self.quiet_until:
            return self._frame(array("h", bytes(2 * FRAME)))
        # Catch up after a backlog (the warm-up hold, network bursts): skip queued silence.
        while len(self.q) > PRIME and max(map(abs, self.q[0])) < QUIET:
            self.q.popleft()
        if not self.q:
            self.primed = False
        elif len(self.q) >= PRIME:
            self.primed = True
        samples = self.q.popleft() if self.q and self.primed else array("h", bytes(2 * FRAME))
        return self._frame(samples)

    def _frame(self, samples: array) -> AudioFrame:
        f = AudioFrame(format="s16", layout="mono", samples=FRAME)
        f.planes[0].update(samples.tobytes())
        f.sample_rate = 48000
        f.pts = self.ts
        f.time_base = fractions.Fraction(1, 48000)
        self.ts += FRAME
        return f


class Session:
    def __init__(self, ws: Any, voice: str) -> None:
        self.ws = ws
        self.voice = voice
        self.tr = cl.Translator()
        # No STUN: ChatGPT's side is ICE-lite on a public address, host candidates reach it, and
        # aiortc's default STUN lookup adds a 5 s gather to every session.
        self.pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.mic = MicTrack()
        self.thread: str | None = None
        self.sdp: asyncio.Future = asyncio.get_running_loop().create_future()
        self.closed = asyncio.Event()
        self.ready = asyncio.Event()  # ChatGPT's session.started: audio before it is lost
        self.stopping = False
        self.out_buf = bytearray()
        self.t_start = time.time()
        self.t_ready = time.time()
    # phone side
    def send(self, obj: dict[str, Any]) -> None:
        asyncio.ensure_future(self._send(json.dumps(obj)))

    async def _send(self, text: str) -> None:
        try:
            await self.ws.send(text)
        except websockets.ConnectionClosed:
            self.closed.set()

    def flush(self) -> None:
        out, acts = self.tr.drain()
        for o in out:
            self.send(o)
        for method, params in acts:
            asyncio.ensure_future(self.append(method, params))

    async def append(self, method: str, params: dict[str, Any]) -> None:
        if not self.thread:
            return
        try:
            await APP.call("thread/realtime/" + method, dict(params, threadId=self.thread))
            log(self.thread[:8], method, params.get("text", "")[:80].replace("\n", " "))
        except Exception as e:  # noqa: BLE001
            log("append failed", e)

    # app-server notifications for our thread
    def on_notification(self, method: str, p: dict[str, Any]) -> None:
        if method == "thread/realtime/sdp" and not self.sdp.done():
            self.sdp.set_result(p.get("sdp", ""))
        elif method == "thread/realtime/error":
            msg = p.get("message", "error")
            log(self.thread and self.thread[:8], "realtime error:", msg[:300])
            if not self.sdp.done():
                self.sdp.set_exception(RuntimeError(msg))
            else:
                self.send({"error": {"message": "ChatGPT voice: " + msg[:300]}})
                self.closed.set()
        elif method == "thread/realtime/closed":
            log(self.thread and self.thread[:8], "realtime closed:", p.get("reason"))
            if not self.stopping:
                # Server ended the call (time cap, limits): the phone reconnects with a new session.
                self.send({"goAway": {"timeLeft": "0s"}})
        elif method == "thread/realtime/itemAdded":
            self.tr.on_item_added(p.get("item") or {})
            self.flush()
        elif method == "turn/started":
            # A delegation starts a Codex turn on the backing thread: stop it, Hermes answers instead.
            turn = (p.get("turn") or {}).get("id")
            if turn and self.thread:
                asyncio.ensure_future(APP.call("turn/interrupt", {"threadId": self.thread, "turnId": turn}))

    def on_dc(self, raw: Any) -> None:
        try:
            e = json.loads(raw)
        except (TypeError, ValueError):
            return
        if e.get("type") == "session.started":
            self.ready.set()
        if os.environ.get("OTTO_RT_DEBUG"):
            log("dc", json.dumps(e)[:160])
        self.tr.on_event(e, time.time())
        if e.get("type") == "session.usage.updated" and self.tr.usage_limited:
            log("usage limit status:", self.tr.usage_limited)
        self.flush()

    async def pump_remote(self, track: MediaStreamTrack) -> None:
        while not self.closed.is_set():
            try:
                fr = await track.recv()
            except Exception:  # noqa: BLE001
                return
            ch = len(fr.layout.channels)
            samples = array("h")
            samples.frombytes(bytes(fr.planes[0])[: fr.samples * ch * 2])
            pcm, peak = cl.pcm48k_to_24k(samples, ch)
            chunk = self.tr.on_audio(pcm, peak, time.time())
            self.flush()
            if chunk is None:
                if self.out_buf:
                    self.send(cl.audio_message(bytes(self.out_buf)))
                    self.out_buf.clear()
                continue
            self.out_buf.extend(chunk)
            if len(self.out_buf) >= 24000 * 2 * 40 // 1000:  # 40 ms
                self.send(cl.audio_message(bytes(self.out_buf)))
                self.out_buf.clear()

    async def start(self, setup: dict[str, Any]) -> None:
        self.pc.addTrack(self.mic)
        dc = self.pc.createDataChannel("oai-events")
        dc.on("message", self.on_dc)
        self.pc.on("track", lambda t: asyncio.ensure_future(self.pump_remote(t)) if t.kind == "audio" else None)
        t = time.time()
        await self.pc.setLocalDescription(await self.pc.createOffer())
        t_offer = time.time() - t
        t = time.time()
        r = await APP.call("thread/start", cl.THREAD_START)
        t_thread = time.time() - t
        self.thread = r["thread"]["id"]
        APP.handlers[self.thread] = self
        await APP.call("thread/realtime/start", cl.start_params(self.thread, self.pc.localDescription.sdp, self.voice, setup))
        sdp = await asyncio.wait_for(self.sdp, 20)
        t_sdp = time.time() - t - t_thread
        await self.pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="answer"))
        for _ in range(100):
            if self.pc.connectionState == "connected":
                break
            if self.pc.connectionState in ("failed", "closed"):
                raise RuntimeError("WebRTC " + self.pc.connectionState)
            await asyncio.sleep(0.1)
        else:
            raise RuntimeError("WebRTC didn't connect")
        try:
            await asyncio.wait_for(self.ready.wait(), 5)
        except asyncio.TimeoutError:
            log(self.thread[:8], "no session.started after 5 s; going ahead")
        self.t_ready = time.time()
        self.mic.hold_until = self.t_ready + WARMUP
        log(self.thread[:8], f"connected in {time.time() - self.t_start:.2f}s (offer {t_offer:.2f}s, thread {t_thread:.2f}s, sdp {t_sdp:.2f}s) voice={self.voice} context={len(cl.context_items(setup))}")

    async def say(self, text: str) -> None:
        import wave
        path = os.path.join(tempfile.mkdtemp(prefix="otto-say-"), "t.wav")
        p = await asyncio.create_subprocess_exec("/usr/bin/say", "-o", path, "--data-format=LEI16@16000",
                                                 "--channels=1", text[:2000])
        await p.wait()
        try:
            with wave.open(path) as w:
                pcm = w.readframes(w.getnframes())
        except (OSError, wave.Error) as e:
            log("say failed:", e)
            return
        # Like a person: start a moment after the session opens (ChatGPT is still loading context).
        await asyncio.sleep(max(0, self.t_ready + float(os.environ.get("OTTO_SELFTEST_DELAY", "0")) - time.time()))
        log(self.thread and self.thread[:8], f"self-test speech {len(pcm) / 32000:.1f}s")
        t0 = time.time()
        for n, i in enumerate(range(0, len(pcm), 3200)):
            if self.closed.is_set():
                return
            self.mic.push(pcm[i:i + 3200])
            await asyncio.sleep(max(0, t0 + (n + 1) * 0.1 - time.time()))

    def end_turn(self) -> None:
        """realtimeInput.audioStreamEnd from the phone: John is done talking."""
        # ChatGPT's realtime v3 has no commit event (input_audio_buffer.commit kills the session):
        # clean silence is what makes its turn detection fire.
        self.mic.end_turn()
        log(self.thread and self.thread[:8], "end of turn from the phone")

    async def stop(self) -> None:
        self.stopping = True
        self.closed.set()
        if self.thread:
            try:
                await APP.call("thread/realtime/stop", {"threadId": self.thread}, timeout=5)
            except Exception:  # noqa: BLE001
                pass
            APP.handlers.pop(self.thread, None)
        await self.pc.close()
        log(self.thread and self.thread[:8], f"ended after {time.time() - self.t_start:.0f}s")


async def handle(ws: Any) -> None:
    q = parse_qs(urlsplit(ws.request.path).query)
    token = (q.get("access_token") or [""])[0]
    claims = cl.verify_token(cl._env(), token)
    now = time.time()
    for k, exp in list(USED_NONCES.items()):
        if exp < now:
            USED_NONCES.pop(k, None)
    if not claims or claims.get("nonce") in USED_NONCES:
        await ws.close(1008, "bad or used token")
        return
    USED_NONCES[claims["nonce"]] = claims["exp"] + 60
    try:
        first = json.loads(await asyncio.wait_for(ws.recv(), 10))
    except Exception:  # noqa: BLE001
        await ws.close(1002, "expected setup")
        return
    kind, setup = cl.parse_phone(first)
    if kind != "setup":
        await ws.close(1002, "expected setup")
        return
    s = Session(ws, claims.get("voice") or cl.DEFAULT_VOICE)
    try:
        await s.start(setup)
    except Exception as e:  # noqa: BLE001
        log("start failed:", e)
        try:
            await ws.send(json.dumps({"error": {"message": f"ChatGPT voice couldn't start: {e}"[:300]}}))
            await ws.close(1011, "start failed")
        except Exception:  # noqa: BLE001
            pass
        await s.stop()
        return
    try:
        await ws.send(json.dumps({"setupComplete": {}}))
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            kind, val = cl.parse_phone(msg)
            if kind == "audio":
                s.mic.push(val)
            elif kind == "end":
                s.end_turn()
            elif kind == "tool":
                s.tr.on_tool_response(val)
                s.flush()
            elif kind == "text":
                # Typed text (the app's DEBUG self-test): ChatGPT's v3 treats appended user text
                # oddly (echoes it, never delegates), so speak it into the mic instead: the whole
                # audio path gets exercised.
                asyncio.ensure_future(s.say(val))
            if s.closed.is_set():
                break
    except websockets.ConnectionClosed:
        pass
    finally:
        await s.stop()


def health(conn: Any, request: Any) -> Response | None:
    if request.path.startswith("/health"):
        return Response(200, "OK", Headers([("Content-Type", "text/plain")]), b"ok\n")
    if not request.path.startswith("/live"):
        return Response(404, "Not Found", Headers(), b"")
    return None


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=cl.BRIDGE_PORT)
    args = ap.parse_args()
    await APP.ensure()
    async with serve(handle, args.host, args.port, process_request=health, max_size=16 * 1024 * 1024,
                     ping_interval=20, ping_timeout=20):
        log(f"chatgpt live bridge on ws://{args.host}:{args.port}/live")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
