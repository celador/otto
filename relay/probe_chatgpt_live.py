"""Talk to the ChatGPT voice bridge like the phone does (bridge venv python).

  ~/.hermes/chatgpt-live/venv/bin/python relay/probe_chatgpt_live.py q.wav [q2.wav --barge 3]

WAVs: mono PCM16 (any rate is resampled to 16 kHz by taking the nearest sample). Prints the
transcripts, tool calls (answered with --answer text, as the phone would after asking Hermes),
time to the first reply audio, and saves the reply audio to /tmp/otto-chatgpt-reply.wav.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import sys
import time
import wave

import websockets

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chatgpt_live as cl  # noqa: E402


def load16k(path: str) -> bytes:
    w = wave.open(path)
    rate, n = w.getframerate(), w.getnframes()
    raw = w.readframes(n)
    import array
    a = array.array("h"); a.frombytes(raw)
    if w.getnchannels() == 2:
        a = a[::2]
    out = array.array("h", (a[int(i * rate / 16000)] for i in range(int(len(a) * 16000 / rate))))
    return out.tobytes()


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("wav", nargs="*")
    ap.add_argument("--text", default=None, help="send typed text (the app's DEBUG self-test path) instead of audio")
    ap.add_argument("--barge", type=float, default=None, help="send the 2nd wav this many s after reply audio starts")
    ap.add_argument("--answer", default="Your next meeting is with Angie at 3 pm today about her leads.")
    ap.add_argument("--listen", type=float, default=15)
    ap.add_argument("--voice", default="")
    ap.add_argument("--host", default=None, help="tailnet host, e.g. my-mac.example.ts.net (wss via tailscale serve)")
    a = ap.parse_args()
    tok = cl.mint({"voice": a.voice} if a.voice else {}, host=a.host)
    url = tok["ws_url"] + "?access_token=" + tok["token"]
    setup = dict(tok["setup"], context=[{"role": "user", "text": "My name is John."},
                                        {"role": "assistant", "text": "Hi John."}])
    t0 = time.time()
    async with websockets.connect(url, max_size=1 << 24) as ws:
        await ws.send(json.dumps({"setup": setup}))
        first = json.loads(await ws.recv())
        print(f"{time.time() - t0:.2f}s setup ->", list(first))
        if "setupComplete" not in first:
            print(first); return
        state = {"spoke_end": None, "first_audio": None, "audio": bytearray(), "interrupted": 0}
        clips = [load16k(p) for p in a.wav]

        async def mic() -> None:
            silence = bytes(3200)
            if a.text:
                await ws.send(json.dumps({"clientContent": {"turns": [{"role": "user", "parts": [{"text": a.text}]}], "turnComplete": True}}))
                state["spoke_end"] = time.time()
            for i, clip in enumerate(clips):
                if i == 1 and a.barge is not None:
                    while state["first_audio"] is None:
                        await asyncio.sleep(0.05)
                    await asyncio.sleep(max(0, a.barge - (time.time() - state["first_audio"])))
                    print(f"{time.time() - t0:.2f}s barge-in speech starts")
                for j in range(0, len(clip), 3200):
                    await ws.send(json.dumps({"realtimeInput": {"audio": {"mimeType": "audio/pcm;rate=16000",
                                                                            "data": base64.b64encode(clip[j:j + 3200]).decode()}}}))
                    await asyncio.sleep(0.1)
                state["spoke_end"] = time.time()
                state["first_audio"] = None if i + 1 < len(clips) else state["first_audio"]
            while True:
                await ws.send(json.dumps({"realtimeInput": {"audio": {"mimeType": "audio/pcm;rate=16000",
                                                                        "data": base64.b64encode(silence).decode()}}}))
                await asyncio.sleep(0.1)

        async def rx() -> None:
            heard, said = "", ""
            async for raw in ws:
                m = json.loads(raw)
                sc = m.get("serverContent") or {}
                for p in (sc.get("modelTurn") or {}).get("parts") or []:
                    pcm = base64.b64decode(p["inlineData"]["data"])
                    state["audio"].extend(pcm)
                    if state["first_audio"] is None:
                        state["first_audio"] = time.time()
                        lag = time.time() - state["spoke_end"] if state["spoke_end"] else float("nan")
                        print(f"{time.time() - t0:.2f}s FIRST REPLY AUDIO ({lag:.2f}s after speech ended)")
                if "inputTranscription" in sc:
                    heard += sc["inputTranscription"]["text"]
                if "outputTranscription" in sc:
                    said += sc["outputTranscription"]["text"]
                if sc.get("interrupted"):
                    state["interrupted"] += 1
                    print(f"{time.time() - t0:.2f}s INTERRUPTED; said so far: {said.strip()!r}"); said = ""
                if sc.get("turnComplete"):
                    print(f"{time.time() - t0:.2f}s turnComplete; heard={heard.strip()!r} said={said.strip()!r}"); heard = said = ""
                for c in (m.get("toolCall") or {}).get("functionCalls") or []:
                    print(f"{time.time() - t0:.2f}s TOOL {c['name']} {c['args']}")
                    async def answer(c=c) -> None:
                        await asyncio.sleep(1.5)
                        await ws.send(json.dumps({"toolResponse": {"functionResponses": [
                            {"id": c["id"], "name": c["name"], "response": {"result": a.answer, "scheduling": "WHEN_IDLE"}}]}}))
                        print(f"{time.time() - t0:.2f}s answered tool")
                    asyncio.ensure_future(answer())
                for k in ("error", "goAway"):
                    if k in m:
                        print(f"{time.time() - t0:.2f}s {k}: {m[k]}")

        tasks = [asyncio.ensure_future(mic()), asyncio.ensure_future(rx())]
        await asyncio.sleep(a.listen + sum(len(c) for c in clips) / 32000)
        for t in tasks:
            t.cancel()
        with wave.open("/tmp/otto-chatgpt-reply.wav", "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(bytes(state["audio"]))
        print(f"reply audio {len(state['audio']) / 48000:.1f}s, interrupted x{state['interrupted']}")


asyncio.run(main())
