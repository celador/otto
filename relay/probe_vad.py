"""Live probe for voice turn-taking: how fast Gemini Live answers after you stop talking, and that a
short mid-sentence pause doesn't end the turn. Streams spoken fixtures (16 kHz PCM16) in real time
followed by low-level background noise, the way the phone's mic would, and logs the timings.

    ~/.hermes/hermes-agent/venv/bin/python relay/probe_vad.py q.pcm                # one question
    ~/.hermes/hermes-agent/venv/bin/python relay/probe_vad.py p1.pcm p2.pcm --gap 0.6   # pause test
    options: --engine gemini|chatgpt (chatgpt = the Mac bridge), --sens LOW|HIGH|UNSPECIFIED (default: what the relay sends), --silence MS,
             --noise DBFS (default -50), --tail S (noise after speech, default 4),
             --force S (send audioStreamEnd S seconds after speech ends: the phone's fallback/tap),
             --phone (run the app's own quiet detector on the stream, like the phone),
             --bg FILE (loop a background recording, e.g. someone talking, instead of white noise),
             --client (noisy-room mode: server VAD off, Otto's own turn detector sends activityStart/End),
             --manual S (server VAD off, activityStart/End by the clock: S s after speech ends)

Make fixtures with: say -o q.aiff "What is the capital of France?" &&
                    ffmpeg -i q.aiff -ar 16000 -ac 1 -f s16le q.pcm
"""
import argparse
import asyncio
import base64
import json
import math
import random
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import chatgpt_live  # noqa: E402
import gemini_live  # noqa: E402
import turn_detect  # noqa: E402
import websockets  # noqa: E402

RATE = 16000
CHUNK = RATE * 2 // 10  # 100 ms, like the phone


BG: list[int] = []  # --bg: looped background recording (babble, TV) instead of white noise
_bg_pos = 0


def noise(seconds: float, dbfs: float, rng: random.Random) -> bytes:
    """White noise (or the --bg recording) at this RMS level."""
    global _bg_pos
    n = int(seconds * RATE)
    target = 32768 * 10 ** (dbfs / 20)
    if BG:
        out = []
        for _ in range(n):
            out.append(BG[_bg_pos % len(BG)])
            _bg_pos += 1
        rms = math.sqrt(sum(v * v for v in BG) / len(BG)) or 1
        g = target / rms
        return struct.pack(f"<{n}h", *(max(-32768, min(32767, int(v * g))) for v in out))
    amp = target * math.sqrt(3)  # uniform noise with this RMS
    return struct.pack(f"<{n}h", *(int(rng.uniform(-amp, amp)) for _ in range(n)))


def speech_end(pcm: bytes, thresh: int = 300) -> float:
    """Seconds into the clip where the last audible sample is (say pads the end with silence)."""
    n = len(pcm) // 2
    s = struct.unpack(f"<{n}h", pcm[: n * 2])
    for i in range(n - 1, -1, -1):
        if abs(s[i]) > thresh:
            return (i + 1) / RATE
    return 0.0


def mix_noise(pcm: bytes, dbfs: float, rng: random.Random) -> bytes:
    n = len(pcm) // 2
    s = struct.unpack(f"<{n}h", pcm[: n * 2])
    z = struct.unpack(f"<{n}h", noise(n / RATE, dbfs, rng))
    return struct.pack(f"<{n}h", *(max(-32768, min(32767, a + b)) for a, b in zip(s, z)))


def dbfs(chunk: bytes) -> float:
    n = len(chunk) // 2
    if not n:
        return -100.0
    s = struct.unpack(f"<{n}h", chunk[: n * 2])
    rms = math.sqrt(sum(v * v for v in s) / n) / 32768
    return max(-100.0, 20 * math.log10(rms)) if rms > 0 else -100.0


async def run(args: argparse.Namespace) -> dict:
    rng = random.Random(7)
    clips = [Path(p).read_bytes() for p in args.clips]
    if args.engine == "chatgpt":
        chatgpt_live.ensure_running()
        m = chatgpt_live.mint({})
    else:
        m = gemini_live.mint({"silence_ms": args.silence} if args.silence else {})
    setup = m["setup"]
    aad = setup.get("realtimeInputConfig", {}).get("automaticActivityDetection", {})
    if args.sens and aad:
        if args.sens == "UNSPECIFIED":
            aad.pop("endOfSpeechSensitivity", None)
        else:
            aad["endOfSpeechSensitivity"] = f"END_SENSITIVITY_{args.sens}"
    if args.start and aad:
        if args.start == "UNSPECIFIED":
            aad.pop("startOfSpeechSensitivity", None)
        else:
            aad["startOfSpeechSensitivity"] = f"START_SENSITIVITY_{args.start}"
    if args.manual is not None or args.client:
        # Client-driven turns (the app's noisy-room mode): no server VAD; we send activityStart/End.
        setup["realtimeInputConfig"] = {"automaticActivityDetection": {"disabled": True}}
        aad = setup["realtimeInputConfig"]["automaticActivityDetection"]
    print("VAD:", json.dumps(aad))
    # Build the stream: lead-in noise, clip1, gap, clip2, ..., tail noise. Track speech end times.
    # ChatGPT drops speech in its first second (the bridge holds the mic): start talking later.
    stream = noise(args.lead if args.lead is not None else (2.0 if args.engine == "chatgpt" else 0.5), args.noise, rng)
    marks = []  # (label, seconds into stream)
    for i, c in enumerate(clips):
        if i:
            stream += noise(args.gap, args.noise, rng)
        start = len(stream) / 2 / RATE
        stream += mix_noise(c, args.noise, rng)
        marks.append((f"speech{i + 1}_end", start + speech_end(c)))
    # Trim the clip's trailing padding out of the accounting: the tail starts right after the clip.
    stream += noise(args.tail, args.noise, rng)
    last_end = marks[-1][1]
    events: list[tuple[float, str]] = []
    url = f"{m['ws_url']}?access_token={m['token']}"
    async with websockets.connect(url, max_size=None) as ws:
        await ws.send(json.dumps({"setup": setup}))
        while "setupComplete" not in json.loads(await ws.recv()):
            pass
        t0 = time.time()
        stop = asyncio.Event()

        phone = turn_detect.TurnDetector() if (args.phone or args.client) else None
        preroll: list[bytes] = []
        state = {"heard": False, "answered": False}

        first_start = marks[0][1] - speech_end(clips[0]) if marks else 0

        async def sender():
            forced = False
            active = False
            for off in range(0, len(stream), CHUNK):
                at = t0 + off / 2 / RATE
                await asyncio.sleep(max(0, at - time.time()))
                if stop.is_set():
                    return
                pos = off / 2 / RATE
                if args.force is not None and not forced and pos >= last_end + args.force:
                    await ws.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))
                    events.append((time.time() - t0, "sent audioStreamEnd"))
                    forced = True
                chunk = stream[off: off + CHUNK]
                if args.manual is not None:
                    if not active and not state.get("ended") and pos >= first_start - 0.3:
                        await ws.send(json.dumps({"realtimeInput": {"activityStart": {}}}))
                        events.append((time.time() - t0, "sent activityStart"))
                        active = True
                    if active and pos >= last_end + args.manual:
                        await ws.send(json.dumps({"realtimeInput": {"activityEnd": {}}}))
                        events.append((time.time() - t0, "sent activityEnd"))
                        active, state["ended"] = False, True
                if args.client:
                    # The app's noisy-room mode: Otto decides activityStart/End; audio only inside.
                    r = phone.feed(dbfs(chunk), 0.1, client=True, playing=False)
                    preroll.append(chunk)
                    del preroll[:-6]
                    if r == "start":
                        await ws.send(json.dumps({"realtimeInput": {"activityStart": {}}}))
                        events.append((time.time() - t0, "client: activityStart (+0.6 s pre-roll)"))
                        for c in preroll[:-1]:
                            await ws.send(json.dumps({"realtimeInput": {"audio": {
                                "mimeType": "audio/pcm;rate=16000", "data": base64.b64encode(c).decode()}}}))
                    if phone.active or r == "start":
                        await ws.send(json.dumps({"realtimeInput": {"audio": {
                            "mimeType": "audio/pcm;rate=16000", "data": base64.b64encode(chunk).decode()}}}))
                    if r and r.startswith("end"):
                        await ws.send(json.dumps({"realtimeInput": {"activityEnd": {}}}))
                        events.append((time.time() - t0, f"client: activityEnd ({r[4:]}) floor={phone.room.floor:.0f}dB"))
                    continue
                if phone and not state["answered"] and phone.feed(dbfs(chunk), 0.1, server_heard=state["heard"]):
                    await ws.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))
                    events.append((time.time() - t0, "phone endpointer: sent audioStreamEnd"))
                    state["hold"] = time.time() + args.hold
                if forced and args.hold and "hold" not in state:
                    state["hold"] = time.time() + args.hold
                # The app holds the mic after ending the turn until Otto answers (or new speech):
                # resuming at once sends the background noise, which Gemini takes as more talking.
                if state.get("hold", 0) > time.time() and not state["answered"]:
                    continue
                await ws.send(json.dumps({"realtimeInput": {"audio": {
                    "mimeType": "audio/pcm;rate=16000", "data": base64.b64encode(chunk).decode()}}}))

        async def receiver():
            heard = ""
            first_audio = None
            while True:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=max(0.1, len(stream) / 2 / RATE + 6 - (time.time() - t0)))
                except (asyncio.TimeoutError, TimeoutError):
                    return first_audio, heard
                msg = json.loads(raw)
                now = time.time() - t0
                sc = msg.get("serverContent") or {}
                if sc.get("inputTranscription", {}).get("text"):
                    heard += sc["inputTranscription"]["text"]
                    state["heard"] = True
                if "toolCall" in msg:
                    events.append((now, "toolCall " + ",".join(f["name"] for f in msg["toolCall"]["functionCalls"])))
                    if first_audio is None:
                        first_audio = now
                for p in (sc.get("modelTurn") or {}).get("parts") or []:
                    if "inlineData" in p and first_audio is None:
                        first_audio = now
                        state["answered"] = True
                        events.append((now, "first model audio"))
                for k in ("interrupted", "turnComplete", "generationComplete"):
                    if sc.get(k):
                        events.append((now, k))
                if first_audio is not None and sc.get("turnComplete"):
                    return first_audio, heard

        snd = asyncio.ensure_future(sender())
        first_audio, heard = await receiver()
        stop.set()
        snd.cancel()
    for label, t in marks:
        events.append((t, label))
    for t, e in sorted(events):
        print(f"  {t:6.2f}s  {e}")
    print("heard:", heard.strip()[:160])
    result = {"vad": aad, "noise_dbfs": args.noise, "speech_end": round(last_end, 2),
              "first_reply": round(first_audio, 2) if first_audio else None,
              "delay_after_speech": round(first_audio - last_end, 2) if first_audio else None,
              "early": bool(first_audio and len(marks) > 1 and first_audio < last_end)}
    print("RESULT", json.dumps(result))
    return result


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--engine", choices=["gemini", "chatgpt"], default="gemini")
    ap.add_argument("--sens", choices=["LOW", "HIGH", "UNSPECIFIED"])
    ap.add_argument("--start", choices=["LOW", "HIGH", "UNSPECIFIED"], help="startOfSpeechSensitivity")
    ap.add_argument("--silence", type=int)
    ap.add_argument("--noise", type=float, default=-50)
    ap.add_argument("--gap", type=float, default=0.6)
    ap.add_argument("--lead", type=float, help="seconds of noise before speech (default 0.5; 2 for chatgpt)")
    ap.add_argument("--tail", type=float, default=4)
    ap.add_argument("--force", type=float)
    ap.add_argument("--hold", type=float, default=0, help="after ending the turn, send no audio for up to S s (until the reply)")
    ap.add_argument("--manual", type=float, help="client-driven turns: AAD off, activityStart before speech, activityEnd S s after it")
    ap.add_argument("--client", action="store_true", help="the app's noisy-room mode: AAD off, turns from relay/turn_detect.py")
    ap.add_argument("--phone", action="store_true", help="run the app's quiet detector (mirror) on the stream")
    ap.add_argument("--bg", help="16 kHz PCM16 background recording to loop instead of white noise")
    args = ap.parse_args()
    if args.bg:
        raw = Path(args.bg).read_bytes()
        BG.extend(struct.unpack(f"<{len(raw) // 2}h", raw[: len(raw) // 2 * 2]))
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
