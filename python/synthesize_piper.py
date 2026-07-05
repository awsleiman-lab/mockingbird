#!/usr/bin/env python3
"""Piper-based speech worker. Speaks the same JSON stdin/stdout protocol as synthesize.py."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import wave
import warnings

warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=UserWarning)

import piper
from piper import PiperVoice

DEFAULT_VOICE = os.environ.get("PIPER_VOICE", "en_US-lessac-medium")
DEFAULT_SPEED = float(os.environ.get("PIPER_SPEED", "1.0"))
MODEL_DIR = os.environ.get("MOCKINGBIRD_MODEL_DIR", "")

_loaded_voices: dict = {}


def resolve_espeak_data_dir() -> str:
    """espeak-ng silently ignores data paths longer than ~147 chars and falls
    back to a nonexistent compile-time default, so expose the packaged data
    through a short symlink when needed."""
    data = Path(piper.__file__).resolve().parent / "espeak-ng-data"
    if len(str(data)) <= 120:
        return str(data)

    link = Path(tempfile.gettempdir()) / "mockingbird-espeak-ng-data"
    try:
        if link.is_symlink():
            if link.resolve() != data:
                link.unlink()
        elif link.exists():
            return str(data)

        if not link.exists():
            link.symlink_to(data, target_is_directory=True)
        return str(link)
    except OSError:
        return str(data)


ESPEAK_DATA_DIR = resolve_espeak_data_dir()


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


def resolve_model_path(voice: str) -> Path:
    candidates = []
    if MODEL_DIR:
        candidates.append(Path(MODEL_DIR) / f"{voice}.onnx")
    candidates.append(Path(voice))

    for candidate in candidates:
        if candidate.exists():
            return candidate

    raise FileNotFoundError(f"Piper voice model was not found for '{voice}'.")


def load_voice(voice: str) -> PiperVoice:
    if voice not in _loaded_voices:
        model_path = resolve_model_path(voice)
        try:
            _loaded_voices[voice] = PiperVoice.load(str(model_path), espeak_data_dir=ESPEAK_DATA_DIR)
        except TypeError:
            _loaded_voices[voice] = PiperVoice.load(str(model_path))
    return _loaded_voices[voice]


def write_speech(piper_voice: PiperVoice, text: str, wav_path: str, speed: float) -> None:
    length_scale = 1.0 / max(speed, 0.1)
    with wave.open(wav_path, "wb") as wav_file:
        try:
            from piper import SynthesisConfig

            piper_voice.synthesize_wav(
                text,
                wav_file,
                syn_config=SynthesisConfig(length_scale=length_scale),
            )
        except ImportError:
            piper_voice.synthesize(text, wav_file, length_scale=length_scale)


def synthesize(text: str, voice: str, speed: float) -> dict:
    start = time.time()
    cleaned = clean_text(text)
    if not cleaned:
        raise ValueError("No readable text was provided.")

    piper_voice = load_voice(voice)

    with tempfile.NamedTemporaryFile(prefix="mockingbird-", suffix=".wav", delete=False) as handle:
        audio_path = handle.name

    write_speech(piper_voice, cleaned, audio_path, speed)

    with wave.open(audio_path, "rb") as wav_file:
        frames = wav_file.getnframes()
        rate = wav_file.getframerate() or 1
        duration = frames / float(rate)

    if duration <= 0:
        raise RuntimeError("The speech engine did not produce audio.")

    return {
        "path": audio_path,
        "duration": round(duration, 3),
        "characters": len(cleaned),
        "elapsed": round(time.time() - start, 3),
    }


def write_wav(path: str, frames: bytes, sample_rate: int, sample_width: int, channels: int) -> None:
    with wave.open(path, "wb") as wav_file:
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(sample_width)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(frames)


def stream_synthesize(text: str, voice: str, speed: float) -> None:
    """Emit one JSON line per synthesized sentence chunk, then a final `done`
    line whose path is the full concatenated audio for the cache."""
    start = time.time()
    cleaned = clean_text(text)
    if not cleaned:
        raise ValueError("No readable text was provided.")

    piper_voice = load_voice(voice)
    length_scale = 1.0 / max(speed, 0.1)

    try:
        from piper import SynthesisConfig

        chunk_iter = piper_voice.synthesize(cleaned, syn_config=SynthesisConfig(length_scale=length_scale))
    except ImportError:
        chunk_iter = piper_voice.synthesize(cleaned, length_scale=length_scale)

    pieces = []
    index = 0
    sample_rate = 22050
    sample_width = 2
    channels = 1
    for chunk in chunk_iter:
        frames = chunk.audio_int16_bytes
        if not frames:
            continue

        sample_rate = chunk.sample_rate
        sample_width = chunk.sample_width
        channels = chunk.sample_channels

        index += 1
        with tempfile.NamedTemporaryFile(prefix="mockingbird-chunk-", suffix=".wav", delete=False) as handle:
            chunk_path = handle.name
        write_wav(chunk_path, frames, sample_rate, sample_width, channels)
        frame_count = len(frames) // (sample_width * channels)
        print(json.dumps({
            "chunk": index,
            "path": chunk_path,
            "duration": round(frame_count / float(sample_rate), 3),
        }), flush=True)
        pieces.append(frames)

    if not pieces:
        raise RuntimeError("The speech engine did not produce audio.")

    full = b"".join(pieces)
    with tempfile.NamedTemporaryFile(prefix="mockingbird-", suffix=".wav", delete=False) as handle:
        final_path = handle.name
    write_wav(final_path, full, sample_rate, sample_width, channels)
    total_frames = len(full) // (sample_width * channels)
    print(json.dumps({
        "done": True,
        "ok": True,
        "path": final_path,
        "duration": round(total_frames / float(sample_rate), 3),
        "characters": len(cleaned),
        "elapsed": round(time.time() - start, 3),
    }), flush=True)


def run_worker() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
            text = request.get("text", "")
            voice = request.get("voice", DEFAULT_VOICE)
            speed = float(request.get("speed", DEFAULT_SPEED))

            if request.get("stream"):
                stream_synthesize(text, voice, speed)
            else:
                result = synthesize(text, voice, speed)
                print(json.dumps({"ok": True, **result}), flush=True)
        except Exception as error:
            print(json.dumps({"ok": False, "error": str(error)}), flush=True)

    return 0


def check_runtime() -> int:
    print(json.dumps({
        "ok": True,
        "python": sys.version.split()[0],
        "engine": "piper",
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
