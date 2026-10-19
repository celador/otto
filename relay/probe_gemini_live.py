"""Live probe: mint a token, open Gemini Live, ask something that needs Otto, answer the tool call,
check audio + transcripts come back. Silent (audio bytes are only counted).

    ~/.hermes/hermes-agent/venv/bin/python relay/probe_gemini_live.py
"""
import asyncio
import base64
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import gemini_live  # noqa: E402
import voice_search  # noqa: E402
import websockets  # noqa: E402


async def main(prompt: str):
    t0 = time.time()
    m = gemini_live.mint({})
    url = f"{m['ws_url']}?access_token={m['token']}"
    async with websockets.connect(url, max_size=None) as ws:
        await ws.send(json.dumps({"setup": m["setup"]}))
        audio = 0
        out_text, in_text = "", ""
        answered = False
        async def recv_until(pred, timeout=40):
            nonlocal audio, out_text, in_text
            end = time.time() + timeout
            while time.time() < end:
                raw = await asyncio.wait_for(ws.recv(), timeout=end - time.time())
                msg = json.loads(raw)
                keys = list(msg.keys())
                sc = msg.get("serverContent") or {}
                for p in (sc.get("modelTurn") or {}).get("parts") or []:
                    if "inlineData" in p:
                        audio += len(base64.b64decode(p["inlineData"]["data"]))
                    elif p.get("text"):
                        print(f"  text part: {p['text'][:80]!r}")
                if sc.get("outputTranscription"):
                    out_text += sc["outputTranscription"].get("text", "")
                if sc.get("inputTranscription"):
                    in_text += sc["inputTranscription"].get("text", "")
                flags = [k for k in ("turnComplete", "interrupted", "generationComplete", "waitingForInput") if sc.get(k)]
                if "serverContent" not in keys or flags:
                    print(f"{time.time()-t0:5.1f}s {keys} {flags} {json.dumps(msg)[:300] if 'serverContent' not in keys else ''}")
                if pred(msg):
                    return msg
            raise TimeoutError
        await recv_until(lambda x: "setupComplete" in x)
        await ws.send(json.dumps({"clientContent": {"turns": [{"role": "user", "parts": [{"text": prompt}]}],
                                                    "turnComplete": True}}))
        calls = []
        audio_at_answer = 0
        # Answer every tool call the way the phone does: web_search/weather through voice_search
        # (blocking: Gemini waits), ask_otto with one willContinue "partial:" progress update and
        # then a canned final answer.
        while True:
            try:
                msg = await recv_until(lambda x: "toolCall" in x or (x.get("serverContent") or {}).get("turnComplete"),
                                       timeout=40)
            except (TimeoutError, asyncio.TimeoutError):
                break
            if "toolCall" not in msg:
                # Done once something was said after the last tool answer (and that answer's facts).
                if audio > audio_at_answer and (not calls or calls[-1] != "ask_otto" or "dentist" in out_text.lower()):
                    break
                continue
            for fc in msg["toolCall"]["functionCalls"]:
                name, args = fc["name"], fc.get("args") or {}
                calls.append(name)
                print("TOOL CALL", name, args)
                responses = []
                if name == "web_search":
                    ts = time.time()
                    try:
                        r = voice_search.web(args.get("query"))["result"]
                    except voice_search.SearchError as e:
                        r = f"Search failed: {e.detail}"
                    print(f"  web_search answered in {time.time()-ts:.2f}s ({len(r)} chars)")
                    responses.append({"id": fc["id"], "name": name,
                                      "response": {"result": r, "scheduling": "INTERRUPT"}})
                elif name == "weather":
                    try:
                        r = voice_search.weather(args.get("place"))["result"]
                    except voice_search.SearchError as e:
                        r = f"Weather failed: {e.detail}"
                    responses.append({"id": fc["id"], "name": name,
                                      "response": {"result": r, "scheduling": "INTERRUPT"}})
                else:
                    await ws.send(json.dumps({"toolResponse": {"functionResponses": [{
                        "id": fc["id"], "name": name, "willContinue": True,
                        "response": {"result": "partial: Otto is checking the calendar.", "scheduling": "SILENT"}}]}}))
                    print("  sent partial (willContinue)")
                    await asyncio.sleep(2)  # "Otto works"
                    responses.append({"id": fc["id"], "name": name, "response": {
                        "result": "Tomorrow: 10:00 dentist, 15:30 call with Neha.", "scheduling": "WHEN_IDLE"}})
                await ws.send(json.dumps({"toolResponse": {"functionResponses": responses}}))
                answered = True
                audio_at_answer = audio
        print("ROUTING:", calls or ["(answered directly)"])
        print(f"audio bytes={audio} (~{audio/48000:.1f}s) tool_answered={answered}")
        print("model said:", out_text.strip()[:400])


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "What's the weather in Montevideo right now?"))
