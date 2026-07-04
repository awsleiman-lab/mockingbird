#!/bin/zsh
set -euo pipefail

# Installs a Mockingbird speech engine on the user's Mac, entirely on the fly:
#   1. Bootstraps `uv` (a single static binary) into the app's runtime folder.
#   2. Uses uv to create a private Python 3.12 venv for the engine.
#   3. Installs pinned packages from python/requirements-<engine>.txt.
# Nothing is installed system-wide; everything lives under the runtime root.
#
# Usage: engine_setup.sh kokoro|piper

ENGINE="${1:?usage: engine_setup.sh kokoro|piper}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCE_ROOT="${MOCKINGBIRD_RESOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUNTIME_ROOT="${MOCKINGBIRD_RUNTIME_ROOT:-$HOME/Library/Application Support/Mockingbird}"

REQUIREMENTS="$RESOURCE_ROOT/python/requirements-$ENGINE.txt"
if [[ ! -f "$REQUIREMENTS" ]]; then
  echo "Unknown engine '$ENGINE' (no requirements file at $REQUIREMENTS)." >&2
  exit 1
fi

ENGINE_DIR="$RUNTIME_ROOT/engines/$ENGINE"
VENV="$ENGINE_DIR/venv"
UV_DIR="$RUNTIME_ROOT/bin"
UV_BIN="$UV_DIR/uv"

export UV_CACHE_DIR="$RUNTIME_ROOT/uv-cache"
export UV_PYTHON_INSTALL_DIR="$RUNTIME_ROOT/python-runtimes"

mkdir -p "$ENGINE_DIR" "$UV_DIR"

if [[ ! -x "$UV_BIN" ]]; then
  echo "Fetching the Python package manager (uv)..."
  curl -LsSf https://astral.sh/uv/install.sh | UV_UNMANAGED_INSTALL="$UV_DIR" sh >/dev/null
fi

if [[ ! -x "$UV_BIN" ]]; then
  echo "Could not download uv. Check your internet connection and try again." >&2
  exit 1
fi

echo "Preparing a private Python 3.12 environment..."
"$UV_BIN" venv --python 3.12 --allow-existing "$VENV" 2>&1

echo "Installing $ENGINE packages (this can take a few minutes)..."
"$UV_BIN" pip install --python "$VENV/bin/python" --requirement "$REQUIREMENTS" 2>&1

echo "Verifying the $ENGINE engine..."
case "$ENGINE" in
  kokoro)
    "$VENV/bin/python" -c "import kokoro, soundfile, numpy" ;;
  piper)
    "$VENV/bin/python" -c "import piper, onnxruntime" ;;
esac

echo "Engine environment ready."
