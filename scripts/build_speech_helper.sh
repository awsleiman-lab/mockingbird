#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT_RUNTIME="$HOME/Library/Application Support/Mockingbird/.venv/bin/python"
HELPERS_DIR="$ROOT/build-cache/helpers"
WORK_DIR="$ROOT/build-cache/pyinstaller-work"
SPEC_DIR="$ROOT/build-cache/pyinstaller-spec"
CONFIG_DIR="$ROOT/build-cache/pyinstaller-config"
HELPER_DIR="$HELPERS_DIR/MockingbirdSynth"
HELPER_BIN="$HELPER_DIR/MockingbirdSynth"
PYTHON_BIN="${MOCKINGBIRD_HELPER_PYTHON:-}"

python_is_supported() {
  "$1" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

python_has_speech_deps() {
  "$1" - <<'PY' >/dev/null 2>&1
import kokoro
import numpy
import soundfile
import torch
PY
}

find_helper_python() {
  if [[ -n "$PYTHON_BIN" ]]; then
    if python_is_supported "$PYTHON_BIN" && python_has_speech_deps "$PYTHON_BIN"; then
      echo "$PYTHON_BIN"
      return 0
    fi
    echo "Configured MOCKINGBIRD_HELPER_PYTHON is missing Python 3.10+ or speech dependencies." >&2
    return 1
  fi

  for candidate in \
    "$APP_SUPPORT_RUNTIME" \
    "$ROOT/.venv/bin/python" \
    "$HOME/.local/bin/python3.12" \
    python3.13 \
    python3.12 \
    python3.11 \
    python3.10 \
    python3; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       python_is_supported "$candidate" &&
       python_has_speech_deps "$candidate"; then
      command -v "$candidate"
      return 0
    fi
  done

  echo "No Python 3.10+ environment with Kokoro, Torch, NumPy, and SoundFile was found." >&2
  echo "Run Mockingbird setup once or create a build venv, then retry." >&2
  return 1
}

PYTHON="$(find_helper_python)"

if ! "$PYTHON" -m PyInstaller --version >/dev/null 2>&1; then
  echo "PyInstaller is not installed in $PYTHON." >&2
  echo "Install it with:" >&2
  echo "  \"$PYTHON\" -m pip install pyinstaller" >&2
  exit 1
fi

rm -rf "$HELPER_DIR" "$WORK_DIR" "$SPEC_DIR"
mkdir -p "$HELPERS_DIR" "$WORK_DIR" "$SPEC_DIR" "$CONFIG_DIR"
export PYINSTALLER_CONFIG_DIR="$CONFIG_DIR"

"$PYTHON" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name MockingbirdSynth \
  --distpath "$HELPERS_DIR" \
  --workpath "$WORK_DIR" \
  --specpath "$SPEC_DIR" \
  --collect-all kokoro \
  --collect-all misaki \
  --collect-all phonemizer \
  --collect-all segments \
  --collect-all csvw \
  --collect-all language_tags \
  --collect-all espeakng_loader \
  --collect-all en_core_web_sm \
  --copy-metadata kokoro \
  --copy-metadata misaki \
  --copy-metadata phonemizer-fork \
  --copy-metadata segments \
  --copy-metadata csvw \
  --copy-metadata language-tags \
  --copy-metadata espeakng-loader \
  --copy-metadata en-core-web-sm \
  --copy-metadata numpy \
  --copy-metadata soundfile \
  --copy-metadata torch \
  --copy-metadata transformers \
  --copy-metadata huggingface-hub \
  "$ROOT/python/synthesize.py"

if [[ ! -x "$HELPER_BIN" ]]; then
  echo "Expected helper binary was not created: $HELPER_BIN" >&2
  exit 1
fi

"$HELPER_BIN" --check >/dev/null

echo "$HELPER_BIN"
