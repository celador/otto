"""Hermes command providers for Otto local voice (stdlib only; talks to relay/local_voice.py).

config.yaml:
  stt:
    provider: otto-local
    providers:
      otto-local: {type: command, command: "python3 .../local_voice_cli.py stt {input_path}"}
  tts:
    provider: otto-local
    providers:
      otto-local: {type: command, command: "python3 .../local_voice_cli.py tts {input_path} {output_path} {voice}",
                   voice: af_heart, output_format: mp3, voice_compatible: true}
"""
import json
import sys
import urllib.request

URL = "http://127.0.0.1:8653"


def post(path: str, data: bytes, ctype: str, timeout: float = 120) -> bytes:
    req = urllib.request.Request(URL + path, data=data, method="POST", headers={"Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "stt":
        with open(argv[1], "rb") as f:
            out = json.loads(post("/stt", f.read(), "application/octet-stream"))
        print(out.get("text", ""))
        return 0
    if len(argv) >= 3 and argv[0] == "tts":
        with open(argv[1], encoding="utf-8") as f:
            text = f.read().strip()
        voice = argv[3] if len(argv) > 3 and argv[3] else None
        body = {"text": text[:5000], "format": "mp3"}
        if voice:
            body["voice"] = voice.removeprefix("kokoro:")
        with open(argv[2], "wb") as f:
            f.write(post("/tts", json.dumps(body).encode(), "application/json"))
        return 0
    print("usage: local_voice_cli.py stt <audio> | tts <text_file> <out.mp3> [voice]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
