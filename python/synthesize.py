#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import warnings

import numpy as np
import soundfile as sf

warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=UserWarning)

DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
DEFAULT_SPEED = float(os.environ.get("KOKORO_SPEED", "1.0"))
SAMPLE_RATE = 24000


def configure_bundled_assets() -> None:
    if os.environ.get("MOCKINGBIRD_ALLOW_NETWORK_ASSETS") == "1":
        return

    if "HF_HOME" not in os.environ:
        hf_home = os.environ.get("MOCKINGBIRD_HF_HOME")
        if not hf_home and getattr(sys, "frozen", False):
            executable = Path(sys.executable).resolve()
            for parent in executable.parents:
                for bundled_home in (parent / "huggingface", parent / "Resources" / "huggingface"):
                    if bundled_home.exists():
                        hf_home = str(bundled_home)
                        break
                if hf_home:
                    break

        if hf_home:
            os.environ["HF_HOME"] = hf_home

    if "HF_HOME" in os.environ:
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")


configure_bundled_assets()


from kokoro import KPipeline

MODEL_DIR = os.environ.get("MOCKINGBIRD_MODEL_DIR")


def build_pipeline() -> KPipeline:
    if MODEL_DIR:
        model_dir = Path(MODEL_DIR)
        config = model_dir / "config.json"
        weights = model_dir / "kokoro-v1_0.pth"
        if config.exists() and weights.exists():
            from kokoro import KModel

            model = KModel(
                repo_id="hexgrad/Kokoro-82M",
                config=str(config),
                model=str(weights),
            )
            return KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M", model=model)

    return KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")


def resolve_voice(voice: str) -> str:
    if MODEL_DIR:
        candidate = Path(MODEL_DIR) / "voices" / f"{voice}.pt"
        if candidate.exists():
            return str(candidate)
    return voice


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


def synthesize(text: str, voice: str, speed: float, pipeline: KPipeline | None = None) -> dict:
    start = time.time()
    cleaned = clean_text(text)
    if not cleaned:
        raise ValueError("No readable text was provided.")

    if pipeline is None:
        pipeline = build_pipeline()

    chunks = []
    for _, _, audio in pipeline(cleaned, voice=resolve_voice(voice), speed=speed):
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


def run_worker() -> int:
    pipeline = build_pipeline()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
            result = synthesize(
                request.get("text", ""),
                request.get("voice", DEFAULT_VOICE),
                float(request.get("speed", DEFAULT_SPEED)),
                pipeline=pipeline,
            )
            print(json.dumps({"ok": True, **result}), flush=True)
        except Exception as error:
            print(json.dumps({"ok": False, "error": str(error)}), flush=True)

    return 0


def check_runtime() -> int:
    print(json.dumps({
        "ok": True,
        "python": sys.version.split()[0],
        "sample_rate": SAMPLE_RATE,
    }), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voice", default=DEFAULT_VOICE)
    parser.add_argument("--speed", type=float, default=DEFAULT_SPEED)
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("text", nargs="*")
    args = parser.parse_args()

    if args.check:
        return check_runtime()

    if args.worker:
        return run_worker()

    text = " ".join(args.text).strip() or sys.stdin.read()
    print(json.dumps(synthesize(text, args.voice, args.speed)), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
