"""ChatGPT voice (chatgpt_live.py): tokens, status, setup → realtime params, event translation
(barge-in, audio gating, delegation ↔ ask_otto) and PCM conversion. No network, no real ~/.hermes."""
import base64
import json
import tempfile
from array import array
from pathlib import Path

import chatgpt_live as cl


def _setup(env="API_SERVER_KEY=k\n", auth=None, venv=True):
    d = Path(tempfile.mkdtemp())
    (d / ".env").write_text(env)
    cl.ENV_FILE = d / ".env"
    cl.CODEX_AUTH = d / "auth.json"
    if auth is not None:
        cl.CODEX_AUTH.write_text(json.dumps(auth))
    cl.VENV_PY = d / "python"
    if venv:
        cl.VENV_PY.write_text("")
    return d


CHATGPT_AUTH = {"auth_mode": "chatgpt", "OPENAI_API_KEY": None, "tokens": {"id_token": "x"}}


# --- tokens

def test_token_roundtrip_and_tamper():
    env = {"API_SERVER_KEY": "k"}
    t = cl.make_token(env, {"voice": "cove"}, now=1000)
    c = cl.verify_token(env, t, now=1010)
    assert c["voice"] == "cove" and c["exp"] == 1000 + cl.TOKEN_TTL and c["nonce"]
    assert cl.verify_token({"API_SERVER_KEY": "other"}, t, now=1010) is None
    raw, sig = t.split(".")
    assert cl.verify_token(env, raw[:-2] + "AA." + sig, now=1010) is None
    assert cl.verify_token(env, "garbage", now=1010) is None


def test_token_expires():
    env = {"API_SERVER_KEY": "k"}
    t = cl.make_token(env, {}, now=1000)
    assert cl.verify_token(env, t, now=1000 + cl.TOKEN_TTL + 1) is None


def test_tokens_are_unique():
    env = {"API_SERVER_KEY": "k"}
    assert cl.make_token(env, {}, now=1) != cl.make_token(env, {}, now=1)


# --- status / mint

def test_status_needs_chatgpt_login():
    _setup(auth={"auth_mode": "apikey", "OPENAI_API_KEY": "sk-x"})
    s = cl.status()
    assert s["available"] is False and "ChatGPT" in s["reason"]
    _setup(auth=None)
    assert cl.status()["available"] is False


def test_status_needs_venv():
    _setup(auth=CHATGPT_AUTH, venv=False)
    s = cl.status()
    assert s["available"] is False and "setup_chatgpt_live.sh" in s["reason"]


def test_status_ok_lists_voices():
    _setup(auth=CHATGPT_AUTH)
    cl.codex_bin = lambda: "/usr/bin/true"
    s = cl.status()
    assert s["available"] is True and s["default_voice"] == "cove"
    assert {v["name"] for v in s["voices"]} == set(cl.VOICES)


def test_mint_shape_matches_gemini_token():
    _setup(env="API_SERVER_KEY=k\nCHATGPT_LIVE_VOICE=maple\n", auth=CHATGPT_AUTH)
    cl.codex_bin = lambda: "/usr/bin/true"
    started = []
    t = cl.mint({}, host="my-mac.example.ts.net:8651", ensure=lambda: started.append(1))
    assert started == [1]
    assert set(t) >= {"token", "ws_url", "model", "voice", "expires_at", "setup"}
    assert t["ws_url"] == "wss://my-mac.example.ts.net:8657/live"
    assert t["voice"] == "maple" and t["setup"] == {"engine": "chatgpt", "voice": "maple"}
    assert cl.verify_token({"API_SERVER_KEY": "k"}, t["token"])["voice"] == "maple"


def test_mint_rejects_bad_voice_and_missing_login():
    _setup(auth=CHATGPT_AUTH)
    cl.codex_bin = lambda: "/usr/bin/true"
    for bad in ("marin", 3, "../x"):
        try:
            cl.mint({"voice": bad}, ensure=lambda: None)
            raise AssertionError("accepted " + repr(bad))
        except cl.LiveError as e:
            assert e.status == 400
    _setup(auth=None)
    try:
        cl.mint({}, ensure=lambda: None)
        raise AssertionError("minted without login")
    except cl.LiveError as e:
        assert e.status == 409


def test_ws_url_local():
    assert cl.ws_url("127.0.0.1:8650") == f"ws://127.0.0.1:{cl.BRIDGE_PORT}/live"
    assert cl.ws_url(None).startswith("ws://127.0.0.1")


# --- realtime start params

def test_start_params_v3_webrtc_client_handoffs_and_context():
    setup = {"engine": "chatgpt", "context": [
        {"role": "user", "text": " hi "}, {"role": "assistant", "text": "hello"},
        {"role": "system", "text": "nope"}, {"role": "user", "text": ""}, "junk"]}
    p = cl.start_params("t1", "SDP", "cove", setup)
    assert p["version"] == "v3" and p["transport"] == {"type": "webrtc", "sdp": "SDP"}
    assert p["clientManagedHandoffs"] is True and p["includeStartupContext"] is False
    assert p["outputModality"] == "audio" and p["voice"] == "cove" and "Otto" in p["prompt"]
    assert p["initialItems"] == [{"role": "user", "text": "hi"}, {"role": "assistant", "text": "hello"}]
    assert "initialItems" not in cl.start_params("t1", "SDP", "cove", {})


def test_context_capped():
    many = [{"role": "user", "text": "x" * 1900} for _ in range(40)]
    items = cl.context_items({"context": many})
    assert len(items) <= cl.MAX_CONTEXT_ITEMS
    assert sum(len(i["text"]) for i in items) <= cl.MAX_CONTEXT_CHARS


def test_backing_thread_has_no_tools():
    f = cl.THREAD_START["config"]["features"]
    assert all(v is False for v in f.values()) and f["shell_tool"] is False and f["unified_exec"] is False
    assert cl.THREAD_START["ephemeral"] is True and cl.THREAD_START["sandbox"] == "read-only"


# --- translation

def ev(t, **kw):
    return dict(type=t, **kw)


def turn(t, role, id_):
    return ev(t, turn={"id": id_, "role": role})


def test_transcripts_and_turn_complete():
    tr = cl.Translator()
    tr.on_event(turn("turn.created", "user", "u1"), 0)
    tr.on_event(ev("input_transcript.added", item={"text": " What"}), 0)
    tr.on_event(ev("output_transcript.added", item={"text": " Four."}), 1)
    tr.on_event(turn("turn.done", "user", "u1"), 1)
    tr.on_event(turn("turn.created", "assistant", "a1"), 1)
    tr.on_event(turn("turn.done", "assistant", "a1"), 2)
    out, acts = tr.drain()
    assert out == [{"serverContent": {"inputTranscription": {"text": " What"}}},
                   {"serverContent": {"outputTranscription": {"text": " Four."}}},
                   {"serverContent": {"turnComplete": True}}]
    assert acts == []


def test_late_input_transcript_is_not_barge_in():
    tr = cl.Translator()
    tr.on_event(turn("turn.created", "user", "u1"), 0)
    tr.on_audio(b"\0\0", peak=5000, now=1.0)  # the answer started
    tr.on_event(ev("input_transcript.added", item={"text": " Uruguay?"}), 1.1)
    out, _ = tr.drain()
    assert {"serverContent": {"interrupted": True}} not in out


def test_barge_in_new_user_turn_while_speaking():
    tr = cl.Translator()
    tr.on_event(turn("turn.created", "assistant", "a1"), 0)
    assert tr.on_audio(b"\1\0", peak=5000, now=0.5) == b"\1\0"
    tr.on_event(turn("turn.done", "assistant", "a1"), 1.0)
    tr.on_event(turn("turn.created", "user", "u2"), 1.0)
    out, _ = tr.drain()
    assert out[-1] == {"serverContent": {"interrupted": True}}
    # the cut-off tail is dropped, then the next answer plays (even before its turn.created)
    assert tr.on_audio(b"\1\0", peak=5000, now=1.2) is None
    assert tr.on_audio(b"\2\0", peak=5000, now=1.7) == b"\2\0"
    tr.on_event(ev("output_transcript.added", item={"text": " Four."}), 1.8)
    out, _ = tr.drain()
    assert out == [{"serverContent": {"outputTranscription": {"text": " Four."}}}]


def test_barge_in_while_assistant_turn_open_mutes_that_turn():
    tr = cl.Translator()
    tr.on_event(turn("turn.created", "assistant", "a1"), 0)
    tr.on_event(turn("turn.created", "user", "u2"), 1)
    assert tr.on_audio(b"\1\0", peak=5000, now=3) is None  # a1 still open
    tr.on_event(ev("output_transcript.added", item={"text": "tail"}), 3)
    tr.on_event(turn("turn.done", "assistant", "a1"), 3.1)
    out, _ = tr.drain()
    assert out == [{"serverContent": {"interrupted": True}}]  # no tail text, no turnComplete
    tr.on_event(turn("turn.created", "assistant", "a2"), 3.2)
    assert tr.on_audio(b"\1\0", peak=5000, now=3.3) == b"\1\0"


def test_user_turn_after_silence_is_not_interrupt():
    tr = cl.Translator()
    tr.on_audio(b"\1\0", peak=5000, now=0)
    tr.on_event(turn("turn.created", "user", "u2"), 5)
    out, _ = tr.drain()
    assert out == []


def test_audio_gate_drops_silence_between_turns_keeps_pauses():
    tr = cl.Translator()
    assert tr.on_audio(b"\0\0", peak=3, now=0) is None
    assert tr.on_audio(b"\5\0", peak=3000, now=1) == b"\5\0"
    assert tr.on_audio(b"\0\0", peak=3, now=1.2) == b"\0\0"  # pause inside speech
    assert tr.on_audio(b"\0\0", peak=3, now=2) is None


def test_delegation_becomes_ask_otto_once():
    tr = cl.Translator()
    item = {"type": "handoff_request", "handoff_id": "h1", "input_transcript": " What's my next meeting? "}
    tr.on_item_added(item)
    tr.on_item_added(item)
    tr.on_item_added({"type": "something_else"})
    out, _ = tr.drain()
    assert out == [{"toolCall": {"functionCalls": [
        {"id": "h1", "name": "ask_otto", "args": {"request": "What's my next meeting?"}}]}}]


def test_delegation_falls_back_to_active_transcript():
    tr = cl.Translator()
    tr.on_item_added({"type": "handoff_request", "item_id": "h2", "input_transcript": "",
                      "active_transcript": [{"role": "user", "text": " check "}, {"role": "assistant", "text": "ok"},
                                            {"role": "user", "text": "my mail"}]})
    out, _ = tr.drain()
    assert out[0]["toolCall"]["functionCalls"][0]["args"]["request"] == "check my mail"


def tool_resp(id_, result, scheduling="WHEN_IDLE", more=False):
    r = {"id": id_, "name": "ask_otto", "response": {"result": result, "scheduling": scheduling}}
    if more:
        r["willContinue"] = True
    return {"toolResponse": {"functionResponses": [r]}}


def test_tool_results_go_back_as_developer_text():
    tr = cl.Translator()
    tr.on_item_added({"type": "handoff_request", "handoff_id": "h1", "input_transcript": "next meeting"})
    tr.drain()
    tr.on_tool_response(tool_resp("h1", "partial: reading calendar", "SILENT", more=True))
    tr.on_tool_response(tool_resp("h1", "partial: found 3 events", "WHEN_IDLE", more=True))
    tr.on_tool_response(tool_resp("h1", "Angie at 3 pm"))
    tr.on_tool_response(tool_resp("h1", ""))
    _, acts = tr.drain()
    assert [a[0] for a in acts] == ["appendText", "appendText"]
    assert all(a[1]["role"] == "developer" for a in acts)
    assert acts[0][1]["text"] == "Otto agent, partial progress: found 3 events"
    assert acts[1][1]["text"] == 'Otto agent, final result for "next meeting": Angie at 3 pm'


def test_silent_final_is_marked():
    tr = cl.Translator()
    tr.on_tool_response(tool_resp("x", "Sent as an update", "SILENT"))
    _, acts = tr.drain()
    assert acts[0][1]["text"].startswith("Otto agent (no need to say anything")


def test_usage_limit_and_error_events():
    tr = cl.Translator()
    tr.on_event(ev("session.usage.updated", usage_limit={"status": None}), 0)
    assert tr.usage_limited is None
    tr.on_event(ev("session.usage.updated", usage_limit={"status": "limited", "reset_seconds": 60}), 0)
    assert tr.usage_limited == "limited"
    tr.on_event(ev("error", error={"message": "boom"}), 0)
    out, _ = tr.drain()
    assert out == [{"error": {"message": "boom"}}]


# --- phone messages

def test_parse_phone():
    pcm = b"\1\2\3\4"
    a = {"realtimeInput": {"audio": {"mimeType": "audio/pcm;rate=16000", "data": base64.b64encode(pcm).decode()}}}
    assert cl.parse_phone(a) == ("audio", pcm)
    assert cl.parse_phone({"setup": {"engine": "chatgpt"}}) == ("setup", {"engine": "chatgpt"})
    assert cl.parse_phone({"realtimeInput": {"audioStreamEnd": True}}) == ("end", None)
    assert cl.parse_phone(tool_resp("a", "b"))[0] == "tool"
    assert cl.parse_phone({"clientContent": {"turns": [{"role": "user", "parts": [{"text": "hi"}]}],
                                            "turnComplete": True}}) == ("text", "hi")
    assert cl.parse_phone({"clientContent": {"turns": [], "turnComplete": False}}) == ("ignore", None)
    assert cl.parse_phone([1]) == ("ignore", None)


# --- PCM

def test_upsample_16k_to_48k():
    src = array("h", [0, 300, -300])
    out = cl.pcm16k_to_48k(src.tobytes())
    assert len(out) == 9
    assert list(out[:6]) == [0, 100, 200, 300, 100, -100]
    assert list(out[6:]) == [-300, -300, -300]
    assert len(cl.pcm16k_to_48k(b"\1")) == 0  # odd byte ignored


def test_downsample_48k_stereo_to_24k_mono_and_peak():
    s = array("h", [100, 300, 100, 300, -1000, -1000, -3000, -3000])
    pcm, peak = cl.pcm48k_to_24k(s, 2)
    out = array("h"); out.frombytes(pcm)
    assert list(out) == [200, -2000] and peak == 2000
    m = array("h", [10, 30, 50, 70])
    pcm, peak = cl.pcm48k_to_24k(m, 1)
    out = array("h"); out.frombytes(pcm)
    assert list(out) == [20, 60] and peak == 60


def test_audio_message_shape():
    m = cl.audio_message(b"\1\2")
    part = m["serverContent"]["modelTurn"]["parts"][0]["inlineData"]
    assert part["mimeType"] == "audio/pcm;rate=24000" and base64.b64decode(part["data"]) == b"\1\2"


def test_clean_request_drops_addressing_only():
    assert cl.clean_request("Ask Otto to reply with just the word pineapple.") == "Reply with just the word pineapple."
    assert cl.clean_request("hey, can you ask my agent what my next meeting is") == "What my next meeting is"
    assert cl.clean_request("Tell Otto: deploy the blog") == "Deploy the blog"
    assert cl.clean_request("  What's   on my calendar? ") == "What's on my calendar?"
    assert cl.clean_request("Ask Angie about the leads") == "Ask Angie about the leads"
    assert cl.clean_request("ask otto") == "ask otto"


# --- bridge mic: end of turn from the phone (bridge venv only: needs aiortc)

def test_bridge_end_turn_sends_clean_silence():
    try:
        import chatgpt_live_bridge as br
    except ImportError:  # aiortc/av live in ~/.hermes/chatgpt-live; run there to cover this
        import pytest
        pytest.skip("bridge venv not available")
    import asyncio
    import time as _t

    async def go():
        m = br.MicTrack()
        m.hold_until = 0
        loud = (b"\x00\x40" * 1600)  # 100 ms of 16 kHz PCM16, well above QUIET
        for _ in range(3):
            m.push(loud)
        assert len(m.q) > 0
        m.end_turn()
        assert len(m.q) == 0 and m.quiet_until > _t.time()
        m.push(loud)  # background noise right after the tap is dropped
        assert len(m.q) == 0
        f = await m.recv()
        assert max(abs(v) for v in array("h", bytes(f.planes[0])[: 2 * br.FRAME])) == 0
        m.quiet_until = 0  # window over: the mic flows again
        m.push(loud)
        assert len(m.q) > 0

    asyncio.run(go())
