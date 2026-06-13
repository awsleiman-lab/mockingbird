#!/usr/bin/env python3
import argparse
import json
import os
import re
import tempfile
import time
import warnings
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import soundfile as sf
from kokoro import KPipeline

warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=UserWarning)

DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
DEFAULT_SPEED = float(os.environ.get("KOKORO_SPEED", "1.0"))
SAMPLE_RATE = 24000


def markdown_to_speech(text: str) -> str:
    text = re.sub(r"```[\w+-]*\n([\s\S]*?)```", r"\1", text)
    text = re.sub(r"`([^`\n]+)`", r"\1", text)
    text = re.sub(r"!\[([^\]]*)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"(^|\s)(#{1,6})\s+", r"\1", text)
    text = re.sub(r"(^|\n)\s{0,3}[-*+]\s+", r"\1", text)
    text = re.sub(r"(^|\n)\s{0,3}\d+[.)]\s+", r"\1", text)
    text = re.sub(r"(\*\*|__)(.*?)\1", r"\2", text)
    text = re.sub(r"(\*|_)(.*?)\1", r"\2", text)
    text = re.sub(r"~~(.*?)~~", r"\1", text)
    text = re.sub(r"\s{2,}", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text


def clean_text(text: str) -> str:
    text = text.encode("utf-8", errors="ignore").decode("utf-8", errors="ignore")
    text = "".join(ch for ch in text if not 0xD800 <= ord(ch) <= 0xDFFF)
    return markdown_to_speech(text).strip()


class SpeechEngine:
    def __init__(self) -> None:
        self.pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")

    def synthesize(self, text: str, voice: str, speed: float) -> dict:
        start = time.time()
        chunks = []
        cleaned = clean_text(text)
        if not cleaned:
            raise ValueError("No readable text was provided.")

        for _, _, audio in self.pipeline(cleaned, voice=voice, speed=speed):
            chunks.append(np.asarray(audio, dtype=np.float32))

        if not chunks:
            raise RuntimeError("The speech engine did not produce audio.")

        audio = np.concatenate(chunks)
        with tempfile.NamedTemporaryFile(prefix="mockingbird-service-", suffix=".wav", delete=False) as wav:
            wav_path = wav.name

        sf.write(wav_path, audio, SAMPLE_RATE)
        return {
            "path": wav_path,
            "duration": round(float(len(audio)) / SAMPLE_RATE, 3),
            "characters": len(cleaned),
            "elapsed": round(time.time() - start, 3),
        }


class Handler(BaseHTTPRequestHandler):
    state: SpeechEngine

    def log_message(self, format: str, *args) -> None:
        return

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {"ok": True})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/synthesize":
            self._send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            result = self.state.synthesize(
                text=str(payload.get("text", "")),
                voice=str(payload.get("voice", DEFAULT_VOICE)),
                speed=float(payload.get("speed", DEFAULT_SPEED)),
            )
            self._send_json(200, result)
        except Exception as exc:
            self._send_json(500, {"error": str(exc)})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    Handler.state = SpeechEngine()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(json.dumps({"ready": True, "host": args.host, "port": args.port}), flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
