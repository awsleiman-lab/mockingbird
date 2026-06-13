#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import tempfile
import time
import warnings

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


def synthesize(text: str, voice: str, speed: float) -> dict:
    start = time.time()
    cleaned = clean_text(text)
    if not cleaned:
        raise ValueError("No readable text was provided.")

    pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
    chunks = []
    for _, _, audio in pipeline(cleaned, voice=voice, speed=speed):
        chunks.append(np.asarray(audio, dtype=np.float32))

    if not chunks:
        raise RuntimeError("The speech engine did not produce audio.")

    audio = np.concatenate(chunks)
    with tempfile.NamedTemporaryFile(prefix="mockingbird-", suffix=".mp3", delete=False) as mp3:
        audio_path = mp3.name

    sf.write(audio_path, audio, SAMPLE_RATE, format="MP3")
    return {
        "path": audio_path,
        "duration": round(float(len(audio)) / SAMPLE_RATE, 3),
        "characters": len(cleaned),
        "elapsed": round(time.time() - start, 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voice", default=DEFAULT_VOICE)
    parser.add_argument("--speed", type=float, default=DEFAULT_SPEED)
    parser.add_argument("text", nargs="*")
    args = parser.parse_args()

    text = " ".join(args.text).strip() or sys.stdin.read()
    print(json.dumps(synthesize(text, args.voice, args.speed)), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
